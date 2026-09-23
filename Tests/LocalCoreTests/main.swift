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
print("\(checks) Swift checks passed.")
