import Foundation
import Security
import LocalCore

@MainActor private var checks = 0
@MainActor private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAILED: \(label)") }
    checks += 1
    print("PASS: \(label)")
}
@MainActor private func rejects(_ label: String, _ work: () async throws -> Void) async {
    do { try await work(); fatalError("FAILED: \(label) did not reject") }
    catch { check(true, label) }
}
private let pairingFixture = Data(#"{"Connection":"IP","AccessoryPairingID":"fixture-accessory"}"#.utf8)
private func reply(_ snapshot: HomeSnapshot = PreviewData.snapshot) -> [String: Any] {
    ["snapshot": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))]
}
@MainActor private final class FakeHelper: HelperRequesting {
    var calls: [(String, [String: Any])] = []
    var stopped = false
    var handler: ((String, [String: Any]) async throws -> [String: Any])?
    func request(_ command: String, _ fields: [String: Any]) async throws -> [String: Any] {
        calls.append((command, fields))
        return try await handler?(command, fields) ?? reply()
    }
    func stop() { stopped = true }
}
@MainActor private final class FakeDiscovery: ThermostatDiscovering {
    var targets: [String?] = []
    var failure = false
    var devices: [DiscoveredDevice] = []
    func discover(matching deviceID: String?) async throws -> [DiscoveredDevice] {
        targets.append(deviceID)
        if failure { throw AppFailure("Synthetic discovery failure") }
        return devices
    }
}
private final class FakeStore: PairingStoring {
    var data: Data? = pairingFixture
    var failLoad = false, failSave = false, failDelete = false
    var saves = 0, deletes = 0
    func load() throws -> Data? { if failLoad { throw AppFailure("Synthetic load failure") }; return data }
    func save(_ data: Data) throws { saves += 1; if failSave { throw AppFailure("Synthetic save failure") }; self.data = data }
    func delete() throws { deletes += 1; if failDelete { throw AppFailure("Synthetic delete failure") }; data = nil }
}
private final class FakeTime { var date = Date(timeIntervalSince1970: 1_800_000_000) }
@MainActor private struct Fixture {
    let suite = "local.ecobee.tests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let helper = FakeHelper()
    let discovery = FakeDiscovery()
    let store = FakeStore()
    let clock = FakeTime()
    let model: AppModel
    init(arguments: [String] = []) {
        preferences = UserDefaults(suiteName: suite)!
        model = AppModel(helper: helper, discovery: discovery, store: store, preferences: preferences,
                         now: { [clock] in clock.date }, automaticTasks: false, arguments: arguments)
    }
    func cleanup() { helper.handler = nil; preferences.removePersistentDomain(forName: suite) }
}
private final class FakeService: NetService {
    var resolved = false, stopped = false
    override func resolve(withTimeout timeout: TimeInterval) { resolved = true }
    override func stop() { stopped = true }
    var record: Data?
    var rawAddresses: [Data]?
    override func txtRecordData() -> Data? { record }
    override var addresses: [Data]? { rawAddresses }
}

private final class FakeBrowser: NetServiceBrowser {
    var searched = false, stopped = false
    var serviceType: String?
    override func searchForServices(ofType type: String, inDomain domain: String) { searched = true; serviceType = type }
    override func stop() { stopped = true }
}

@main @MainActor private enum AppChecks {
    static func main() async throws {
        let thermostat = PreviewData.snapshot.thermostats[0]
        do {
            let f = Fixture(); defer { f.cleanup() }
            await f.model.start()
            check(f.model.connected && f.model.paired && !f.model.isConnecting && !f.model.busy, "Startup finishes connected and unlocked")
            check(f.discovery.targets.count == 1 && f.discovery.targets[0] == "fixture-accessory", "Reconnect discovers only the saved accessory")
            check(f.preferences.data(forKey: "lastHomeSnapshot.v1") != nil, "Fresh connection persists display cache")
            await f.model.start()
            check(f.helper.calls.count == 1, "Starting twice does not create duplicate connections")
            f.model.unitRaw = "celsius"
            check(f.preferences.string(forKey: "temperatureUnit") == "celsius" && f.model.unit == .celsius, "Unit selection uses injected preferences")
            f.model.unitRaw = "invalid"
            check(f.model.unit == .fahrenheit, "Invalid stored unit falls back safely")
            f.model.busy = true
            let count = f.helper.calls.count
            _ = await f.model.write(["mode": 0.0], thermostat: thermostat)
            check(f.helper.calls.count == count, "Busy state serializes commands")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            let old = f.clock.date.addingTimeInterval(-60)
            f.preferences.set(try JSONEncoder().encode(CachedHomeSnapshot(snapshot: PreviewData.snapshot, accessoryID: "fixture-accessory", savedAt: old)), forKey: "lastHomeSnapshot.v1")
            f.helper.handler = { _, _ in
                check(f.model.snapshot != nil && f.model.lastUpdated == old, "Cached screen is restored before live reply")
                check(!f.model.connected && !f.model.canControl && f.model.isConnecting, "Cached capabilities cannot unlock controls")
                throw AppFailure("Offline fixture")
            }
            await f.model.start()
            check(!f.model.connected && !f.model.isConnecting && !f.model.busy && f.model.error != nil, "Failed connection ends loading but preserves offline readings")
            check(f.model.snapshot != nil, "Connection failure preserves cached layout")
            let before = f.helper.calls.count
            _ = await f.model.write(["target": 22.0], thermostat: thermostat)
            check(f.helper.calls.count == before, "Disconnected write never reaches helper")
            f.helper.handler = nil
            await f.model.reconnect()
            check(f.model.canControl && f.model.lastUpdated == f.clock.date, "Only fresh authenticated readings unlock cached UI")
        }
        for mode in ["missing", "mismatch", "corrupt", "expired"] {
            let f = Fixture(); defer { f.cleanup() }
            if mode == "missing" { f.store.data = nil }
            let cached = CachedHomeSnapshot(snapshot: PreviewData.snapshot, accessoryID: mode == "mismatch" ? "other" : "fixture-accessory", savedAt: f.clock.date.addingTimeInterval(mode == "expired" ? -700_000 : 0))
            f.preferences.set(mode == "corrupt" ? Data("broken".utf8) : try JSONEncoder().encode(cached), forKey: "lastHomeSnapshot.v1")
            f.discovery.failure = true
            await f.model.start()
            check(f.model.snapshot == nil && f.preferences.data(forKey: "lastHomeSnapshot.v1") == nil, "Startup removes \(mode) pairing/cache")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }; f.store.failLoad = true
            await f.model.start()
            check(!f.model.isConnecting && f.model.error != nil && f.helper.calls.isEmpty, "Keychain load failure ends startup without connecting")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            await f.model.start()
            f.helper.handler = { _, _ in ["snapshot": ["invalid": true]] }
            await f.model.refresh()
            check(!f.model.connected && !f.model.busy && f.model.error != nil, "Malformed refresh locks controls")
            f.helper.handler = { _, _ in [:] }
            await f.model.reconnect()
            check(!f.model.connected && f.model.error != nil, "Missing snapshot cannot establish a connection")
            f.helper.handler = { _, _ in ["warning": "Accepted; readback failed"] }
            f.model.connected = true
            let accepted = await f.model.write(["fan": 100], thermostat: thermostat)
            check(accepted && !f.model.connected && f.model.notice == "Accepted; readback failed", "Accepted write with missing readback is explicit and locks controls")
            f.helper.handler = { _, _ in throw AppFailure("uncertain write") }
            f.model.connected = true
            let count = f.helper.calls.count
            let failed = await f.model.write(["fan": 0], thermostat: thermostat)
            check(!failed && f.helper.calls.count == count + 1 && !f.model.connected, "Uncertain write is sent once and never retried")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }; f.store.data = nil
            await f.model.start()
            f.helper.handler = { command, _ in command == "finish_pairing" ? ["pairing": ["Connection":"IP", "AccessoryPairingID":"fixture-accessory"]] : reply() }
            f.store.failSave = true
            await f.model.finishPairing(pin: "111-22-333")
            check(f.model.hasUnsavedPairing && f.model.paired && !f.model.canControl, "Failed Keychain save retains pairing and disables controls")
            check(!f.helper.calls.contains { $0.0 == "refresh" }, "Pairing is saved before optional readings")
            f.store.failSave = false; f.model.retrySave()
            check(!f.model.hasUnsavedPairing && f.model.error == nil && f.store.saves == 2, "User can retry saving pairing without pairing again")
            await f.model.reconnect()
            f.store.failDelete = true
            await f.model.unpair()
            check(f.model.paired && f.model.error != nil, "Keychain delete failure cannot claim pairing removal succeeded")
            f.store.failDelete = false
            await f.model.unpair()
            check(!f.model.paired && !f.model.connected && f.model.snapshot == nil && f.helper.stopped, "Unpair clears live state and stops helper")
            check(f.preferences.data(forKey: "lastHomeSnapshot.v1") == nil, "Unpair removes startup cache")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }; f.store.data = nil
            await f.model.start()
            await f.model.discover()
            check(f.model.didSearch && !f.model.pairingReady, "Discovery records completed search")
            let device = try JSONDecoder().decode(DiscoveredDevice.self, from: Data(#"{"id":"fixture-accessory","name":"Fixture","model":"ECB701","address":"192.0.2.1","port":1234,"available":true,"featureFlags":0,"statusFlags":1,"configNumber":1}"#.utf8))
            await f.model.beginPairing(device)
            check(f.model.pairingReady && f.model.selectedDevice?.id == device.id, "Starting pairing records selected endpoint")
            await f.model.finishPairing(pin: "111-22-333")
            check(!f.model.paired && !f.model.pairingReady && f.model.error != nil, "Missing pairing payload resets unfinished setup")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            await f.model.start()
            await f.model.setFan(on: true, duration: .fifteen, thermostat: thermostat)
            check(f.model.fanRun?.endsAt == f.clock.date.addingTimeInterval(900) && f.model.fanRun?.startConfirmed == true, "Timed fan starts and persists a deterministic deadline")
            check(f.preferences.data(forKey: "localFanRun.v1") != nil, "Pending fan deadline is persisted")
            await f.model.unpair()
            check(!f.helper.calls.contains { $0.0 == "unpair" }, "Unpair is blocked while a fan deadline is active")
            f.clock.date = f.clock.date.addingTimeInterval(901)
            var off = PreviewData.snapshot; off.thermostats[0].fan = 0; off.thermostats[0].fanState = 0
            f.helper.handler = { _, _ in reply(off) }
            await f.model.finishFanRunIfDue()
            check(f.model.fanRun == nil && f.model.fanFeedback?.phase == .confirmed, "Expired fan timer requests Auto and confirms off")
            let count = f.helper.calls.count
            await f.model.finishFanRunIfDue()
            check(f.helper.calls.count == count, "Completed deadline does not write twice")
            check(f.preferences.data(forKey: "localFanRun.v1") == nil, "Completed fan deadline is removed")
            await f.model.setFan(on: true, duration: .continuous, thermostat: thermostat)
            check(f.model.fanRun == nil && f.model.fanFeedback?.action == .start, "Continuous run replaces stop feedback without a deadline")
            f.model.hasUnsavedPairing = true
            let before = f.helper.calls.count
            await f.model.setFan(on: false, thermostat: thermostat)
            check(f.helper.calls.count == before, "Unsaved pairing blocks fan commands")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            await f.model.start()
            await f.model.setFan(on: true, duration: .fifteen, thermostat: thermostat)
            f.clock.date = f.clock.date.addingTimeInterval(901)
            f.helper.handler = { _, _ in throw AppFailure("uncertain Auto") }
            await f.model.finishFanRunIfDue()
            check(f.model.fanRun?.returnAttempted == true, "Failed timer return remains marked attempted")
            let count = f.helper.calls.count
            f.model.connected = true
            await f.model.finishFanRunIfDue()
            check(f.helper.calls.count == count, "Failed timer return is not retried automatically")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            let run = FanRun(accessoryID: "fixture-accessory", thermostatID: thermostat.id, duration: .fifteen, now: f.clock.date)
            f.preferences.set(try JSONEncoder().encode(run), forKey: "localFanRun.v1")
            await f.model.start()
            check(f.model.fanRun?.id == run.id, "Startup restores the same saved fan deadline")
            await f.model.setFan(on: false, thermostat: thermostat)
            check(f.model.fanRun == nil, "Accepted manual stop clears restored deadline")
            f.clock.date = f.clock.date.addingTimeInterval(3)
            f.model.checkFanFeedback()
            for _ in 0..<1000 { if !f.model.busy { break }; await Task.yield() }
            check(f.helper.calls.last?.0 == "refresh", "Pending fan feedback performs a read-only refresh")
            f.clock.date = f.clock.date.addingTimeInterval(31)
            f.model.checkFanFeedback()
            check(f.model.fanFeedback?.isPending == false, "Feedback watchdog stops waiting after deadline")
        }
        do {
            let f = Fixture(arguments: ["--demo"]); defer { f.cleanup() }
            await f.model.start()
            check(f.model.demo && !f.model.connected && f.helper.calls.isEmpty && f.model.canControl, "Demo is isolated from real pairing and transport")
            _ = await f.model.write(["mode": 0.0, "target": 23.0, "heat": 19.0, "cool": 25.0, "fan": 100], thermostat: thermostat)
            check(f.model.snapshot?.thermostats[0].fanRunning == true && f.helper.calls.isEmpty, "Demo writes update simulated readings only")
            await f.model.setFan(on: false, thermostat: thermostat)
            check(f.model.snapshot?.thermostats[0].fanRunning == false, "Demo stop respects simulated HVAC state")
            _ = await f.model.write(["resume": true], thermostat: thermostat)
            check(f.model.snapshot?.thermostats[0].mode == 3, "Demo schedule resume restores sample settings")
            check(f.preferences.data(forKey: "lastHomeSnapshot.v1") == nil, "Demo never persists a real startup snapshot")
            let beforeRefresh = f.clock.date
            await f.model.refresh()
            check(f.model.lastUpdated == beforeRefresh && f.helper.calls.isEmpty, "Demo refresh never contacts a thermostat")
            f.model.exitDemo()
            check(f.model.snapshot == nil && !f.model.demo && f.model.fanFeedback == nil, "Exiting demo clears simulated state")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            await f.model.start()
            f.helper.handler = { command, _ in
                if command == "inspect_fan_timer" { return ["diagnostics": ["services": [["fields": ["holdEnd": ["value": "fixture-deadline"]]]]]] }
                return ["deadline":"fixture-shortened", "deadlineConfirmed":true, "climateUnchanged":true]
            }
            await f.model.inspectFanTimer()
            check(f.model.showTimerDiagnostics && f.model.timerDiagnostics != nil, "Timer diagnostics display returned allowlisted report")
            await f.model.testFanDeadline()
            check(f.helper.calls.last?.1["expectedEnd"] as? String == "fixture-deadline" && f.model.timerTrialMessage?.contains("readback matches") == true, "Deadline trial uses inspected value and verified result")
            f.helper.handler = { _, _ in ["deadlineConfirmed": false] }
            await f.model.testFanDeadline()
            check(f.model.timerTrialMessage?.contains("could not be verified") == true, "Unconfirmed trial is never labeled successful")
            f.helper.handler = { _, _ in throw AppFailure("fixture failure") }
            await f.model.testFanDeadline()
            check(f.model.timerTrialMessage?.contains("could not be confirmed") == true, "Trial failure is visible")
            f.helper.handler = { _, _ in [:] }
            await f.model.inspectFanTimer()
            check(f.model.error != nil, "Missing diagnostic report is rejected")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }; f.store.data = nil
            await f.model.start()
            await f.model.reconnect()
            check(f.helper.calls.isEmpty && f.model.error != nil, "Missing pairing rejects reconnect without contacting helper")
            f.helper.handler = { command, _ in command == "finish_pairing" ? ["pairing": ["Connection":"IP", "AccessoryPairingID":"fixture-accessory"]] : reply() }
            await f.model.finishPairing(pin: "111-22-333")
            check(f.model.connected && !f.model.hasUnsavedPairing && f.store.saves == 1, "Successful pairing saves keys and then accepts fresh readings")
            let device = try JSONDecoder().decode(DiscoveredDevice.self, from: Data(#"{"id":"fixture-accessory","name":"Fixture","model":"ECB701","address":"192.0.2.1","port":1234,"available":false,"featureFlags":0,"statusFlags":0,"configNumber":1}"#.utf8))
            f.discovery.devices = [device]
            await f.model.reconnect()
            let endpoint = f.helper.calls.last?.1["endpoint"] as? [String: Any]
            check(endpoint?["address"] as? String == "192.0.2.1", "Reconnect passes newly discovered endpoint for saved accessory")
            f.discovery.failure = true
            let before = f.helper.calls.count
            await f.model.reconnect()
            check(!f.model.connected && !f.model.isConnecting && f.model.error != nil && f.helper.calls.count == before, "Discovery failure ends reconnect and keeps controls locked")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            await f.model.start()
            await f.model.testFanDeadline()
            check(f.model.error != nil && !f.helper.calls.contains { $0.0 == "test_fan_deadline" }, "Experimental deadline requires prior inspection")
            await f.model.setFan(on: true, duration: .fifteen, thermostat: thermostat)
            let runID = f.model.fanRun?.id
            var other = try JSONSerialization.jsonObject(with: JSONEncoder().encode(thermostat)) as! [String: Any]
            other["id"] = "other-service"
            let second = try JSONDecoder().decode(LocalThermostat.self, from: JSONSerialization.data(withJSONObject: other))
            let before = f.helper.calls.count
            await f.model.setFan(on: true, thermostat: second)
            check(f.helper.calls.count == before && f.model.fanRun?.id == runID, "Another thermostat cannot replace an existing fan deadline")
            f.helper.handler = { _, _ in throw AppFailure("Lost feedback connection") }
            f.clock.date = f.clock.date.addingTimeInterval(3)
            f.model.checkFanFeedback()
            for _ in 0..<1000 { if !f.model.busy { break }; await Task.yield() }
            check(!f.model.connected && f.model.fanFeedback?.phase == .unconfirmed && f.model.error != nil, "Failed feedback read ends spinner and disables controls")
            f.model.connected = true; f.model.snapshot = nil
            f.clock.date = f.clock.date.addingTimeInterval(901)
            let count = f.helper.calls.count
            await f.model.finishFanRunIfDue()
            check(f.model.fanRun?.returnAttempted == true && f.model.error?.contains("unavailable") == true && f.helper.calls.count == count, "Expired timer with missing control reports failure without sending a guessed command")
        }
        try keychainTests()
        try await discoveryTests()
        await transportTests()
        print("\(checks) app/adapter checks passed.")
    }

    static func keychainTests() throws {
        var query: [String: Any] = [:]
        var store = PairingStore()
        store.access.copy = { query = $0; return (errSecItemNotFound, nil) }
        let missing = try store.load()
        check(missing == nil, "Missing Keychain item is an unpaired state")
        check(query[kSecAttrAccount as String] as? String == "homekit-pairing", "Keychain access is scoped to pairing account")
        store.access.copy = { _ in (errSecSuccess, Data("fixture".utf8) as CFData) }
        let loaded = try store.load()
        check(loaded == Data("fixture".utf8), "Keychain load returns stored bytes")
        store.access.copy = { _ in (errSecUserCanceled, nil) }
        do { _ = try store.load(); fatalError("Expected canceled Keychain error") } catch { check(error is KeychainFailure, "Canceled Keychain access is surfaced") }
        var added: [String: Any] = [:]
        store.access.update = { _, _ in errSecItemNotFound }
        store.access.add = { added = $0; return errSecSuccess }
        try store.save(Data("fixture".utf8))
        check(added[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, "New pairing is device-only and requires unlocked Keychain")
        check(added[kSecAttrSynchronizable as String] == nil, "Pairing is not marked synchronizable")
        store.access.update = { _, fields in check(fields[kSecValueData as String] as? Data == Data("updated".utf8), "Existing pairing update carries new bytes"); return errSecSuccess }
        store.access.add = { _ in fatalError("Update must not add duplicate item") }
        try store.save(Data("updated".utf8))
        for status in [errSecSuccess, errSecItemNotFound] {
            store.access.delete = { _ in status }; try store.delete()
            check(true, "Keychain deletion tolerates success or missing item")
        }
        store.access.update = { _, _ in errSecAuthFailed }
        do { try store.save(Data()); fatalError("Expected save error") } catch { check(true, "Keychain update failure is surfaced") }
        store.access.update = { _, _ in errSecItemNotFound }; store.access.add = { _ in errSecAuthFailed }
        do { try store.save(Data()); fatalError("Expected add error") } catch { check(true, "Keychain add failure is surfaced") }
        store.access.delete = { _ in errSecAuthFailed }
        do { try store.delete(); fatalError("Expected delete error") } catch { check(true, "Keychain delete failure is surfaced") }
        check(KeychainFailure(errSecAuthFailed).localizedDescription.contains("Keychain"), "Keychain errors explain recovery")
    }

    static func discoveryTests() async throws {
        let service = FakeService(domain: "local.", type: "_hap._tcp.", name: "Fixture Ecobee", port: 1234)
        check(BonjourDiscovery.parse(service) == nil, "Discovery ignores absent TXT records")
        service.record = NetService.data(fromTXTRecord: ["id": Data("FIXTURE".utf8), "ci": Data("9".utf8), "sf": Data("1".utf8)])
        check(BonjourDiscovery.parse(service) == nil, "Discovery ignores unresolved addresses")
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("192.0.2.1")
        service.rawAddresses = [Data([1]), withUnsafeBytes(of: &addr) { Data($0) }]
        let parsed = BonjourDiscovery.parse(service)
        check(parsed?.id == "fixture" && parsed?.address == "192.0.2.1" && parsed?.available == true, "Discovery parses and normalizes a resolved thermostat")
        check(parsed?.configNumber == 1 && parsed?.featureFlags == 0, "Missing optional discovery metadata has safe defaults")
        service.record = NetService.data(fromTXTRecord: ["ci": Data("9".utf8)])
        check(BonjourDiscovery.parse(service) == nil, "Discovery rejects missing accessory identity")
        let lamp = FakeService(domain: "local.", type: "_hap._tcp.", name: "Lamp", port: 1234)
        lamp.record = NetService.data(fromTXTRecord: ["id":Data("fixture".utf8), "ci":Data("5".utf8)])
        lamp.rawAddresses = service.rawAddresses
        check(BonjourDiscovery.parse(lamp) == nil, "Discovery filters non-thermostat accessories")
        service.record = NetService.data(fromTXTRecord: ["id": Data("FIXTURE".utf8), "ci": Data("9".utf8)])
        do {
            let browser = FakeBrowser()
            let discovery = BonjourDiscovery(browserFactory: { browser }, timeout: .seconds(2))
            let pending = Task { try await discovery.discover(matching: "FIXTURE") }
            for _ in 0..<1000 { if browser.searched { break }; await Task.yield() }
            check(browser.searched && browser.serviceType == "_hap._tcp.", "Discovery searches the HomeKit service type")
            await rejects("Overlapping discoveries cannot replace pending continuation") { _ = try await discovery.discover() }
            discovery.netServiceBrowser(browser, didFind: service, moreComing: false)
            check(service.resolved, "Found services are resolved before parsing")
            discovery.netServiceDidResolveAddress(lamp)
            check(!browser.stopped, "Unrelated accessories cannot complete a targeted scan")
            discovery.netServiceDidResolveAddress(service)
            let devices = try await pending.value
            check(devices.count == 1 && devices.first?.id == "fixture", "Saved accessory match ends discovery early regardless of ID case")
            check(browser.stopped && browser.delegate == nil && service.stopped && service.delegate == nil, "Discovery cleans up browser and services")
        }
        do {
            let browser = FakeBrowser()
            let discovery = BonjourDiscovery(browserFactory: { browser }, timeout: .milliseconds(100))
            let pending = Task { try await discovery.discover() }
            for _ in 0..<1000 { if browser.searched { break }; await Task.yield() }
            let second = FakeService(domain: "local.", type: "_hap._tcp.", name: "A thermostat", port: 1234)
            second.record = NetService.data(fromTXTRecord: ["id": Data("other".utf8), "ci": Data("9".utf8)])
            second.rawAddresses = service.rawAddresses
            for item in [service, second, service] {
                discovery.netServiceBrowser(browser, didFind: item, moreComing: true)
                discovery.netServiceDidResolveAddress(item)
            }
            let devices = try await pending.value
            check(devices.map(\.id) == ["other", "fixture"], "Full discovery waits, sorts names, and deduplicates identities")
            let empty = try await discovery.discover()
            check(empty.isEmpty, "A subsequent discovery clears prior results")
        }
        do {
            let browser = FakeBrowser()
            let discovery = BonjourDiscovery(browserFactory: { browser })
            let pending = Task { try await discovery.discover() }
            for _ in 0..<1000 { if browser.searched { break }; await Task.yield() }
            discovery.netServiceBrowser(browser, didNotSearch: [:])
            await rejects("Bonjour search failure resolves caller with an error") { _ = try await pending.value }
            check(browser.stopped && browser.delegate == nil, "Failed discovery also releases browser")
        }
    }

    static func transportTests() async {
        let env = ProcessInfo.processInfo.environment
        let helper = HelperConnection(executableURL: URL(fileURLWithPath: env["TEST_PYTHON"]!), arguments: [env["TEST_HELPER_SCRIPT"]!], requestTimeout: .seconds(2))
        defer { helper.stop() }
        for command in ["hello", "fragmented", "wrong-id", "malformed"] {
            do { let result = try await helper.request(command); check(result["echo"] as? String == command, "Pipe RPC handles \(command)") }
            catch { fatalError("Unexpected helper failure: \(error)") }
        }
        await rejects("Helper rejection propagates to caller") { _ = try await helper.request("error") }
        let pending = Task { try await helper.request("wait") }
        for _ in 0..<1000 { if helper.hasPendingRequest { break }; await Task.yield() }
        await rejects("Concurrent helper requests are rejected") { _ = try await helper.request("hello") }
        helper.stop()
        await rejects("Stopping helper resolves outstanding request") { _ = try await pending.value }
        do { let result = try await helper.request("hello"); check(result["echo"] as? String == "hello", "Helper can restart after stop") } catch { fatalError("Restart failed") }
        await rejects("Oversized response is rejected") { _ = try await helper.request("oversize") }
        await rejects("Process exit resolves pending request") { _ = try await helper.request("exit") }
        let slow = HelperConnection(executableURL: URL(fileURLWithPath: env["TEST_PYTHON"]!), arguments: [env["TEST_HELPER_SCRIPT"]!], requestTimeout: .milliseconds(100))
        await rejects("Timeout resolves request without retry") { _ = try await slow.request("wait") }; slow.stop()
        let missing = HelperConnection(executableURL: URL(fileURLWithPath: "/nonexistent/ecobee-unit-test-helper"))
        await rejects("Missing helper executable produces an error") { _ = try await missing.request("hello") }; missing.stop()
    }
}
