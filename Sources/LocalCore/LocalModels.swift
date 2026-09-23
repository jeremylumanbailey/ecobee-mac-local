import Foundation

public struct DiscoveredDevice: Codable, Identifiable {
    public let id: String
    public let name: String
    public let model: String
    public let address: String
    public let available: Bool
    public let port: Int
    public let featureFlags: Int
    public let statusFlags: Int
    public let configNumber: Int
}
public struct HomeSnapshot: Codable {
    public let name: String
    public let model: String
    public let firmware: String
    public var thermostats: [LocalThermostat]
    public let sensors: [RoomSensor]
}
public struct RoomSensor: Codable, Identifiable {
    public let id: String
    public let name: String
    public let temperature: Double?
    public let occupied: Bool?
}
public struct LocalThermostat: Codable, Identifiable {
    public let id: String
    public let name: String
    public var current: Double?
    public var humidity: Double?
    public var mode: Double?
    public var state: Double?
    public var target: Double?
    public var heat: Double?
    public var cool: Double?
    public var fan: Double?
    public var fanState: Double?
    public var fanRunning: Bool? {
        switch fanState {
        case 2: return true
        case 0, 1: return false
        default: return nil
        }
    }
    public let fields: [String: ControlMetadata]
    public func systemIndicator(isCurrent: Bool = true) -> SystemIndicator {
        guard isCurrent else { return .unknown }
        if mode == 0 { return .off }
        switch state {
        case 1: return .heating(active: true)
        case 2: return .cooling(active: true)
        case 0:
            switch mode {
            case 1: return .heating(active: false)
            case 2: return .cooling(active: false)
            case 3: return .automaticIdle
            default: return .unknown
            }
        default: return .unknown
        }
    }
    public var modeName: String { Self.modeNames[Int(mode ?? -1)] ?? "Unknown" }
    public var stateName: String { [0: "Idle", 1: "Heating", 2: "Cooling"][Int(state ?? -1)] ?? "Unknown" }
    public static let modeNames = [0: "Off", 1: "Heat", 2: "Cool", 3: "Auto"]
    public var allowedModes: [Int] {
        guard let field = fields["mode"] else { return [] }
        return (field.validValues ?? [0, 1, 2, 3]).filter { value in
            value >= (field.minimum ?? 0) && value <= (field.maximum ?? 3)
        }.map(Int.init)
    }
}
public enum SystemIndicator: Equatable {
    case off, heating(active: Bool), cooling(active: Bool), automaticIdle, unknown
    public var description: String {
        switch self {
        case .off: return "System off"
        case .heating(let active): return active ? "Heating is running" : "Heating selected, currently idle"
        case .cooling(let active): return active ? "Cooling is running" : "Cooling selected, currently idle"
        case .automaticIdle: return "Automatic heating and cooling, currently idle"
        case .unknown: return "Current system status unavailable"
        }
    }
}

public struct ControlMetadata: Codable {
    public let aid: Int
    public let iid: Int
    public let format: String
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let validValues: [Double]?
    public func quantized(_ value: Double) -> Double {
        let increment = max(step ?? 0.1, 0.001)
        let base = minimum ?? 0
        return ((((value - base) / increment).rounded() * increment + base) * 1e6).rounded() / 1e6
    }
}
public enum DisplayUnit: String, CaseIterable, Identifiable {
    case fahrenheit, celsius
    public var id: String { rawValue }
    public var symbol: String { self == .celsius ? "°C" : "°F" }
    public func fromCelsius(_ value: Double) -> Double { self == .celsius ? value : value * 9 / 5 + 32 }
    public func toCelsius(_ value: Double) -> Double { self == .celsius ? value : (value - 32) * 5 / 9 }
    public func text(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return fromCelsius(value).formatted(.number.precision(.fractionLength(0...1))) + "°"
    }
}
public enum PreviewData {
    public static var snapshot: HomeSnapshot { try! JSONDecoder().decode(HomeSnapshot.self, from: Data(json.utf8)) }
    private static let json = #"""
    {"name":"My home","model":"Smart Thermostat Essential","firmware":"Demo","thermostats":[{"id":"1.10","name":"Living room","current":22.2,"humidity":43,"mode":3,"state":0,"fanState":2,"target":22,"heat":20,"cool":24,"fields":{"mode":{"aid":1,"iid":12,"format":"uint8","minimum":0,"maximum":3,"validValues":[0,1,2,3]},"target":{"aid":1,"iid":13,"format":"float","minimum":7,"maximum":32,"step":0.1},"heat":{"aid":1,"iid":14,"format":"float","minimum":7,"maximum":32,"step":0.1},"cool":{"aid":1,"iid":15,"format":"float","minimum":7,"maximum":32,"step":0.1},"resume":{"aid":1,"iid":17,"format":"bool"}}}],"sensors":[]}
    """#
}
