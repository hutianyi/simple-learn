import Foundation

enum MarkdownCleaner {
    static func plainText(_ markdown: String) throws -> String {
        var result: [String] = []
        var fence: String?
        for line in markdown.components(separatedBy: .newlines) {
            if let marker = ListenRegex.captures("^ {0,3}(`{3,}|~{3,})(.*)$", line) {
                if let current = fence {
                    if marker[1].first == current.first && marker[1].count >= current.count && marker[2].trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                } else { fence = marker[1] }
                continue
            }
            guard fence == nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ListenRegex.captures("^(?:[-*_]\\s*){3,}$", trimmed) != nil || ListenRegex.captures("^\\[[^]]+\\]:", trimmed) != nil { continue }
            if trimmed.hasPrefix("|") || ListenRegex.captures("<(?!https?://)[A-Za-z/][^>]*>", trimmed) != nil {
                throw ListenError.message("文章包含暂不支持的表格或 HTML，请先整理为普通 Markdown 段落。")
            }
            let heading = ListenRegex.heading(line)
            var text = heading ?? line
            text = ListenRegex.replacing("!\\[[^]]*\\]\\([^)]*\\)", in: text, with: "")
            text = ListenRegex.replacing("!\\[[^]]*\\]\\[[^]]*\\]", in: text, with: "")
            text = ListenRegex.replacing("\\[([^]]+)\\]\\[[^]]*\\]", in: text, with: "$1")
            text = ListenRegex.replacing("^\\s*>\\s?", in: text, with: "")
            text = ListenRegex.replacing("^\\s*[-+*]\\s+", in: text, with: "")
            let attributed = try AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            text = ListenRegex.replacing("https?://[^\\s>]*[A-Za-z0-9/#=?&%_~-]", in: String(attributed.characters), with: "")
                .trimmingCharacters(in: .whitespaces)
            if heading != nil && !text.isEmpty && !".!?:;".contains(text.last!) { text += "." }
            result.append(text)
        }
        return ListenRegex.replacing("\\n{3,}", in: result.joined(separator: "\n"), with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
