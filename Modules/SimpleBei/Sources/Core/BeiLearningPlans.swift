import Foundation

struct BeiPlaybackPlan: Equatable {
    let first: Int
    let last: Int
    let totalPasses: Int?
    private(set) var current: Int
    private(set) var completedPasses = 0
    private(set) var finished = false
    private var completePass = true
    init(first: Int, last: Int, totalPasses: Int?) {
        self.first = first; self.last = last; self.totalPasses = totalPasses; current = first
    }
    mutating func advance() {
        guard !finished else { return }
        if current < last { current += 1; return }
        if completePass { completedPasses += 1 }
        if let totalPasses, completedPasses >= totalPasses { finished = true; return }
        current = first; completePass = true
    }
    mutating func move(_ delta: Int) {
        guard !finished else { return }
        current = min(last, max(first, current + delta))
        completePass = current == first
    }
}

struct BeiPracticePlan: Equatable {
    enum Turn { case app, child }
    let first: Int
    let last: Int
    let appFirst: Bool
    private(set) var current: Int
    private(set) var turn: Turn
    private(set) var finished = false
    private var secondTurn = false

    init(first: Int, last: Int, appFirst: Bool) {
        self.first = first; self.last = last; self.appFirst = appFirst
        current = first; turn = appFirst ? .app : .child
    }
    mutating func advance() {
        guard !finished else { return }
        if !secondTurn {
            turn = turn == .app ? .child : .app
            secondTurn = true
        } else if current == last { finished = true }
        else {
            current += 1; secondTurn = false
            turn = appFirst ? .app : .child
        }
    }
    func childWaitDuration(afterSpokenDuration duration: Double) -> Double? {
        guard appFirst, turn == .child, !finished else { return nil }
        return max(3, duration * 1.5)
    }
}

enum BeiHintLevel: String, CaseIterable, Identifiable {
    case full, beginning, hidden
    private static let chineseHintTokens = try! NSRegularExpression(pattern: #"\p{Han}|[\p{L}\p{M}\p{N}&&[^\p{Han}]]+(?:['’][\p{L}\p{M}\p{N}&&[^\p{Han}]]+)*"#)
    var id: String { rawValue }
    var title: String { switch self { case .full: "看全文"; case .beginning: "句首提示"; case .hidden: "隐藏全文" } }
    func display(_ text: String, language: PassageLanguage) -> String {
        switch self {
        case .full: return text
        case .hidden: return "•••"
        case .beginning:
            if language == .chinese {
                let count = Self.chineseHintTokens.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                guard count > 1 else { return "…" }
                return String(text.prefix(count > 3 ? 2 : 1)) + "…"
            }
            let words = text.split(whereSeparator: \.isWhitespace)
            guard words.count > 1 else { return "…" }
            return String(words[0]) + " …"
        }
    }
}
