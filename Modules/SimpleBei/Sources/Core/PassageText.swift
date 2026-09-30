import Foundation
import NaturalLanguage

enum PassageText {
    static func suggestedLanguage(_ source: String) -> PassageLanguage {
        NLLanguageRecognizer.dominantLanguage(for: source) == .english ? .english : .chinese
    }

    static func make(title: String, body: String, language: PassageLanguage, layout: PassageLayout) throws -> Passage {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let passage = Passage(title: cleanTitle.isEmpty ? String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)) : cleanTitle,
            body: body, language: language, layout: layout, units: split(body, language: language, layout: layout))
        try validate(passage)
        return passage
    }

    static func split(_ source: String, language: PassageLanguage, layout: PassageLayout) -> [PassageUnit] {
        var result: [PassageUnit] = []
        source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: .byParagraphs) { _, range, _, _ in
            let paragraph = result.last.map { $0.paragraph + 1 } ?? 0
            if layout == .poem {
                append(range, paragraph: paragraph, source: source, to: &result)
            } else if language == .english {
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = source
                tokenizer.setLanguage(.english)
                tokenizer.enumerateTokens(in: range) { sentence, _ in
                    append(sentence, paragraph: paragraph, source: source, to: &result)
                    return true
                }
            } else {
                var start = range.lowerBound
                var cursor = start
                while cursor < range.upperBound {
                    let character = source[cursor]
                    cursor = source.index(after: cursor)
                    if "。！？!?".contains(character) {
                        while cursor < range.upperBound, "。！？!?”’\"」』）)".contains(source[cursor]) { cursor = source.index(after: cursor) }
                        append(start..<cursor, paragraph: paragraph, source: source, to: &result)
                        start = cursor
                    }
                }
                append(start..<range.upperBound, paragraph: paragraph, source: source, to: &result)
            }
        }
        return result
    }

    private static func append(_ range: Range<String.Index>, paragraph: Int, source: String, to units: inout [PassageUnit]) {
        var start = range.lowerBound, end = range.upperBound
        while start < end, source[start].isWhitespace { start = source.index(after: start) }
        while start < end, source[source.index(before: end)].isWhitespace { end = source.index(before: end) }
        guard start < end else { return }
        let ns = NSRange(start..<end, in: source)
        units.append(PassageUnit(location: ns.location, length: ns.length, paragraph: paragraph))
    }

    static func validate(_ passage: Passage) throws {
        guard !passage.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !passage.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              passage.contentVersion > 0, !passage.units.isEmpty,
              passage.editedAt.timeIntervalSince1970.isFinite,
              Set(passage.units.map(\.id)).count == passage.units.count else {
            throw BeiError.invalid("标题、正文或分句结构无效。")
        }
        var previousEnd = passage.body.startIndex
        var previousParagraph = -1
        let utf16Count = passage.body.utf16.count
        for unit in passage.units {
            guard unit.location >= 0, unit.length > 0, unit.location <= utf16Count,
                  unit.length <= utf16Count - unit.location,
                  let range = Range(unit.range, in: passage.body), range.lowerBound >= previousEnd,
                  unit.paragraph >= 0, unit.paragraph >= previousParagraph,
                  !passage.body[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  passage.body[previousEnd..<range.lowerBound].allSatisfy(\.isWhitespace) else {
                throw BeiError.invalid("分句范围重叠、越界或遗漏正文，请重新预览分句。")
            }
            // Foundation can accept UTF-16 scalar boundaries inside a grapheme; UI uses whole characters.
            guard passage.body.indices.contains(range.lowerBound),
                  range.upperBound == passage.body.endIndex || passage.body.indices.contains(range.upperBound) else {
                throw BeiError.invalid("分句不能切开一个完整字符。")
            }
            previousEnd = range.upperBound
            previousParagraph = unit.paragraph
        }
        guard passage.body[previousEnd...].allSatisfy(\.isWhitespace) else { throw BeiError.invalid("分句遗漏正文结尾。") }
    }

    static func merge(_ index: Int, in passage: inout Passage) throws {
        guard passage.units.indices.contains(index), index + 1 < passage.units.count else { return }
        let next = passage.units[index + 1]
        passage.units[index].length = next.location + next.length - passage.units[index].location
        passage.units.remove(at: index + 1)
        try validate(passage)
    }

    static func divide(_ index: Int, afterCharacters count: Int, in passage: inout Passage) throws {
        guard passage.units.indices.contains(index) else { return }
        let unit = passage.units[index]
        let text = unit.text(in: passage.body)
        guard count > 0, count < text.count else { throw BeiError.invalid("请选择句子中间的分句位置。") }
        let offset = text.prefix(count).utf16.count
        passage.units[index].length = offset
        passage.units.insert(PassageUnit(location: unit.location + offset, length: unit.length - offset, paragraph: unit.paragraph), at: index + 1)
        try validate(passage)
    }
}
