import Foundation

enum DictationLanguage: String, Equatable {
    case chinese = "zh-CN"
    case english = "en-US"
}

enum DictationCore {
    private static let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: "\t"))

    static func parseWords(from text: String) -> [String] {
        text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func language(for text: String) -> DictationLanguage {
        let containsChinese = text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
        }
        return containsChinese ? .chinese : .english
    }

    static func repeatedSpeechText(for text: String) -> String {
        language(for: text) == .chinese ? "\(text)，\(text)" : "\(text). \(text)"
    }
}
