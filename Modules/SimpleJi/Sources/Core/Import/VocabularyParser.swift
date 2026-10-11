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
            let pair = split(content).map {
                separatingPartOfSpeech(english: $0.english, chinese: $0.chinese)
            }
            guard let pair, isValid(english: pair.english, chinese: pair.chinese) else {
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

    static func separatingPartOfSpeech(english: String, chinese: String) -> (english: String, chinese: String) {
        let term = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaning = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only move known, dotted labels at a word boundary; preserve phrases and abbreviations.
        let label = #"(?:n|v|vt|vi|adj|adv|pron|prep|conj|interj|int|num|art|det|aux|modal|abbr|phr)\."#
        let pattern = #"(?i)(?<!\S)"# + label + #"(?:\s*(?:[/&、,，]\s*)?"# + label + #")*\s*$"#
        guard let range = term.range(of: pattern, options: .regularExpression) else {
            return (term, meaning)
        }
        let word = String(term[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let partOfSpeech = String(term[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (word, partOfSpeech + meaning)
    }

    static func chineseMeaningForSpeech(_ meaning: String) -> String {
        let abbreviations = #"(?:n|v|vt|vi|adj|adv|pron|prep|conj|interj|int|num|art|det|aux|modal|abbr|phr)"#
        let fullNames = #"(?:noun|verb|adjective|adverb|pronoun|preposition|conjunction|interjection|numeral|article|determiner|auxiliary|abbreviation|phrase)"#
        let chineseFollows = #"(?=\s*[:：]?\s*[\p{Han}（(])"#
        let label = #"(?:"# + abbreviations + #"[.．](?![A-Za-z0-9])|"#
            + #"(?:"# + abbreviations + "|" + fullNames + #")[.．]?"# + chineseFollows + ")"
        // Recognize labels only at the start of a meaning or after a clause separator.
        let pattern = #"(?i)(?:^|(?<=[;；,，、\n\r（(]))\s*"# + label
            + #"(?:\s*[/&、,，]\s*"# + label + #")*\s*[:：]?\s*(?=\S)"#
        return meaning.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        guard var chineseStart = line.firstIndex(where: { character in
            character.unicodeScalars.contains(where: isCJK)
        }) else { return nil }

        // Opening parentheses before the first Chinese character belong to the meaning.
        // Leave complete English parentheses, such as "word(s)", untouched.
        while chineseStart > line.startIndex {
            let previous = line.index(before: chineseStart)
            let character = line[previous]
            guard character.isWhitespace || character == "（" || character == "(" else { break }
            chineseStart = previous
        }

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
