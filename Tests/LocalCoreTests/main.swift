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
print("\(checks) Swift checks passed.")
