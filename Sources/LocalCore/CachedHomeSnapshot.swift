import Foundation

/// One local display snapshot, never evidence of a live connection or permission to write.
public struct CachedHomeSnapshot: Codable {
    public let version: Int
    public let accessoryID: String
    public let savedAt: Date
    public let snapshot: HomeSnapshot

    public init(snapshot: HomeSnapshot, accessoryID: String, savedAt: Date = Date()) {
        version = 1
        self.accessoryID = accessoryID.lowercased()
        self.savedAt = savedAt
        // Occupancy history is unnecessary for a startup preview.
        self.snapshot = HomeSnapshot(name: snapshot.name, model: snapshot.model, firmware: snapshot.firmware,
            thermostats: snapshot.thermostats, sensors: snapshot.sensors.map {
                RoomSensor(id: $0.id, name: $0.name, temperature: $0.temperature, occupied: nil)
            })
    }

    public static func restore(_ data: Data, accessoryID: String, now: Date = Date()) -> Self? {
        guard data.count <= 512_000, !accessoryID.isEmpty,
              let cached = try? JSONDecoder().decode(Self.self, from: data),
              cached.version == 1, cached.accessoryID == accessoryID.lowercased(),
              cached.savedAt <= now.addingTimeInterval(300),
              now.timeIntervalSince(cached.savedAt) <= 7 * 24 * 60 * 60,
              !cached.snapshot.thermostats.isEmpty else { return nil }
        return cached
    }
}
