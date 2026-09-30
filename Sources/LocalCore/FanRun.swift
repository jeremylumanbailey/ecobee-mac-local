import Foundation

public enum FanRunDuration: Int, CaseIterable, Identifiable {
    case fifteen = 15, thirty = 30, fortyFive = 45, oneHour = 60, twoHours = 120, continuous = 0
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .continuous: return "Until stopped"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        default: return "\(rawValue) minutes"
        }
    }
}

/// A Mac-managed return to Auto, not a hold programmed into the thermostat.
public struct FanRun: Codable, Equatable, Identifiable {
    public let id: UUID
    public let accessoryID: String
    public let thermostatID: String
    public let endsAt: Date
    public var startConfirmed = false
    public private(set) var returnAttempted = false

    public init(accessoryID: String, thermostatID: String, duration: FanRunDuration, now: Date = Date()) {
        precondition(duration != .continuous)
        id = UUID(); self.accessoryID = accessoryID; self.thermostatID = thermostatID
        endsAt = now.addingTimeInterval(Double(duration.rawValue) * 60)
    }

    /// Persist the claim before sending a command. An uncertain write is never retried automatically.
    public mutating func claimReturn(at now: Date, accessoryID: String, connected: Bool, busy: Bool) -> Bool {
        guard now >= endsAt, self.accessoryID == accessoryID, connected, !busy, !returnAttempted else { return false }
        returnAttempted = true
        return true
    }

    public mutating func markReturnAttempted() { returnAttempted = true }
}
