import Foundation

public struct MarkdownTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]
}

public enum MarkdownTableParser {
    public static func parse(_ lines: [String]) -> MarkdownTable? {
        guard lines.count >= 2 else { return nil }
        let headers = cells(in: lines[0])
        let separators = cells(in: lines[1])
        guard !headers.isEmpty, headers.count == separators.count,
              separators.allSatisfy({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " :-")).isEmpty && $0.contains("-") }) else { return nil }
        return MarkdownTable(headers: headers, rows: lines.dropFirst(2).map(cells))
    }

    private static func cells(in line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
