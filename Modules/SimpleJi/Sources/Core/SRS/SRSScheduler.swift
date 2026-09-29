import Foundation
import FSRS

struct SRSDecision: Equatable {
    let cardData: Data
    let nextReviewDate: Date
    let scheduledDays: Double
}

enum SRSScheduler {
    static let migrationVersion: Int16 = 1

    // swift-fsrs defaults to the 19-weight FSRS-5 model. Supplying the official
    // 21-weight vector is what explicitly opts this app into FSRS-6.
    static let parameters = FSRSParameters(
        requestRetention: 0.92,
        maximumInterval: 3_650,
        w: FSRSDefaults.defaultWv6,
        enableFuzz: false,
        enableShortTerm: false
    )

    static func emptyCard(due: Date) -> Card {
        Card(due: due)
    }

    static func decision(
        cardData: Data?,
        answer: ReviewResult,
        date: Date
    ) throws -> SRSDecision {
        let card = try cardData.map(decodeCard) ?? emptyCard(due: date)
        return try decision(card: card, answer: answer, date: date)
    }

    static func decision(
        card: Card,
        answer: ReviewResult,
        date: Date
    ) throws -> SRSDecision {
        let grade: Rating = answer == .known ? .good : .again
        let next = try FSRS(parameters: parameters).next(
            card: card,
            now: date,
            grade: grade
        ).card
        return SRSDecision(
            cardData: try encodeCard(next),
            nextReviewDate: next.due,
            scheduledDays: next.scheduledDays
        )
    }

    static func encodeCard(_ card: Card) throws -> Data {
        try JSONEncoder().encode(card)
    }

    static func decodeCard(_ data: Data) throws -> Card {
        try JSONDecoder().decode(Card.self, from: data)
    }
}
