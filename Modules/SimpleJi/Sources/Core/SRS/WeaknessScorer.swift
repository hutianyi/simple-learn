import Foundation

enum WeaknessScorer {
    static let unseenScore = 0.5

    static func score(_ state: ReviewStateSnapshot) -> Double {
        guard state.formalAttempts > 0 else { return unseenScore }

        var value = (Double(state.formalUnknownCount) + 0.5)
            / (Double(state.formalAttempts) + 1.0)

        if state.lastFormalResult == .unknown {
            value += 0.35
        }

        value -= Double(min(max(state.consecutiveKnown, 0), 5)) * 0.06
        return value
    }
}
