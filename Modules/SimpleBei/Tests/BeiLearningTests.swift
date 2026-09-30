import Foundation
import Testing
@testable import SimpleBei

struct BeiLearningTests {
    @Test(arguments: [1, 3, 5]) func finitePassesReadExactlyTheSelectedRange(_ total: Int) {
        var plan = BeiPlaybackPlan(first: 2, last: 4, totalPasses: total)
        var read: [Int] = []
        while !plan.finished, read.count < 100 { read.append(plan.current); plan.advance() }
        #expect(read == Array(repeating: [2, 3, 4], count: total).flatMap { $0 })
        #expect(plan.completedPasses == total)
    }
    @Test func infiniteSingleSentenceDoesNotFinish() {
        var plan = BeiPlaybackPlan(first: 3, last: 3, totalPasses: nil)
        for _ in 0..<20 { plan.advance() }
        #expect(!plan.finished && plan.current == 3 && plan.completedPasses == 20)
    }
    @Test func skippingDoesNotCountAnIncompletePass() {
        var plan = BeiPlaybackPlan(first: 0, last: 2, totalPasses: 1)
        plan.move(2); plan.advance()
        #expect(plan.completedPasses == 0 && !plan.finished && plan.current == 0)
        plan.advance(); plan.advance(); plan.advance()
        #expect(plan.completedPasses == 1 && plan.finished)
    }
    @Test(arguments: [1, 2, 3], [true, false])
    func everySentenceHasBothTurnsBeforeAdvancing(_ count: Int, _ appFirst: Bool) {
        var plan = BeiPracticePlan(first: 0, last: count - 1, appFirst: appFirst)
        var sentences: [Int] = [], turns: [BeiPracticePlan.Turn] = []
        while !plan.finished, turns.count < 20 {
            sentences.append(plan.current); turns.append(plan.turn); plan.advance()
        }
        #expect(sentences == (0..<count).flatMap { [$0, $0] })
        let pair: [BeiPracticePlan.Turn] = appFirst ? [.app, .child] : [.child, .app]
        #expect(turns == Array(repeating: pair, count: count).flatMap { $0 })
        #expect(plan.finished)
    }
    @Test(arguments: [true, false]) func finalSentenceWaitsForBothTurns(_ appFirst: Bool) {
        var plan = BeiPracticePlan(first: 0, last: 0, appFirst: appFirst)
        plan.advance(); #expect(!plan.finished && plan.current == 0)
        plan.advance(); #expect(plan.finished)
        let finished = plan; plan.advance(); #expect(plan == finished)
    }
    @Test func selfFirstWaitsForManualConfirmationOnEverySentence() {
        var plan = BeiPracticePlan(first: 0, last: 1, appFirst: false)
        #expect(plan.turn == .child && plan.childWaitDuration(afterSpokenDuration: 10) == nil)
        plan.advance(); #expect(plan.current == 0 && plan.turn == .app)
        plan.advance()
        #expect(plan.current == 1 && plan.turn == .child && plan.childWaitDuration(afterSpokenDuration: 10) == nil)
    }
    @Test func systemFirstWaitUsesActualSentenceDuration() {
        var plan = BeiPracticePlan(first: 0, last: 1, appFirst: true)
        #expect(plan.childWaitDuration(afterSpokenDuration: 10) == nil)
        plan.advance()
        #expect(plan.childWaitDuration(afterSpokenDuration: 10) == 15)
        #expect(plan.childWaitDuration(afterSpokenDuration: 0.5) == 3)
        plan.advance(); #expect(plan.current == 1 && plan.turn == .app)
    }
    @Test func hiddenAndBeginningHintsDoNotRevealShortAnswers() {
        #expect(BeiHintLevel.hidden.display("床前明月光", language: .chinese) == "•••")
        #expect(BeiHintLevel.beginning.display("春。", language: .chinese) == "…")
        #expect(BeiHintLevel.beginning.display("床前明月光", language: .chinese) == "床前…")
        #expect(BeiHintLevel.beginning.display("Hello春。", language: .chinese) == "H…")
        #expect(BeiHintLevel.beginning.display("Hello!", language: .english) == "…")
        #expect(BeiHintLevel.beginning.display("I am happy.", language: .english) == "I …")
    }
}
