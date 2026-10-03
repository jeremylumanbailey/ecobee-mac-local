import Foundation

public enum ThermostatCommandError: LocalizedError {
    case crossedThresholds
    public var errorDescription: String? { "The heating target must be below the cooling target." }
}

/// Values for the UI's draft controls. The helper independently validates every write against fresh metadata.
public enum ThermostatCommands {
    public static func adjusted(_ value: Double, direction: Double, unit: DisplayUnit, metadata: ControlMetadata) -> Double {
        let step = unit == .celsius ? 0.5 : 1.0
        let raw = unit.toCelsius(unit.fromCelsius(value) + direction * step)
        return min(max(metadata.quantized(raw), max(metadata.minimum ?? 4, 4)), min(metadata.maximum ?? 35, 35))
    }
    public static func changes(for thermostat: LocalThermostat, mode: Int, target: Double, heat: Double, cool: Double) throws -> [String: Double] {
        var changes: [String: Double] = [:]
        if Double(mode) != thermostat.mode { changes["mode"] = Double(mode) }
        if mode == 3 {
            if let meta = thermostat.fields["heat"], heat != thermostat.heat { changes["heat"] = meta.quantized(heat) }
            if let meta = thermostat.fields["cool"], cool != thermostat.cool { changes["cool"] = meta.quantized(cool) }
        } else if mode != 0, let meta = thermostat.fields["target"], target != thermostat.target {
            changes["target"] = meta.quantized(target)
        }
        if !changes.isEmpty, mode == 3, heat >= cool { throw ThermostatCommandError.crossedThresholds }
        return changes
    }
}
