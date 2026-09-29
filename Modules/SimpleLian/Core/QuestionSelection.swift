import Foundation

public struct SelectionCandidate: Equatable, Sendable {
    public let id: UUID
    public let kind: VariantKind
    public let disabled: Bool
    public let lastPresentedAt: Date?

    public init(id: UUID, kind: VariantKind, disabled: Bool = false, lastPresentedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.disabled = disabled
        self.lastPresentedAt = lastPresentedAt
    }
}

public enum QuestionSelector {
    public static func choose(from candidates: [SelectionCandidate], creditedCorrectCount: Int, excluding: Set<UUID> = []) -> SelectionCandidate? {
        let active = candidates.filter { !$0.disabled && !excluding.contains($0.id) }
        let preferred: VariantKind = creditedCorrectCount == 0 ? .near : .transfer
        let pool = active.filter { $0.kind == preferred }.isEmpty ? active : active.filter { $0.kind == preferred }
        return pool.sorted {
            switch ($0.lastPresentedAt, $1.lastPresentedAt) {
            case (nil, nil): return $0.id.uuidString < $1.id.uuidString
            case (nil, _): return true
            case (_, nil): return false
            case (let lhs?, let rhs?): return lhs < rhs
            }
        }.first
    }
}
