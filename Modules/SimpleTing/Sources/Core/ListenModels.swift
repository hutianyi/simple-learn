import Foundation

enum PlaybackOrder: String, Codable, CaseIterable, Identifiable {
    case forward, reverse, shuffle
    var id: String { rawValue }
    var title: String { switch self { case .forward: "正序"; case .reverse: "倒序"; case .shuffle: "随机" } }
}

enum SpeechRatePreset: String, Codable, CaseIterable, Identifiable {
    case slow, standard, faster, fast
    var id: String { rawValue }
    var title: String { switch self { case .slow: "慢速"; case .standard: "标准"; case .faster: "较快"; case .fast: "快速" } }
    // These are synthesis parameters, not promises of linear playback multipliers.
    var rate: Float { switch self { case .slow: 0.25; case .standard: 0.32; case .faster: 0.38; case .fast: 0.44 } }
}

struct ListenPreferences: Codable, Equatable {
    var voiceIdentifier: String
    var rate: SpeechRatePreset
    var order: PlaybackOrder
    var loopEnabled: Bool
    var lastPlayedID: UUID?
}

struct ListenArticle: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var articleNumber: Int
    var title: String
    var rawMarkdown: String
    var speechText: String
}

struct ListenDay: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var dayNumber: Int?
    var title: String
    var sourceFileName: String
    var sourceKey: String
    var sourceMarkdown: String
    var firstImportedAt: Date
    var updatedAt: Date
    var importSequence: Int64
    var articles: [ListenArticle]
}

struct ImportDraft: Identifiable, Sendable {
    let id = UUID()
    let sourceFileName: String
    let sourceMarkdown: String
    let dayNumber: Int?
    let sourceKey: String
    let title: String
    let articles: [ListenArticle]
}

enum ListenError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct ListenLibrary: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var parserVersion = 1
    var nextImportSequence: Int64 = 1
    var days: [ListenDay] = []

    var newestFirst: [ListenDay] { days.sorted { $0.importSequence > $1.importSequence } }
    var articlesNewestFirst: [ListenArticle] {
        newestFirst.flatMap { $0.articles.sorted { $0.articleNumber > $1.articleNumber } }
    }
    func day(for articleID: UUID) -> ListenDay? { days.first { $0.articles.contains { $0.id == articleID } } }
    func article(_ id: UUID) -> ListenArticle? { day(for: id)?.articles.first { $0.id == id } }

    func validate() throws {
        guard schemaVersion == 1, parserVersion == 1, nextImportSequence > 0 else {
            throw ListenError.message("文章库格式不受支持，原文件已保留。")
        }
        let articles = days.flatMap(\.articles)
        guard Set(days.map(\.id)).count == days.count,
              Set(days.map(\.sourceKey)).count == days.count,
              Set(days.map(\.importSequence)).count == days.count,
              Set(articles.map(\.id)).count == articles.count,
              days.allSatisfy({ $0.importSequence > 0 && $0.importSequence < nextImportSequence && !$0.sourceKey.isEmpty && !$0.articles.isEmpty }),
              days.allSatisfy({ Set($0.articles.map(\.articleNumber)).count == $0.articles.count }),
              articles.allSatisfy({ $0.articleNumber > 0 && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ListenError.message("文章库数据不完整，原文件已保留。")
        }
    }

    func importing(_ drafts: [ImportDraft], at date: Date = Date()) throws -> ListenLibrary {
        guard !drafts.isEmpty else { throw ListenError.message("请先粘贴要导入的文章。") }
        guard Set(drafts.map(\.sourceKey)).count == drafts.count else {
            throw ListenError.message("本批次有重复 Day 或文件名，请只保留其中一份。")
        }
        var result = self
        for draft in drafts {
            var articles = draft.articles.sorted { $0.articleNumber < $1.articleNumber }
            if let index = result.days.firstIndex(where: { $0.sourceKey == draft.sourceKey }) {
                let old = result.days[index]
                for i in articles.indices {
                    if let prior = old.articles.first(where: { $0.articleNumber == articles[i].articleNumber }) { articles[i].id = prior.id }
                }
                result.days[index] = ListenDay(id: old.id, dayNumber: draft.dayNumber, title: draft.title,
                    sourceFileName: draft.sourceFileName, sourceKey: draft.sourceKey, sourceMarkdown: draft.sourceMarkdown,
                    firstImportedAt: old.firstImportedAt, updatedAt: date, importSequence: old.importSequence, articles: articles)
            } else {
                guard result.nextImportSequence < Int64.max else { throw ListenError.message("入库序号已达到上限。") }
                result.days.append(ListenDay(dayNumber: draft.dayNumber, title: draft.title, sourceFileName: draft.sourceFileName,
                    sourceKey: draft.sourceKey, sourceMarkdown: draft.sourceMarkdown, firstImportedAt: date,
                    updatedAt: date, importSequence: result.nextImportSequence, articles: articles))
                result.nextImportSequence += 1
            }
        }
        try result.validate()
        return result
    }
}

enum ListenRegex {
    static func captures(_ pattern: String, _ text: String, insensitive: Bool = false) -> [String]? {
        let regex = try! NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : [])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    static func heading(_ line: String) -> String? {
        guard let captures = captures("^ {0,3}#{1,6}[\\t ]+(.+?)\\s*$", line) else { return nil }
        return replacing("\\s+#+\\s*$", in: captures[1], with: "").trimmingCharacters(in: .whitespaces)
    }
}
