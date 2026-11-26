import Foundation

/// Text keyed by BCP-47 language tag ("en", "fr-CA", "zh-Hant", ...).
/// Used for stop names and spoken-name overrides so multilingual announcements
/// are possible from day one.
public struct LocalizedText: Hashable, Codable, Sendable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public init(_ text: String, language: String) {
        self.values = [language: text]
    }

    public var isEmpty: Bool { values.isEmpty }

    /// Returns the first available text for the preferred languages, in order.
    /// Tries an exact tag match, then any tag sharing the language subtag
    /// (e.g. "fr" matches "fr-CA"). Deterministic when several regional variants exist.
    public func resolved(preferring languages: [String]) -> String? {
        for tag in languages {
            if let exact = values[tag] { return exact }
            let language = tag.split(separator: "-").first.map(String.init) ?? tag
            if let key = values.keys.sorted().first(where: { $0 == language || $0.hasPrefix(language + "-") }) {
                return values[key]
            }
        }
        return nil
    }
}
