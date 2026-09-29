import Foundation

enum VocabularyParser {
    static func parse(_ text: String) -> VocabularyParseResult {
        let lines = text.components(separatedBy: .newlines)
        var entries: [ParsedVocabularyEntry] = []
        var unrecognized: [UnrecognizedVocabularyLine] = []
        var ignored = 0

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if shouldIgnore(trimmed) {
                ignored += 1
                continue
            }

            let content = removingBullet(from: trimmed)
            guard let pair = split(content), isValid(english: pair.english, chinese: pair.chinese) else {
                unrecognized.append(
                    UnrecognizedVocabularyLine(
                        lineNumber: lineNumber,
                        text: rawLine,
                        reason: "未找到有效的英文和中文释义"
                    )
                )
                continue
            }

            entries.append(
                ParsedVocabularyEntry(
                    lineNumber: lineNumber,
                    originalLine: rawLine,
                    english: pair.english,
                    chinese: pair.chinese
                )
            )
        }

        return VocabularyParseResult(
            totalLineCount: lines.count,
            ignoredLineCount: ignored,
            entries: entries,
            unrecognized: unrecognized
        )
    }

    static func isValid(english: String, chinese: String) -> Bool {
        isValidEnglish(english) && containsCJK(chinese)
    }

    private static func shouldIgnore(_ line: String) -> Bool {
        guard !line.isEmpty else { return true }
        if line.hasPrefix("#") { return true }
        if line == "---" || line == "***" { return true }
        return false
    }

    private static func removingBullet(from line: String) -> String {
        guard line.count >= 2 else { return line }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line
    }

    private static func split(_ line: String) -> (english: String, chinese: String)? {
        if let tab = line.firstIndex(of: "\t") {
            let left = String(line[..<tab]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !left.isEmpty, !right.isEmpty { return (left, right) }
        }

        for separator in [" - ", " — "] {
            if let range = line.range(of: separator) {
                let left = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty, !right.isEmpty { return (left, right) }
            }
        }

        guard let chineseStart = line.firstIndex(where: { character in
            character.unicodeScalars.contains(where: isCJK)
        }) else { return nil }

        let english = String(line[..<chineseStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        let chinese = String(line[chineseStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !english.isEmpty, !chinese.isEmpty else { return nil }
        return (english, chinese)
    }

    private static func isValidEnglish(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isCJK)
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
