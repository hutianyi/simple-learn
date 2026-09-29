import Foundation
import Testing
@testable import SimpleLianCore

@Test func parsesFencedPayload() throws {
    let input = """
    下面是题库：
    ```simplelian-json
    {"schema_version":1,"batch_title":"测试","groups":[]}
    ```
    """
    let payload = try ImportParser.parse(input)
    #expect(payload.batchTitle == "测试")
}

@Test func rejectsMultipleBlocks() {
    let input = "```simplelian-json\n{}\n```\n```simplelian-json\n{}\n```"
    #expect(throws: ImportParserError.multipleFencedBlocks) { try ImportParser.parse(input) }
}

@Test func validatesVariantWarnings() {
    let original = QuestionPayload(questionID: "o1", promptMarkdown: "题", answerMarkdown: "答", explanationMarkdown: "解")
    let payload = SimpleLianPayload(schemaVersion: 1, batchTitle: "批次", groups: [.init(groupID: "g1", title: "题型", original: original, variants: [])])
    let report = PayloadValidator.validate(payload)
    #expect(report.canImport)
    #expect(report.warnings.count == 3)
}

@Test func schedulesThreeIndependentCorrectAnswers() {
    let calendar = Calendar.gregorianUTC
    var state = ReviewSnapshot()
    state = ReviewScheduler.apply(.formalCorrect(day: "2026-09-01"), to: state, calendar: calendar)
    #expect(state.creditedCorrectCount == 1)
    #expect(state.nextReviewDay == "2026-09-08")
    state = ReviewScheduler.apply(.formalCorrect(day: "2026-09-08"), to: state, calendar: calendar)
    #expect(state.creditedCorrectCount == 2)
    #expect(state.nextReviewDay == "2026-09-22")
    state = ReviewScheduler.apply(.formalCorrect(day: "2026-09-22"), to: state, calendar: calendar)
    #expect(state.status == .mastered)
    #expect(state.nextReviewDay == nil)
}

@Test func wrongAndCorrectionDoNotEarnMasteryCredit() {
    let calendar = Calendar.gregorianUTC
    let scheduled = ReviewSnapshot(status: .scheduled, creditedCorrectCount: 2, nextReviewDay: "2026-09-01", lastCreditedDay: "2026-08-18")
    let wrong = ReviewScheduler.apply(.formalWrong(day: "2026-09-01"), to: scheduled, calendar: calendar)
    #expect(wrong.status == .pendingCorrection)
    #expect(wrong.creditedCorrectCount == 0)
    let corrected = ReviewScheduler.apply(.correctionSucceeded(day: "2026-09-01"), to: wrong, calendar: calendar)
    #expect(corrected.status == .scheduled)
    #expect(corrected.creditedCorrectCount == 0)
    #expect(corrected.nextReviewDay == "2026-09-04")
}

@Test func sameDayCannotReceiveCreditTwice() {
    let state = ReviewSnapshot(status: .scheduled, creditedCorrectCount: 1, nextReviewDay: "2026-09-08", lastCreditedDay: "2026-09-08")
    let next = ReviewScheduler.apply(.formalCorrect(day: "2026-09-08"), to: state)
    #expect(next == state)
}

@Test func selectorPrefersUnseenAndKindByStage() {
    let old = Date(timeIntervalSince1970: 100)
    let nearSeen = SelectionCandidate(id: UUID(), kind: .near, lastPresentedAt: old)
    let nearNew = SelectionCandidate(id: UUID(), kind: .near)
    let transfer = SelectionCandidate(id: UUID(), kind: .transfer)
    #expect(QuestionSelector.choose(from: [nearSeen, nearNew, transfer], creditedCorrectCount: 0)?.id == nearNew.id)
    #expect(QuestionSelector.choose(from: [nearSeen, nearNew, transfer], creditedCorrectCount: 1)?.id == transfer.id)
}

@Test func parsesSimpleMarkdownTable() {
    let table = MarkdownTableParser.parse(["| 项目 | 数值 |", "| --- | ---: |", "| 苹果 | 3 |"])
    #expect(table?.headers == ["项目", "数值"])
    #expect(table?.rows == [["苹果", "3"]])
}
