import Foundation
import Combine

@MainActor
final class PracticeViewModel: ObservableObject, Identifiable {
    enum Feedback { case correct, incorrect(Int) }
    let id = UUID()
    let mode: PracticeMode
    let selectedOperations: [OperationType]
    let questions: [GeneratedQuestion]
    let sessionStartedAt = Date()
    @Published private(set) var index = 0
    @Published private(set) var answer = ""
    @Published private(set) var feedback: Feedback?
    @Published private(set) var completedSession: SessionRecord?
    @Published private(set) var elapsed = 0.0
    private var records: [QuestionRecord] = []
    private var activeStartedUptime: TimeInterval?
    private var elapsedBeforePause = 0.0
    private var currentPresentedAt = Date()
    private var timer: Timer?
    private var feedbackTask: Task<Void, Never>?
    private var isSceneActive = true
    private let uptime: () -> TimeInterval
    let repairDayKey: String?

    init(mode: PracticeMode, questionCount: Int, selectedOperations: Set<OperationType> = Set(OperationType.allCases), generator: QuestionGenerator = QuestionGenerator(), repairDayKey: String? = nil, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.mode = mode
        self.selectedOperations = mode.operation.map { [$0] } ?? OperationType.allCases.filter(selectedOperations.contains)
        self.questions = generator.generate(operations: self.selectedOperations, count: questionCount)
        self.uptime = uptime
        self.repairDayKey = repairDayKey
        beginQuestionTimer()
    }

    deinit { timer?.invalidate(); feedbackTask?.cancel() }
    var currentQuestion: GeneratedQuestion { questions[index] }
    var questionNumber: Int { index + 1 }
    var isInputLocked: Bool { feedback != nil || completedSession != nil }

    func append(_ digit: Int) {
        guard !isInputLocked, answer.count < 3 else { return }
        if answer == "0" { answer = "\(digit)" } else { answer += "\(digit)" }
    }
    func delete() { guard !isInputLocked else { return }; answer.removeLastIfPossible() }
    func submit() {
        guard !isInputLocked, let userAnswer = Int(answer) else { return }
        let duration = currentElapsed()
        stopTimer()
        let question = currentQuestion
        let correct = userAnswer == question.correctAnswer
        records.append(QuestionRecord(id: UUID(), sequenceNumber: questionNumber, operationType: question.operationType,
                                      leftOperand: question.leftOperand, rightOperand: question.rightOperand,
                                      correctAnswer: question.correctAnswer, userAnswer: userAnswer, isCorrect: correct,
                                      durationSeconds: duration, presentedAt: currentPresentedAt, answeredAt: Date()))
        feedback = correct ? .correct : .incorrect(question.correctAnswer)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
    func stop() { timer?.invalidate(); timer = nil; feedbackTask?.cancel(); feedbackTask = nil }

    func partialSession(now: Date = Date()) -> SessionRecord? {
        guard !records.isEmpty, completedSession == nil else { return nil }
        var session = SessionRecord(id: id, startedAt: sessionStartedAt, completedAt: now,
            practiceMode: mode, selectedOperations: mode == .mixed ? selectedOperations : nil,
            targetQuestionCount: questions.count, questions: records)
        session.isPartial = true
        return session
    }

    func scenePhaseChanged(isActive: Bool) {
        isSceneActive = isActive
        guard feedback == nil, completedSession == nil else { return }
        isActive ? resumeTimer() : pauseTimer()
    }

    private func advance() {
        feedback = nil
        if index + 1 == questions.count {
            completedSession = SessionRecord(id: UUID(), startedAt: sessionStartedAt, completedAt: Date(), practiceMode: mode,
                                             selectedOperations: mode == .mixed ? selectedOperations : nil,
                                             targetQuestionCount: questions.count, questions: records)
            completedSession?.repairedDayKey = repairDayKey
            if repairDayKey != nil { completedSession?.repairTimeZoneID = Calendar.current.timeZone.identifier }
            if completedSession?.validRepairKey() == nil { completedSession?.repairedDayKey = nil }
        } else {
            index += 1; answer = ""; elapsed = 0; elapsedBeforePause = 0; beginQuestionTimer()
        }
    }
    private func beginQuestionTimer() {
        currentPresentedAt = Date(); activeStartedUptime = nil
        if isSceneActive { resumeTimer() }
    }
    private func pauseTimer() { elapsedBeforePause = currentElapsed(); activeStartedUptime = nil; stopTimer(); elapsed = elapsedBeforePause }
    private func resumeTimer() { guard activeStartedUptime == nil else { return }; activeStartedUptime = uptime(); startTimer() }
    private func currentElapsed() -> Double { elapsedBeforePause + (activeStartedUptime.map { uptime() - $0 } ?? 0) }
    private func startTimer() { timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.elapsed = self?.currentElapsed() ?? 0 } } }
    private func stopTimer() { timer?.invalidate(); timer = nil }
}

private extension String { mutating func removeLastIfPossible() { guard !isEmpty else { return }; removeLast() } }
