import Foundation

enum PassageLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese, english
    var id: String { rawValue }
    var title: String { self == .chinese ? "中文" : "英文" }
    var locale: Locale { Locale(identifier: self == .chinese ? "zh-CN" : "en-US") }
}

enum PassageLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case prose, poem
    var id: String { rawValue }
    var title: String { self == .prose ? "课文" : "古诗（保留诗行）" }
}

struct PassageUnit: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var location: Int
    var length: Int
    var paragraph: Int
    var range: NSRange { NSRange(location: location, length: length) }
    func text(in source: String) -> String {
        guard let range = Range(range, in: source) else { return "" }
        return String(source[range])
    }
}

struct Passage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var body: String
    var language: PassageLanguage
    var layout: PassageLayout
    var units: [PassageUnit]
    var contentVersion = 1
    var editedAt = Date()
    var archived = false

    var preview: String { String(body.prefix(80)) }
    func hasSameContent(as other: Passage) -> Bool {
        title == other.title && body == other.body && language == other.language && layout == other.layout && archived == other.archived &&
            units.map { [$0.location, $0.length, $0.paragraph] } == other.units.map { [$0.location, $0.length, $0.paragraph] }
    }
    func selectedText(from first: Int, through last: Int) -> String {
        guard first >= 0, last >= first, last < units.count,
              let start = Range(units[first].range, in: body)?.lowerBound,
              let end = Range(units[last].range, in: body)?.upperBound else { return "" }
        return String(body[start..<end])
    }
}

struct BeiPreferences: Codable, Equatable {
    var chineseVoiceID: String?
    var englishVoiceID: String?
    var speechRate: Float = 0.45
    var sentencePause: Double = 0
    var paragraphPause: Double = 1
    var repeatPause: Double = 2
    // nil denotes an explicitly chosen infinite loop.
    var totalPasses: Int? = 3
    var fontSize: Double = 24
    func voiceID(for language: PassageLanguage) -> String? {
        language == .chinese ? chineseVoiceID : englishVoiceID
    }
}

struct BeiLibrary: Codable, Equatable {
    var schemaVersion = 1
    var passages: [Passage] = []
    var preferences = BeiPreferences()

    func validated() throws -> BeiLibrary {
        guard schemaVersion == 1 else { throw BeiError.invalid("课文库版本不支持。") }
        guard Set(passages.map(\.id)).count == passages.count else { throw BeiError.invalid("课文编号重复。") }
        for passage in passages { try PassageText.validate(passage) }
        let p = preferences
        guard p.speechRate.isFinite, (0.1...0.65).contains(p.speechRate),
              [p.sentencePause, p.paragraphPause, p.repeatPause].allSatisfy({ $0.isFinite && (0...60).contains($0) }),
              p.fontSize.isFinite, (16...48).contains(p.fontSize),
              p.totalPasses.map({ (1...10000).contains($0) }) ?? true else {
            throw BeiError.invalid("播放或显示设置无效。")
        }
        return self
    }
}

enum BeiError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}
