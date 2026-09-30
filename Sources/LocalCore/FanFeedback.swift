import Foundation

/// Tracks a single fan request separately from the thermostat's actual fan operation.
public struct FanFeedback: Equatable {
    public enum Phase: Equatable { case requesting, waiting, confirmed, continuing, unconfirmed }
    public enum Action: Equatable { case start, stop }
    public let action: Action
    public let id = UUID()
    public let thermostatID: String
    public private(set) var phase: Phase = .requesting
    public private(set) var accepted = false
    private var deadline: Date?
    public var isPending: Bool { phase == .requesting || phase == .waiting }
    public var message: String {
        switch phase {
        case .requesting, .waiting: return action == .start ? "Starting fan…" : "Stopping fan…"
        case .confirmed: return action == .start ? "Fan is running." : "Auto selected. Fan is off."
        case .continuing: return "Auto selected. The thermostat is still running the fan."
        case .unconfirmed:
            if action == .start {
                return accepted ? "Fan On requested. Running status could not be confirmed."
                    : "Fan On could not be confirmed. Check the connection before trying again."
            }
            return accepted ? "Auto requested. Fan status could not be confirmed."
                : "Stop could not be confirmed. Check the connection and try Stop / Auto again."
        }
    }
    public init(thermostatID: String, action: Action) {
        self.thermostatID = thermostatID; self.action = action
    }

    public mutating func completeRequest(accepted: Bool, now: Date) {
        self.accepted = accepted
        phase = accepted ? .waiting : .unconfirmed
        deadline = accepted ? now.addingTimeInterval(30) : nil
    }

    public mutating func observe(mode: Double?, running: Bool?, now: Date) {
        guard accepted else { return }
        let requestedMode: Double = action == .start ? 100 : 0
        if mode == requestedMode && running == (action == .start) { phase = .confirmed }
        else if !isPending || deadline.map({ now >= $0 }) == true {
            phase = action == .stop && mode == 0 && running == true ? .continuing : .unconfirmed
        }
    }

    public mutating func expire(at now: Date) {
        if phase == .waiting, let deadline, now >= deadline { phase = .unconfirmed }
    }

    public mutating func connectionLost() { phase = .unconfirmed }
}
