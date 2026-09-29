import FSRS
import XCTest
@testable import WordMemoryCards

final class SRSSchedulerTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_192_000)

    func testConfigurationIsExplicitlyFSRS6() {
        XCTAssertEqual(SRSScheduler.parameters.w, FSRSDefaults.defaultWv6)
        XCTAssertEqual(SRSScheduler.parameters.w.count, 21)
        XCTAssertEqual(SRSScheduler.parameters.requestRetention, 0.92)
        XCTAssertEqual(SRSScheduler.parameters.maximumInterval, 3_650)
        XCTAssertFalse(SRSScheduler.parameters.enableFuzz)
        XCTAssertFalse(SRSScheduler.parameters.enableShortTerm)
        XCTAssertEqual(FSRS(parameters: SRSScheduler.parameters).version, .v6)
    }

    func testNewKnownMapsToGoodAndProducesFutureDueDate() throws {
        let card = SRSScheduler.emptyCard(due: date)
        let decision = try SRSScheduler.decision(card: card, answer: .known, date: date)
        let expected = try FSRS(parameters: SRSScheduler.parameters)
            .next(card: card, now: date, grade: .good).card

        XCTAssertEqual(try SRSScheduler.decodeCard(decision.cardData), expected)
        XCTAssertGreaterThan(decision.nextReviewDate, date)
    }

    func testNewUnknownMapsToAgain() throws {
        let card = SRSScheduler.emptyCard(due: date)
        let decision = try SRSScheduler.decision(card: card, answer: .unknown, date: date)
        let expected = try FSRS(parameters: SRSScheduler.parameters)
            .next(card: card, now: date, grade: .again).card

        XCTAssertEqual(try SRSScheduler.decodeCard(decision.cardData), expected)
        XCTAssertEqual(decision.nextReviewDate, expected.due)
    }

    func testConsecutiveGoodIntervalsGrowDynamically() throws {
        var card = SRSScheduler.emptyCard(due: date)
        var intervals: [Int] = []

        for _ in 0..<5 {
            let decision = try SRSScheduler.decision(card: card, answer: .known, date: card.due)
            card = try SRSScheduler.decodeCard(decision.cardData)
            intervals.append(Int(decision.scheduledDays))
        }

        XCTAssertEqual(intervals, intervals.sorted())
        XCTAssertGreaterThan(intervals.last ?? 0, intervals.first ?? 0)
        XCTAssertNotEqual(Array(intervals.prefix(4)), [1, 3, 7, 14])
        XCTAssertLessThanOrEqual(intervals.last ?? 0, 3_650)
    }

    func testAgainUsesFSRSInsteadOfHalvingLegacyLevel() throws {
        var card = SRSScheduler.emptyCard(due: date)
        let learned = try SRSScheduler.decision(card: card, answer: .known, date: date)
        card = try SRSScheduler.decodeCard(learned.cardData)
        let forgotten = try SRSScheduler.decision(
            card: card,
            answer: .unknown,
            date: learned.nextReviewDate
        )
        let updated = try SRSScheduler.decodeCard(forgotten.cardData)

        XCTAssertEqual(updated.lapses, 1)
        XCTAssertGreaterThan(updated.stability, 0)
        XCTAssertGreaterThan(forgotten.nextReviewDate, learned.nextReviewDate)
    }

    func testTwentyKnownWordsAreNotForcedIntoTomorrowQueue() throws {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        var states: [ReviewStateSnapshot] = []

        for index in 0..<20 {
            let wordID = UUID()
            for direction in ReviewDirection.allCases {
                let decision = try SRSScheduler.decision(
                    card: SRSScheduler.emptyCard(due: date),
                    answer: .known,
                    date: date
                )
                states.append(
                    ReviewStateSnapshot(
                        id: UUID(),
                        wordID: wordID,
                        english: "word\(index)",
                        normalizedEnglish: "word\(index)",
                        chinese: "释义",
                        direction: direction,
                        level: 0,
                        nextReviewDate: decision.nextReviewDate,
                        formalKnownCount: 1,
                        formalUnknownCount: 0,
                        consecutiveKnown: 1,
                        lastFormalResult: .known
                    )
                )
            }
        }

        let queue = ReviewQueueBuilder.buildBaseQueue(
            from: states,
            sessionLimit: nil,
            today: tomorrow
        )
        XCTAssertTrue(queue.isEmpty)
    }
}
