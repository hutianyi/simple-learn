import Foundation

struct DictationResults {
    enum Mark: String, CaseIterable {
        case correct = "默对"
        case incorrect = "默错"
    }

    let words: [String]
    private(set) var marks: [Mark]

    init(words: [String] = []) {
        self.words = words
        marks = Array(repeating: .correct, count: words.count)
    }

    var correctCount: Int { marks.filter { $0 == .correct }.count }
    var incorrectWords: [String] {
        zip(words, marks).compactMap { word, mark in mark == .incorrect ? word : nil }
    }
    var canConfirm: Bool { !words.isEmpty }

    mutating func setMark(_ mark: Mark, at index: Int) {
        guard marks.indices.contains(index) else { return }
        marks[index] = mark
    }

    mutating func markAllCorrect() {
        marks = Array(repeating: .correct, count: words.count)
    }
}

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
