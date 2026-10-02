import Foundation

struct DictationTimingConfiguration: Equatable {
    static let defaultRepeatAfterSeconds = 15
    static let defaultAdvanceAfterSeconds = 30
    static let stepSeconds = 5
    static let minimumAdvanceAfterSeconds = 10
    static let maximumAdvanceAfterSeconds = 600
    static let minimumGapSeconds = 5

    let repeatAfterSeconds: Int
    let advanceAfterSeconds: Int

    static let `default` = DictationTimingConfiguration(repeatAfterSeconds: defaultRepeatAfterSeconds, advanceAfterSeconds: defaultAdvanceAfterSeconds)

    static func automatic(for text: String) -> Self {
        let chineseCount = text.unicodeScalars.filter {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }.count
        let letters = text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
        // Apostrophes join a word (o’clock); punctuation and Hanzi separate English words.
        let wordCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'’")
        let englishWords = text.components(separatedBy: wordCharacters.inverted)
            .filter { $0.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) } }.count
        let letterExtra = (max(0, letters - 10) + 4) / 5 * 10
        let seconds = 60 + chineseCount * 5 + letterExtra + max(0, englishWords - 2) * 10
        let rounded = (seconds + 9) / 10 * 10
        return Self(repeatAfterSeconds: rounded - 30, advanceAfterSeconds: rounded)
    }

    var isValid: Bool {
        advanceAfterSeconds >= Self.minimumAdvanceAfterSeconds
            && advanceAfterSeconds.isMultiple(of: Self.stepSeconds)
            && repeatAfterSeconds >= Self.stepSeconds
            && repeatAfterSeconds.isMultiple(of: Self.stepSeconds)
            && repeatAfterSeconds <= advanceAfterSeconds - Self.minimumGapSeconds
    }

    var remainingSecondsAfterRepeat: Int { advanceAfterSeconds - repeatAfterSeconds }
}

struct DictationCountdown {
    struct Update: Equatable {
        let secondsRemaining: Int
        let shouldRepeatAndWarn: Bool
        let shouldAdvance: Bool
    }

    let timing: DictationTimingConfiguration
    private(set) var repeatAt: Date
    private(set) var deadline: Date
    private(set) var pausedAt: Date?
    private(set) var didRepeatAndWarn = false
    private(set) var hasExtendedTime = false

    init(timing: DictationTimingConfiguration, startedAt: Date = Date(), paused: Bool = false) {
        precondition(timing.isValid, "计时设置无效")
        self.timing = timing
        pausedAt = paused ? startedAt : nil
        repeatAt = startedAt.addingTimeInterval(TimeInterval(timing.repeatAfterSeconds))
        deadline = startedAt.addingTimeInterval(TimeInterval(timing.advanceAfterSeconds))
    }

    mutating func pause(at now: Date = Date()) {
        if pausedAt == nil { pausedAt = now }
    }

    mutating func resume(at now: Date = Date()) {
        guard let pausedAt else { return }
        let elapsed = max(0, now.timeIntervalSince(pausedAt))
        deadline = deadline.addingTimeInterval(elapsed)
        repeatAt = repeatAt.addingTimeInterval(elapsed)
        self.pausedAt = nil
    }

    @discardableResult
    mutating func extend(at now: Date = Date()) -> Bool {
        guard !hasExtendedTime else { return false }
        hasExtendedTime = true
        let seconds = 30
        deadline = deadline.addingTimeInterval(TimeInterval(seconds))
        repeatAt = repeatAt.addingTimeInterval(TimeInterval(seconds))
        if repeatAt > (pausedAt ?? now) { didRepeatAndWarn = false }
        return true
    }

    mutating func update(at now: Date = Date()) -> Update {
        let effectiveNow = pausedAt ?? now
        let secondsRemaining = Int(ceil(max(0, deadline.timeIntervalSince(effectiveNow))))
        if pausedAt != nil {
            return Update(secondsRemaining: secondsRemaining, shouldRepeatAndWarn: false, shouldAdvance: false)
        }
        if secondsRemaining == 0 {
            return Update(secondsRemaining: 0, shouldRepeatAndWarn: false, shouldAdvance: true)
        }
        let shouldRepeatAndWarn = !didRepeatAndWarn && now >= repeatAt
        if shouldRepeatAndWarn { didRepeatAndWarn = true }
        return Update(secondsRemaining: secondsRemaining, shouldRepeatAndWarn: shouldRepeatAndWarn, shouldAdvance: false)
    }
}
