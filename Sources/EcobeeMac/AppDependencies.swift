import Foundation
import LocalCore

@MainActor protocol HelperRequesting {
    func request(_ command: String, _ fields: [String: Any]) async throws -> [String: Any]
    func stop()
}
extension HelperRequesting {
    func request(_ command: String) async throws -> [String: Any] { try await request(command, [:]) }
}
@MainActor protocol ThermostatDiscovering {
    func discover(matching deviceID: String?) async throws -> [DiscoveredDevice]
}
extension ThermostatDiscovering {
    func discover() async throws -> [DiscoveredDevice] { try await discover(matching: nil) }
}
protocol PairingStoring {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}
