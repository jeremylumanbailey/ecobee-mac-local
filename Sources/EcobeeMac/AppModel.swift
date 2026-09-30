import SwiftUI
import LocalCore

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot: HomeSnapshot?
    @Published var devices: [DiscoveredDevice] = []
    @Published var selectedDevice: DiscoveredDevice?
    @Published var busy = false
    @Published var paired = false
    @Published var pairingReady = false
    @Published var demo = false
    @Published var error: String?
    @Published var notice: String?
    @Published var lastUpdated: Date?
    @Published var hasUnsavedPairing = false
    @Published var didSearch = false
    @Published var connected = false
    @Published var timerTrialMessage: String?
    private var inspectedHoldEnd: String?
    @Published var timerDiagnostics: String?
    @Published var showTimerDiagnostics = false
    @Published private(set) var fanRun: FanRun?
    @Published private(set) var fanFeedback: FanFeedback?
    private var nextFanFeedbackRead = Date.distantPast
    @AppStorage("temperatureUnit") var unitRaw = DisplayUnit.fahrenheit.rawValue
    var unit: DisplayUnit { DisplayUnit(rawValue: unitRaw) ?? .fahrenheit }
    let helper = HelperConnection()
    private let discovery = BonjourDiscovery()
    private let store = PairingStore()
    private var pairingData: Data?
    private var started = false
    private var pollTask: Task<Void, Never>?
    private var fanTimerTask: Task<Void, Never>?
    private let fanRunKey = "localFanRun.v1"
    private var accessoryID: String? {
        if demo { return "demo" }
        guard let pairingData,
              let pairing = try? JSONSerialization.jsonObject(with: pairingData) as? [String: Any]
        else { return nil }
        return (pairing["AccessoryPairingID"] as? String)?.lowercased()
    }

    func start() async {
        guard !started else { return }; started = true
        if ProcessInfo.processInfo.arguments.contains("--demo") { showDemo() }
        else {
            do {
                pairingData = try store.load()
                paired = pairingData != nil
                if let data = UserDefaults.standard.data(forKey: fanRunKey),
                   let saved = try? JSONDecoder().decode(FanRun.self, from: data),
                   saved.accessoryID == accessoryID { fanRun = saved }
                if paired { await reconnect() }
            } catch { self.error = error.localizedDescription }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self else { return }
                if self.paired && !self.demo && !self.busy && self.fanFeedback?.isPending != true {
                    if self.connected { await self.refresh() } else { await self.reconnect() }
                }
            }
        }
        fanTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.checkFanFeedback()
                await self?.finishFanRunIfDue()
            }
        }
    }
    func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do { try await work() } catch { self.error = error.localizedDescription }
    }
    func discover() async {
        await perform {
            pairingReady = false; selectedDevice = nil
            devices = try await discovery.discover()
            didSearch = true
        }
    }
    func beginPairing(_ device: DiscoveredDevice) async {
        await perform {
            pairingReady = false
            let endpoint = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device))
            _ = try await helper.request("start_pairing", ["deviceID": device.id, "endpoint": endpoint])
            selectedDevice = device; pairingReady = true
        }
    }
    func finishPairing(pin: String) async {
        await perform {
            let result = try await helper.request("finish_pairing", ["pin": pin])
            guard let pairing = result["pairing"] as? [String: Any] else { throw AppFailure("The thermostat returned an invalid pairing.") }
            pairingData = try JSONSerialization.data(withJSONObject: pairing)
            paired = true; pairingReady = false; hasUnsavedPairing = true
            try savePairing()
            let state = try await helper.request("refresh")
            try accept(state)
        }
        if !paired { pairingReady = false }
    }
    func savePairing() throws {
        guard let pairingData else { return }
        try store.save(pairingData)
        hasUnsavedPairing = false
    }
    func retrySave() {
        do { try savePairing(); error = nil; notice = "Pairing saved securely in Keychain." }
        catch { self.error = error.localizedDescription }
    }
    func reconnect() async {
        await perform {
            guard let pairingData else { throw AppFailure("No saved pairing is available.") }
            connected = false
            let pairing = try JSONSerialization.jsonObject(with: pairingData) as? [String: Any] ?? [:]
            let deviceID = (pairing["AccessoryPairingID"] as? String)?.lowercased()
            let nearby = try await discovery.discover()
            var arguments: [String: Any] = ["pairing": pairing]
            if let device = nearby.first(where: { $0.id == deviceID }) {
                arguments["endpoint"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device))
            }
            let result = try await helper.request("connect", arguments)
            try accept(result)
        }
    }
    func refresh() async {
        if demo { lastUpdated = Date(); return }
        await perform {
            do { try accept(await helper.request("refresh")) }
            catch { connected = false; throw error }
        }
    }
    @discardableResult
    func write(_ changes: [String: Any], thermostat: LocalThermostat) async -> Bool {
        var accepted = false
        await perform {
            if demo {
                guard let index = snapshot?.thermostats.firstIndex(where: { $0.id == thermostat.id }) else { return }
                if let value = changes["mode"] as? Double { snapshot?.thermostats[index].mode = value }
                if let value = changes["target"] as? Double { snapshot?.thermostats[index].target = value }
                if let value = changes["heat"] as? Double { snapshot?.thermostats[index].heat = value }
                if let value = changes["cool"] as? Double { snapshot?.thermostats[index].cool = value }
                if let value = changes["fan"] as? Int {
                    let hvacActive = [1.0, 2.0].contains(snapshot?.thermostats[index].state ?? 0)
                    snapshot?.thermostats[index].fan = Double(value)
                    snapshot?.thermostats[index].fanState = value == 100 || hvacActive ? 2 : 0
                }
                if changes["resume"] as? Bool == true { snapshot = PreviewData.snapshot }
                accepted = true
                lastUpdated = Date(); notice = "Demo updated. No real thermostat was changed."
                return
            }
            guard connected else { throw AppFailure("Reconnect before changing the thermostat.") }
            do {
                let result = try await helper.request("write", ["thermostatID": thermostat.id, "changes": changes])
                accepted = true
                if let warning = result["warning"] as? String { connected = false; notice = warning }
                else { try accept(result); notice = "Changes accepted. Showing the thermostat’s latest readings." }
            } catch { connected = false; throw error }
        }
        return accepted
    }

    func setFan(on: Bool, duration: FanRunDuration = .continuous, thermostat: LocalThermostat) async {
        guard !busy else { return }
        guard (connected || demo), !hasUnsavedPairing, thermostat.fields["fan"] != nil, let accessoryID else {
            error = "Reconnect to a thermostat with local fan control before changing the fan."; return
        }
        if let fanRun, fanRun.thermostatID != thermostat.id {
            error = "Return the other thermostat’s timed fan run to Auto first."; return
        }
        fanFeedback = FanFeedback(thermostatID: thermostat.id, action: on ? .start : .stop)
        if on {
            fanRun = duration == .continuous ? nil : FanRun(accessoryID: accessoryID, thermostatID: thermostat.id, duration: duration)
        } else {
            fanRun?.markReturnAttempted()
        }
        // Save before sending: if the reply is lost, a timed run still has its return-to-Auto deadline.
        persistFanRun()
        let runID = fanRun?.id
        let accepted = await write(["fan": on ? 100 : 0], thermostat: thermostat)
        completeFanRequest(accepted: accepted)
        if on, fanRun?.id == runID { fanRun?.startConfirmed = accepted }
        if accepted && !on { fanRun = nil }
        persistFanRun()
    }

    private func finishFanRunIfDue() async {
        guard var run = fanRun, let accessoryID,
              run.claimReturn(at: Date(), accessoryID: accessoryID, connected: connected || demo, busy: busy || hasUnsavedPairing)
        else { return }
        fanRun = run; persistFanRun()
        guard let thermostat = snapshot?.thermostats.first(where: { $0.id == run.thermostatID }), thermostat.fields["fan"] != nil else {
            error = "The fan timer ended, but its thermostat control is unavailable. Check the fan on your thermostat."; return
        }
        fanFeedback = FanFeedback(thermostatID: thermostat.id, action: .stop)
        let accepted = await write(["fan": 0], thermostat: thermostat)
        completeFanRequest(accepted: accepted)
        if accepted {
            fanRun = nil; persistFanRun()
        }
    }

    private func completeFanRequest(accepted: Bool) {
        fanFeedback?.completeRequest(accepted: accepted, now: Date())
        if connected || demo { updateFanFeedbackReading() }
        else { fanFeedback?.connectionLost() }
        nextFanFeedbackRead = Date().addingTimeInterval(2)
        // The inline feedback owns the outcome; avoid a second, prematurely final notice.
        if accepted && (connected || demo) { notice = nil }
    }

    private func updateFanFeedbackReading() {
        guard let feedback = fanFeedback else { return }
        let thermostat = snapshot?.thermostats.first { $0.id == feedback.thermostatID }
        fanFeedback?.observe(mode: thermostat?.fan,
                                 running: thermostat?.fanRunning, now: Date())
    }

    /// Called by the one-second clock, so even an in-flight read cannot leave the spinner stuck.
    private func checkFanFeedback() {
        guard connected || demo else { fanFeedback?.connectionLost(); return }
        let wasWaiting = fanFeedback?.phase == .waiting
        fanFeedback?.expire(at: Date())
        if wasWaiting && fanFeedback?.isPending == false { updateFanFeedbackReading() }
        guard fanFeedback?.isPending == true else { return }
        guard !busy, Date() >= nextFanFeedbackRead, !demo, let id = fanFeedback?.id else { return }
        nextFanFeedbackRead = Date().addingTimeInterval(2)
        busy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let result = try await self.helper.request("refresh")
                guard self.fanFeedback?.id == id else { return }
                try self.accept(result)
            } catch {
                self.connected = false
                if self.fanFeedback?.id == id { self.fanFeedback?.connectionLost() }
                self.error = error.localizedDescription
            }
        }
    }

    private func persistFanRun() {
        guard !demo else { return }
        if let fanRun, let data = try? JSONEncoder().encode(fanRun) {
            UserDefaults.standard.set(data, forKey: fanRunKey)
        } else { UserDefaults.standard.removeObject(forKey: fanRunKey) }
    }

    func inspectFanTimer() async {
        await perform {
            guard connected, !demo else { throw AppFailure("Connect to your thermostat to inspect its timer capabilities.") }
            let result = try await helper.request("inspect_fan_timer")
            guard let report = result["diagnostics"] as? [String: Any] else { throw AppFailure("No timer report was returned.") }
            try acceptTimerReport(report)
            showTimerDiagnostics = true
        }
    }

    private func acceptTimerReport(_ report: [String: Any]) throws {
        let services = report["services"] as? [[String: Any]]
        let fields = services?.first?["fields"] as? [String: [String: Any]]
        inspectedHoldEnd = fields?["holdEnd"]?["value"] as? String
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        timerDiagnostics = String(decoding: data, as: UTF8.self)
    }

    func testFanDeadline() async {
        await perform {
            guard connected, !demo, fanRun == nil, let inspectedHoldEnd else {
                throw AppFailure("Inspect a native fan hold first. No Mac fan timer can be active during this test.")
            }
            timerTrialMessage = "Sending one two-minute deadline to the thermostat…"
            do {
                let result = try await helper.request("test_fan_deadline", ["expectedEnd": inspectedHoldEnd])
                if let report = result["diagnostics"] as? [String: Any] { try acceptTimerReport(report) }
                let deadline = result["deadline"] as? String ?? "unknown"
                if result["deadlineConfirmed"] as? Bool == true && result["climateUnchanged"] as? Bool == true {
                    timerTrialMessage = "Thermostat readback matches \(deadline). Climate settings are unchanged. Quit this app and observe whether the native fan hold ends on its own. No Mac timer was created."
                } else {
                    timerTrialMessage = "The write was accepted, but its deadline or unchanged climate settings could not be verified. Check the thermostat before continuing. No automatic retry will occur."
                }
            } catch {
                timerTrialMessage = "The deadline test could not be confirmed: \(error.localizedDescription)"
                throw error
            }
        }
    }

    func unpair() async {
        await perform {
            guard fanRun == nil else { throw AppFailure("Return the fan to Auto before removing this Mac’s pairing.") }
            _ = try await helper.request("unpair")
            // If deleting Keychain fails, retain an explicit error instead of claiming success.
            try store.delete()
            helper.stop(); pairingData = nil; paired = false; connected = false
            fanFeedback = nil
            snapshot = nil; lastUpdated = nil; devices = []; didSearch = false
            notice = "Pairing removed from the thermostat and this Mac."
        }
    }
    func showDemo() {
        guard !busy, !paired else { return }
        demo = true; connected = false; error = nil; notice = nil
        snapshot = PreviewData.snapshot; lastUpdated = Date()
    }
    func exitDemo() {
        fanRun = nil; fanFeedback = nil
        demo = false; snapshot = nil; lastUpdated = nil; notice = nil; error = nil
    }
    private func accept(_ result: [String: Any]) throws {
        guard let value = result["snapshot"] else { throw AppFailure("The thermostat returned no readings.") }
        snapshot = try decode(HomeSnapshot.self, value)
        lastUpdated = Date(); connected = true
        updateFanFeedbackReading()
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}
