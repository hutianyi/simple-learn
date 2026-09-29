import Foundation

enum EnglishNormalizer {
    static func normalize(_ value: String) -> String {
        let apostrophesUnified = value
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        let normalized = apostrophesUnified.precomposedStringWithCompatibilityMapping
        let collapsed = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
