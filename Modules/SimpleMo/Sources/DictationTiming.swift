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

    var isValid: Bool {
        advanceAfterSeconds >= Self.minimumAdvanceAfterSeconds
            && advanceAfterSeconds <= Self.maximumAdvanceAfterSeconds
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
    let repeatAt: Date
    let deadline: Date
    private(set) var didRepeatAndWarn = false

    init(timing: DictationTimingConfiguration, startedAt: Date = Date()) {
        precondition(timing.isValid, "计时设置无效")
        self.timing = timing
        repeatAt = startedAt.addingTimeInterval(TimeInterval(timing.repeatAfterSeconds))
        deadline = startedAt.addingTimeInterval(TimeInterval(timing.advanceAfterSeconds))
    }

    mutating func update(at now: Date = Date()) -> Update {
        let secondsRemaining = Int(ceil(max(0, deadline.timeIntervalSince(now))))
        if secondsRemaining == 0 {
            return Update(secondsRemaining: 0, shouldRepeatAndWarn: false, shouldAdvance: true)
        }
        let shouldRepeatAndWarn = !didRepeatAndWarn && now >= repeatAt
        if shouldRepeatAndWarn { didRepeatAndWarn = true }
        return Update(secondsRemaining: secondsRemaining, shouldRepeatAndWarn: shouldRepeatAndWarn, shouldAdvance: false)
    }
}
