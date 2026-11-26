import Foundation

public struct Waypoint: Identifiable, Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case origin, destination, generated, manual
    }

    public enum NameSource: String, Codable, Sendable {
        case user, crossStreet, landmark, placeholder
    }

    public var id: UUID
    public var coordinate: GeoCoordinate
    public var name: LocalizedText
    /// Optional per-language phonetic/spoken override for TTS.
    public var spokenName: LocalizedText
    public var source: Source
    public var nameSource: NameSource
    /// Locked stops survive regeneration (manual edits, renamed stops).
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        coordinate: GeoCoordinate,
        name: LocalizedText,
        spokenName: LocalizedText = LocalizedText(),
        source: Source,
        nameSource: NameSource = .placeholder,
        isLocked: Bool = false
    ) {
        self.id = id
        self.coordinate = coordinate
        self.name = name
        self.spokenName = spokenName
        self.source = source
        self.nameSource = nameSource
        self.isLocked = isLocked
    }
}
