import Foundation
import LocalCore

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAILED: \(label)") }
    checks += 1
    print("PASS: \(label)")
}
check(abs(DisplayUnit.fahrenheit.toCelsius(68) - 20) < 0.00001, "Fahrenheit to Celsius")
check(abs(DisplayUnit.fahrenheit.fromCelsius(20) - 68) < 0.00001, "Celsius to Fahrenheit")
check(DisplayUnit.celsius.toCelsius(20) == 20, "Celsius stays unchanged")
let field = try JSONDecoder().decode(ControlMetadata.self, from: Data(#"{"aid":1,"iid":4,"format":"float","minimum":7,"maximum":32,"step":0.5}"#.utf8))
check(field.quantized(DisplayUnit.fahrenheit.toCelsius(73)) == 23, "Fahrenheit target matches HAP step")
check(field.quantized(20.26) == 20.5, "Half-degree target quantization")
check(DisplayUnit.fahrenheit.text(nil) == "—", "Missing reading is not zero")
check(DisplayUnit.celsius.text(.nan) == "—", "Invalid reading is not displayed")
check(PreviewData.snapshot.firmware == "Demo", "Demo does not claim real firmware")
check(PreviewData.snapshot.thermostats.first?.allowedModes == [0, 1, 2, 3], "Modes follow characteristic metadata")
var thermostat = PreviewData.snapshot.thermostats[0]
thermostat.fan = 0
check(thermostat.fanRunning == true, "Active fan runs even in automatic fan mode")
for state in [0.0, 1.0] {
    thermostat.fanState = state
    check(thermostat.fanRunning == false, "Inactive or idle fan does not spin (\(state))")
}
for state in [nil, 3, Double.nan] as [Double?] {
    thermostat.fanState = state
    check(thermostat.fanRunning == nil, "Missing or invalid fan state stays unknown")
}
let systemCases: [(Double?, Double?, SystemIndicator)] = [
    (2, 2, .cooling(active: true)), (2, 0, .cooling(active: false)),
    (1, 1, .heating(active: true)), (1, 0, .heating(active: false)),
    (0, 0, .off), (0, 2, .off),
    (3, 1, .heating(active: true)), (3, 2, .cooling(active: true)),
    (3, 0, .automaticIdle), (2, nil, .unknown), (nil, 0, .unknown),
    (2, 9, .unknown)
]
for (mode, state, expected) in systemCases {
    thermostat.mode = mode; thermostat.state = state
    check(thermostat.systemIndicator() == expected, "System indicator: \(expected.description)")
}
thermostat.mode = 2; thermostat.state = 2
check(thermostat.systemIndicator(isCurrent: false) == .unknown, "Disconnected reading does not claim active cooling")
let now = Date(timeIntervalSince1970: 1_700_000_000)
var run = FanRun(accessoryID: "test-accessory", thermostatID: "1.10", duration: .fifteen, now: now)
check(run.endsAt == now.addingTimeInterval(900), "Timed run calculates its deadline")
check(!run.claimReturn(at: now, accessoryID: "test-accessory", connected: true, busy: false), "Fan stays on before deadline")
let expired = run.endsAt.addingTimeInterval(300)
check(!run.claimReturn(at: expired, accessoryID: "different-accessory", connected: true, busy: false), "Saved timer cannot control a different accessory")
check(!run.claimReturn(at: expired, accessoryID: "test-accessory", connected: false, busy: false), "Disconnected expiration stays pending")
check(!run.claimReturn(at: expired, accessoryID: "test-accessory", connected: true, busy: true), "Timer waits for other commands")
let savedRun = try JSONEncoder().encode(run)
var restored = try JSONDecoder().decode(FanRun.self, from: savedRun)
check(restored == run, "Pending deadline survives restart unchanged")
check(restored.claimReturn(at: expired, accessoryID: "test-accessory", connected: true, busy: false), "Overdue timer returns to Auto after reconnect or wake")
check(!restored.claimReturn(at: expired, accessoryID: "test-accessory", connected: true, busy: false), "Uncertain Auto write is not automatically retried")
var attempted = try JSONDecoder().decode(FanRun.self, from: JSONEncoder().encode(restored))
check(!attempted.claimReturn(at: expired, accessoryID: "test-accessory", connected: true, busy: false), "Restart does not replay an attempted Auto write")
run.markReturnAttempted()
check(!run.claimReturn(at: expired, accessoryID: "test-accessory", connected: true, busy: false), "Manual stop prevents duplicate automatic stop")
var exactDeadline = FanRun(accessoryID: "test-accessory", thermostatID: "1.10", duration: .twoHours, now: now)
check(exactDeadline.claimReturn(at: now.addingTimeInterval(7200), accessoryID: "test-accessory", connected: true, busy: false), "Two-hour timer can expire exactly at its deadline")
var stop = FanFeedback(thermostatID: "1.10", action: .stop)
check(stop.isPending && stop.message == "Stopping fan…", "Stop provides immediate pending feedback")
stop.observe(mode: 0, running: false, now: now)
check(stop.phase == .requesting, "Pre-command readings cannot confirm a stop")
stop.completeRequest(accepted: true, now: now)
stop.observe(mode: 0, running: true, now: now.addingTimeInterval(2))
check(stop.phase == .waiting, "Auto acknowledgment does not claim the physical fan stopped")
stop.observe(mode: 100, running: false, now: now.addingTimeInterval(3))
check(stop.phase == .waiting, "Stale On mode cannot confirm Auto")
stop.observe(mode: 0, running: nil, now: now.addingTimeInterval(4))
check(stop.phase == .waiting, "Unknown operation does not claim the fan stopped")
stop.observe(mode: 0, running: false, now: now.addingTimeInterval(6))
check(stop.phase == .confirmed && !stop.isPending, "Fresh Auto and inactive fan end pending feedback")
stop.observe(mode: 0, running: true, now: now.addingTimeInterval(10))
check(stop.phase == .continuing, "Later automatic fan operation does not retain an off message")
var delayedStop = FanFeedback(thermostatID: "1.10", action: .stop)
delayedStop.completeRequest(accepted: true, now: now)
delayedStop.expire(at: now.addingTimeInterval(29))
check(delayedStop.isPending, "Stop observation continues before its deadline")
delayedStop.expire(at: now.addingTimeInterval(30))
check(!delayedStop.isPending && delayedStop.phase == .unconfirmed, "Stop spinner expires even without a read response")
delayedStop.observe(mode: 0, running: true, now: now.addingTimeInterval(30))
check(delayedStop.phase == .continuing, "Running in Auto after timeout is explained")
delayedStop.connectionLost()
check(delayedStop.phase == .unconfirmed && !delayedStop.isPending, "Disconnection ends progress without claiming success")
delayedStop.observe(mode: 0, running: false, now: now.addingTimeInterval(60))
check(delayedStop.phase == .confirmed, "A later refresh can confirm a delayed stop")
var failedStop = FanFeedback(thermostatID: "1.10", action: .stop)
failedStop.completeRequest(accepted: false, now: now)
failedStop.observe(mode: 0, running: false, now: now)
check(failedStop.phase == .unconfirmed && !failedStop.isPending, "Failed write stays unconfirmed even with a cached off reading")
check(FanFeedback(thermostatID: "1.10", action: .stop).id != stop.id, "New fan requests have distinct feedback identities")
var start = FanFeedback(thermostatID: "1.10", action: .start)
check(start.isPending && start.message == "Starting fan…", "Run fan immediately shows starting feedback")
start.observe(mode: 100, running: true, now: now)
check(start.phase == .requesting, "Pre-command running readings cannot confirm Fan On")
start.completeRequest(accepted: true, now: now)
start.observe(mode: 100, running: false, now: now.addingTimeInterval(2))
check(start.phase == .waiting, "On acknowledgment waits for physical fan operation")
start.observe(mode: 0, running: true, now: now.addingTimeInterval(4))
check(start.phase == .waiting, "Automatic fan operation cannot confirm requested On mode")
start.observe(mode: nil, running: true, now: now.addingTimeInterval(6))
check(start.phase == .waiting, "Missing mode cannot confirm Fan On")
start.observe(mode: 100, running: nil, now: now.addingTimeInterval(8))
check(start.phase == .waiting, "Missing operation cannot confirm Fan On")
start.observe(mode: 100, running: true, now: now.addingTimeInterval(10))
check(start.phase == .confirmed && start.message == "Fan is running.", "Fresh On and active readings confirm startup")
start.observe(mode: 100, running: false, now: now.addingTimeInterval(12))
check(start.phase == .unconfirmed, "Later inactive reading removes running confirmation")
var delayedStart = FanFeedback(thermostatID: "1.10", action: .start)
delayedStart.completeRequest(accepted: true, now: now)
delayedStart.expire(at: now.addingTimeInterval(30))
check(!delayedStart.isPending && delayedStart.phase == .unconfirmed, "Startup progress is bounded to 30 seconds after acceptance")
delayedStart.observe(mode: 100, running: true, now: now.addingTimeInterval(40))
check(delayedStart.phase == .confirmed, "Later refresh can confirm delayed startup")
delayedStart.connectionLost()
check(delayedStart.phase == .unconfirmed, "Disconnect removes running confirmation")
var failedStart = FanFeedback(thermostatID: "1.10", action: .start)
failedStart.completeRequest(accepted: false, now: now)
failedStart.observe(mode: 100, running: true, now: now)
check(!failedStart.isPending && failedStart.phase == .unconfirmed, "Failed start cannot be confirmed by cached running readings")
let replacementStop = FanFeedback(thermostatID: "1.10", action: .stop)
check(replacementStop.id != start.id && replacementStop.message == "Stopping fan…", "Stop replaces startup feedback with its own request")
let cached = CachedHomeSnapshot(snapshot: PreviewData.snapshot, accessoryID: "TEST-PAIRING", savedAt: now)
let cachedData = try JSONEncoder().encode(cached)
let recovered = CachedHomeSnapshot.restore(cachedData, accessoryID: "test-pairing", now: now.addingTimeInterval(10))
check(recovered?.snapshot.thermostats.first?.current == PreviewData.snapshot.thermostats.first?.current, "Startup cache restores last temperature")
check(recovered?.savedAt == now, "Cached readings retain their original timestamp")
check(recovered?.snapshot.thermostats.first?.fields["fan"] != nil, "Cached layout preserves fan-control capability")
check(CachedHomeSnapshot.restore(cachedData, accessoryID: "another-thermostat", now: now) == nil, "A cache cannot be restored for a different pairing")
check(CachedHomeSnapshot.restore(cachedData, accessoryID: "", now: now) == nil, "No pairing identity means no cache")
check(CachedHomeSnapshot.restore(cachedData, accessoryID: "test-pairing", now: now.addingTimeInterval(7 * 86400 + 1)) == nil, "Readings older than seven days are discarded")
check(CachedHomeSnapshot.restore(cachedData, accessoryID: "test-pairing", now: now.addingTimeInterval(-301)) == nil, "Implausibly future-dated cache is discarded")
check(CachedHomeSnapshot.restore(Data("broken JSON".utf8), accessoryID: "test-pairing", now: now) == nil, "Corrupt cache does not block startup")
check(CachedHomeSnapshot.restore(Data(repeating: 32, count: 512_001), accessoryID: "test-pairing", now: now) == nil, "Oversized cache is rejected")
var cachedJSON = try JSONSerialization.jsonObject(with: cachedData) as! [String: Any]
cachedJSON["version"] = 99
let invalidVersionData = try JSONSerialization.data(withJSONObject: cachedJSON)
check(CachedHomeSnapshot.restore(invalidVersionData, accessoryID: "test-pairing", now: now) == nil, "Unsupported cache version is discarded")
var sampleJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PreviewData.snapshot)) as! [String: Any]
sampleJSON["sensors"] = [["id": "sensor-test", "name": "Demo room", "temperature": 22.0, "occupied": true]]
let occupiedSnapshot = try JSONDecoder().decode(HomeSnapshot.self, from: JSONSerialization.data(withJSONObject: sampleJSON))
let privacyCache = CachedHomeSnapshot(snapshot: occupiedSnapshot, accessoryID: "test-pairing", savedAt: now)
check(privacyCache.snapshot.sensors.first?.occupied == nil, "Startup cache does not store occupancy history")
check(privacyCache.snapshot.sensors.first?.temperature == 22, "Sensor temperature remains available for the dimmed preview")
sampleJSON["thermostats"] = []
let emptySnapshot = try JSONDecoder().decode(HomeSnapshot.self, from: JSONSerialization.data(withJSONObject: sampleJSON))
let emptyData = try JSONEncoder().encode(CachedHomeSnapshot(snapshot: emptySnapshot, accessoryID: "test-pairing", savedAt: now))
check(CachedHomeSnapshot.restore(emptyData, accessoryID: "test-pairing", now: now) == nil, "Empty thermostat cache is discarded")
let editThermostat = PreviewData.snapshot.thermostats[0]
let unchanged = try ThermostatCommands.changes(for: editThermostat, mode: 3, target: 22, heat: 20, cool: 24)
check(unchanged.isEmpty, "Unchanged draft generates no command")
let offChanges = try ThermostatCommands.changes(for: editThermostat, mode: 0, target: 25, heat: 21, cool: 26)
check(offChanges == ["mode": 0], "Switching Off never sends temperature drafts")
let coolChanges = try ThermostatCommands.changes(for: editThermostat, mode: 2, target: 23.24, heat: 20, cool: 24)
check(coolChanges == ["mode": 2, "target": 23.2], "Cooling changes include quantized target and mode only")
let autoChanges = try ThermostatCommands.changes(for: editThermostat, mode: 3, target: 28, heat: 21, cool: 25)
check(autoChanges == ["heat": 21, "cool": 25], "Auto mode writes thresholds instead of target")
do {
    _ = try ThermostatCommands.changes(for: editThermostat, mode: 3, target: 22, heat: 25, cool: 24)
    fatalError("Crossed threshold should fail")
} catch { check(error.localizedDescription.contains("below"), "Crossed draft thresholds fail before sending") }
let adjustmentField = editThermostat.fields["target"]!
check(ThermostatCommands.adjusted(32, direction: 1, unit: .celsius, metadata: adjustmentField) == 32, "Temperature increment clamps to device maximum")
check(ThermostatCommands.adjusted(7, direction: -1, unit: .celsius, metadata: adjustmentField) == 7, "Temperature decrement clamps to device minimum")
check(ThermostatCommands.adjusted(20, direction: 1, unit: .celsius, metadata: adjustmentField) == 20.5, "Celsius draft step is half a degree")
check(ThermostatCommands.adjusted(20, direction: 1, unit: .fahrenheit, metadata: adjustmentField) == 20.6, "Fahrenheit draft step converts and quantizes")
for duration in FanRunDuration.allCases { check(!duration.title.isEmpty && duration.id == duration.rawValue, "Duration label and identifier: \(duration.rawValue)") }
check(DisplayUnit.celsius.symbol == "°C" && DisplayUnit.fahrenheit.symbol == "°F", "Display units have correct labels")
var limitedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(editThermostat)) as! [String: Any]
limitedJSON["fields"] = [:]
let unsupported = try JSONDecoder().decode(LocalThermostat.self, from: JSONSerialization.data(withJSONObject: limitedJSON))
check(unsupported.allowedModes.isEmpty, "Missing mode capability has no allowed selections")
let unsupportedChanges = try ThermostatCommands.changes(for: unsupported, mode: 3, target: 25, heat: 21, cool: 25)
check(unsupportedChanges.isEmpty, "Missing temperature controls cannot generate draft writes")
check(DisplayUnit.celsius.id == "celsius" && DisplayUnit.fahrenheit.id == "fahrenheit", "Unit picker identities remain stable")
check(DisplayUnit.fahrenheit.text(20) == "68°" && DisplayUnit.celsius.text(20) == "20°", "Live readings format in the selected unit")
for (mode, state, name, status) in [(0.0, 0.0, "Off", "Idle"), (1, 1, "Heat", "Heating"), (2, 2, "Cool", "Cooling"), (3, 99, "Auto", "Unknown")] {
    thermostat.mode = mode; thermostat.state = state
    check(thermostat.modeName == name && thermostat.stateName == status, "Mode and state labels: \(name)")
}
thermostat.mode = nil; thermostat.state = nil
check(thermostat.modeName == "Unknown" && thermostat.stateName == "Unknown", "Missing mode and state have honest labels")
for action in [FanFeedback.Action.start, .stop] {
    for accepted in [false, true] {
        var feedback = FanFeedback(thermostatID: "fixture", action: action)
        feedback.completeRequest(accepted: accepted, now: now)
        feedback.expire(at: now.addingTimeInterval(31))
        let prefix = action == .start ? (accepted ? "Fan On requested." : "Fan On could not be confirmed.") : (accepted ? "Auto requested." : "Stop could not be confirmed.")
        check(feedback.message.hasPrefix(prefix), "Unconfirmed fan message distinguishes write acceptance and action")
    }
}
let unrestricted = try JSONDecoder().decode(ControlMetadata.self, from: Data(#"{"aid":1,"iid":4,"format":"float"}"#.utf8))
check(ThermostatCommands.adjusted(35, direction: 1, unit: .celsius, metadata: unrestricted) == 35, "Missing metadata still enforces app temperature ceiling")
check(ThermostatCommands.adjusted(4, direction: -1, unit: .celsius, metadata: unrestricted) == 4, "Missing metadata still enforces app temperature floor")
print("\(checks) Swift checks passed.")
