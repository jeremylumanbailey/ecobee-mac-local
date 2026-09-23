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
    @AppStorage("temperatureUnit") var unitRaw = DisplayUnit.fahrenheit.rawValue
    var unit: DisplayUnit { DisplayUnit(rawValue: unitRaw) ?? .fahrenheit }
    let helper = HelperConnection()
    private let discovery = BonjourDiscovery()
    private let store = PairingStore()
    private var pairingData: Data?
    private var started = false
    private var pollTask: Task<Void, Never>?

    func start() async {
        guard !started else { return }; started = true
        if ProcessInfo.processInfo.arguments.contains("--demo") { showDemo() }
        else {
            do {
                pairingData = try store.load()
                paired = pairingData != nil
                if paired { await reconnect() }
            } catch { self.error = error.localizedDescription }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self else { return }
                if self.paired && !self.demo && !self.busy {
                    if self.connected { await self.refresh() } else { await self.reconnect() }
                }
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
    func write(_ changes: [String: Any], thermostat: LocalThermostat) async {
        await perform {
            if demo {
                guard let index = snapshot?.thermostats.firstIndex(where: { $0.id == thermostat.id }) else { return }
                if let value = changes["mode"] as? Double { snapshot?.thermostats[index].mode = value }
                if let value = changes["target"] as? Double { snapshot?.thermostats[index].target = value }
                if let value = changes["heat"] as? Double { snapshot?.thermostats[index].heat = value }
                if let value = changes["cool"] as? Double { snapshot?.thermostats[index].cool = value }
                if changes["resume"] as? Bool == true { snapshot = PreviewData.snapshot }
                lastUpdated = Date(); notice = "Demo updated. No real thermostat was changed."
                return
            }
            guard connected else { throw AppFailure("Reconnect before changing the thermostat.") }
            do {
                let result = try await helper.request("write", ["thermostatID": thermostat.id, "changes": changes])
                if let warning = result["warning"] as? String { connected = false; notice = warning }
                else { try accept(result); notice = "Changes accepted. Showing the thermostat’s latest readings." }
            } catch { connected = false; throw error }
        }
    }
    func unpair() async {
        await perform {
            _ = try await helper.request("unpair")
            // If deleting Keychain fails, retain an explicit error instead of claiming success.
            try store.delete()
            helper.stop(); pairingData = nil; paired = false; connected = false
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
        demo = false; snapshot = nil; lastUpdated = nil; notice = nil; error = nil
    }
    private func accept(_ result: [String: Any]) throws {
        guard let value = result["snapshot"] else { throw AppFailure("The thermostat returned no readings.") }
        snapshot = try decode(HomeSnapshot.self, value)
        lastUpdated = Date(); connected = true
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}
