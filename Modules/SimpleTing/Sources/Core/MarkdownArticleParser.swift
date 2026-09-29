import Foundation

enum MarkdownArticleParser {
    static func parsePastedText(_ text: String) throws -> ImportDraft {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ListenError.message("请先粘贴 Markdown 原文。")
        }
        let parsed = try parse(text, fileName: "粘贴文本")
        // Each confirmation appends one material; Day headings never identify or replace an older import.
        return ImportDraft(sourceFileName: "粘贴文本", sourceMarkdown: parsed.sourceMarkdown,
            dayNumber: nil, sourceKey: "paste:\(UUID().uuidString)",
            title: parsed.articles[0].title, articles: parsed.articles)
    }

    static func parse(_ text: String, fileName: String) throws -> ImportDraft {
        let source = text.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var articles: [ListenArticle] = []
        var number: Int?
        var title = ""
        var body: [String] = []
        var auxiliary = false
        var fence: String?
        let endTitles = Set(["reading comprehension", "answer key", "fact sources", "sources", "references"])

        func finish() throws {
            guard let articleNumber = number else { return }
            let markdown = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = try MarkdownCleaner.plainText(markdown)
            guard !spoken.isEmpty else { throw ListenError.message("Article \(articleNumber) 的正文为空。") }
            articles.append(ListenArticle(articleNumber: articleNumber, title: title, rawMarkdown: markdown, speechText: spoken))
            number = nil; title = ""; body = []
        }

        for line in source.components(separatedBy: "\n") {
            if let marker = ListenRegex.captures("^ {0,3}(`{3,}|~{3,})(.*)$", line) {
                if let current = fence {
                    if marker[1].first == current.first && marker[1].count >= current.count && marker[2].trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                } else { fence = marker[1] }
                continue
            }
            guard fence == nil else { continue }
            if let heading = ListenRegex.heading(line) {
                let normalized = ListenRegex.replacing("\\s+", in: heading, with: " ").trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":：")).lowercased()
                if endTitles.contains(normalized) { try finish(); auxiliary = true; continue }
                if let parts = ListenRegex.captures("^Article\\s+([1-9]\\d*)\\s*[:：—–-]\\s*(\\S.*)$", heading, insensitive: true) {
                    guard let value = Int(parts[1]) else { throw ListenError.message("Article 编号太大。") }
                    try finish(); auxiliary = false; number = value; title = try MarkdownCleaner.plainText(parts[2]); continue
                }
                if ListenRegex.captures("^Article\\s+\\d+(?:\\s*[:：—–-])?\\s*$", heading, insensitive: true) != nil {
                    if !auxiliary { throw ListenError.message("Article 标题不完整，请使用 Article 编号: 标题。") }
                    continue
                }
            }
            if number != nil { body.append(line) }
        }
        guard fence == nil else { throw ListenError.message("Markdown 代码块未闭合。") }
        try finish()
        guard !articles.isEmpty else { throw ListenError.message("没有找到可导入的 Article。") }
        guard Set(articles.map(\.articleNumber)).count == articles.count else { throw ListenError.message("文件中的 Article 编号重复。") }
        let stem = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ListenRegex.captures("(?:^|[^A-Za-z0-9])Day\\s*0*([1-9]\\d*)(?=$|[^A-Za-z0-9])", stem, insensitive: true)
        let dayNumber = parts.flatMap { Int($0[1]) }
        return ImportDraft(sourceFileName: fileName, sourceMarkdown: source, dayNumber: dayNumber,
            sourceKey: dayNumber.map { "day:\($0)" } ?? "file:\(stem.lowercased())",
            title: dayNumber.map { "Day \($0)" } ?? stem, articles: articles.sorted { $0.articleNumber < $1.articleNumber })
    }

    static func defaultOrder(_ drafts: [ImportDraft]) -> [ImportDraft] {
        drafts.sorted {
            if let a = $0.dayNumber, let b = $1.dayNumber, a != b { return a < b }
            if ($0.dayNumber != nil) != ($1.dayNumber != nil) { return $0.dayNumber != nil }
            return $0.sourceFileName.localizedStandardCompare($1.sourceFileName) == .orderedAscending
        }
    }
}
