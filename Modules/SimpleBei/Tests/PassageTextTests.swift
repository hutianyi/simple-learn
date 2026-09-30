import Foundation
import Testing
@testable import SimpleBei

struct PassageTextTests {
    @Test func chineseSentencesPreserveCommaAndClosingQuote() throws {
        let p = try PassageText.make(title: "", body: "“春天来了，花开了！”小鸟唱歌。\n第二段。", language: .chinese, layout: .prose)
        #expect(p.units.map { $0.text(in: p.body) } == ["“春天来了，花开了！”", "小鸟唱歌。", "第二段。"])
        #expect(p.units.map(\.paragraph) == [0, 0, 1])
        #expect(!p.title.isEmpty)
    }
    @Test func poetryKeepsLineAndRepeatingWords() throws {
        let body = "  看看花，看看树。\n\n看看花，看看树。\n"
        let p = try PassageText.make(title: "诗", body: body, language: .chinese, layout: .poem)
        #expect(p.body == body)
        #expect(p.units.count == 2)
        #expect(p.units[0].text(in: body) == p.units[1].text(in: body))
        #expect(p.units[0].id != p.units[1].id)
    }
    @Test func englishAbbreviationDecimalAndApostrophe() throws {
        let p = try PassageText.make(title: "Story", body: "Dr. Smith has 3.5 apples. I'm happy! Are you?", language: .english, layout: .prose)
        #expect(p.units.map { $0.text(in: p.body) } == ["Dr. Smith has 3.5 apples.", "I'm happy!", "Are you?"])
    }
    @Test func languageSuggestion() {
        #expect(PassageText.suggestedLanguage("The trees have new green leaves in spring.") == .english)
        #expect(PassageText.suggestedLanguage("春天来了，小树长出了新叶。") == .chinese)
    }
    @Test func englishParagraphsWithoutTerminalPunctuation() throws {
        let p = try PassageText.make(title: "Paragraphs", body: "First paragraph\nSecond paragraph\n\nThird paragraph", language: .english, layout: .prose)
        #expect(p.units.map { $0.text(in: p.body) } == ["First paragraph", "Second paragraph", "Third paragraph"])
        #expect(p.units.map(\.paragraph) == [0, 1, 2])
    }
    @Test func emptyTextRejected() {
        #expect(throws: (any Error).self) { try PassageText.make(title: "空", body: " \n", language: .chinese, layout: .prose) }
    }
    @Test func unicodeSplitAndMergeKeepOriginalRanges() throws {
        let source = "春🌿天 e\u{301}来了。第二句。"
        var p = try PassageText.make(title: "字符", body: source, language: .chinese, layout: .prose)
        try PassageText.divide(0, afterCharacters: 2, in: &p)
        #expect(p.units[0].text(in: source) == "春🌿")
        #expect(p.units[1].text(in: source) == "天 e\u{301}来了。")
        try PassageText.merge(0, in: &p)
        #expect(p.units[0].text(in: source) == "春🌿天 e\u{301}来了。")
        #expect(p.body == source)
    }
    @Test func selectedRangeDoesNotIncludeOtherSentences() throws {
        let p = try PassageText.make(title: "范围", body: "第一句。第二句。\n第三句。第四句。", language: .chinese, layout: .prose)
        #expect(p.selectedText(from: 1, through: 2) == "第二句。\n第三句。")
        #expect(p.selectedText(from: -1, through: 99).isEmpty)
        #expect(p.selectedText(from: 2, through: 1).isEmpty)
    }
    @Test func malformedAndOverflowRangesRejected() throws {
        let original = try PassageText.make(title: "范围", body: "第一句。第二句。", language: .chinese, layout: .prose)
        for range in [NSRange(location: -1, length: 1), NSRange(location: 0, length: Int.max), NSRange(location: Int.max, length: 1)] {
            var p = original; p.units[0].location = range.location; p.units[0].length = range.length
            #expect(throws: (any Error).self) { try PassageText.validate(p) }
        }
        var overlap = original; overlap.units[1].location = 0
        #expect(throws: (any Error).self) { try PassageText.validate(overlap) }
        var missing = original; missing.units.removeFirst()
        #expect(throws: (any Error).self) { try PassageText.validate(missing) }
    }
    @Test func splittingInsideGraphemeRejected() throws {
        var p = try PassageText.make(title: "组合字符", body: "e\u{301}。", language: .english, layout: .poem)
        p.units[0].location = 1; p.units[0].length -= 1
        #expect(throws: (any Error).self) { try PassageText.validate(p) }
    }
}
