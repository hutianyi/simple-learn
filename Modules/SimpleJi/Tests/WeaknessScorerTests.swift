import XCTest
@testable import WordMemoryCards

final class WeaknessScorerTests: XCTestCase {
    func testUnseenUsesNeutralScore() {
        XCTAssertEqual(WeaknessScorer.score(makeState()), 0.5, accuracy: 0.0001)
    }

    func testRecentMistakeRaisesWeakness() {
        let recentMistake = makeState(known: 4, unknown: 1, consecutive: 0, last: .unknown)
        let recentKnown = makeState(known: 4, unknown: 1, consecutive: 1, last: .known)
        XCTAssertGreaterThan(WeaknessScorer.score(recentMistake), WeaknessScorer.score(recentKnown))
    }

    func testConsecutiveKnownLowersWeakness() {
        let noStreak = makeState(known: 5, unknown: 2, consecutive: 0, last: .known)
        let streak = makeState(known: 5, unknown: 2, consecutive: 5, last: .known)
        XCTAssertLessThan(WeaknessScorer.score(streak), WeaknessScorer.score(noStreak))
    }

    private func makeState(
        known: Int = 0,
        unknown: Int = 0,
        consecutive: Int = 0,
        last: ReviewResult? = nil
    ) -> ReviewStateSnapshot {
        ReviewStateSnapshot(
            id: UUID(),
            wordID: UUID(),
            english: "apple",
            normalizedEnglish: "apple",
            chinese: "苹果",
            direction: .englishToChinese,
            level: 0,
            nextReviewDate: Date(),
            formalKnownCount: known,
            formalUnknownCount: unknown,
            consecutiveKnown: consecutive,
            lastFormalResult: last
        )
    }
}
