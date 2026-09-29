import CoreData
import Foundation

@MainActor
final class ReviewSessionViewModel: ObservableObject {
    enum Phase {
        case loading
        case empty
        case active
        case summary(SessionSummary)
        case failed(String)
    }

    struct SessionSummary {
        let mode: PracticeMode
        let answered: Int
        let known: Int
        let unknown: Int
        let retries: Int
        let remainingDue: Int

        var accuracy: Int {
            guard answered > 0 else { return 0 }
            return Int((Double(known) / Double(answered) * 100).rounded())
        }
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var currentTask: ReviewTask?
    @Published private(set) var isRevealed = false
    @Published private(set) var isSaving = false
    @Published private(set) var baseTaskCount = 0
    @Published private(set) var baseAnswered = 0

    private let repository: ReviewRepository
    private let mode: PracticeMode
    private let sessionLimit: Int?
    private let extraPracticeScope: ExtraPracticeScope
    private var queue: [ReviewTask] = []
    private var sessionID: UUID?
    private var knownCount = 0
    private var unknownCount = 0
    private var retryAnswered = 0

    init(
        container: NSPersistentContainer,
        mode: PracticeMode,
        sessionLimit: Int?,
        extraPracticeScope: ExtraPracticeScope = .weakest20
    ) {
        repository = ReviewRepository(container: container)
        self.mode = mode
        self.sessionLimit = sessionLimit
        self.extraPracticeScope = extraPracticeScope
    }

    var answeredCount: Int {
        mode == .scheduled ? baseAnswered + retryAnswered : baseAnswered
    }

    var shouldConfirmExit: Bool { answeredCount > 0 }

    var progress: Double {
        guard baseTaskCount > 0 else { return 0 }
        return min(Double(baseAnswered) / Double(baseTaskCount), 1)
    }

    func start() async {
        guard sessionID == nil else { return }
        phase = .loading

        do {
            let states: [ReviewStateSnapshot]
            switch mode {
            case .scheduled:
                states = try await repository.dueStates()
                queue = ReviewQueueBuilder.buildBaseQueue(
                    from: states,
                    sessionLimit: nil,
                    today: Date()
                )
            case .extraPractice:
                let includesEverything = extraPracticeScope == .everything
                states = includesEverything
                    ? try await repository.allStates()
                    : try await repository.weakStates()
                queue = ReviewQueueBuilder.buildExtraPracticeQueue(
                    from: states,
                    limit: sessionLimit,
                    includeAll: includesEverything
                )
            }

            guard !queue.isEmpty else {
                phase = .empty
                return
            }

            baseTaskCount = queue.count
            sessionID = try await repository.startSession(
                mode: mode,
                baseTaskCount: baseTaskCount
            )
            currentTask = queue.first
            phase = .active
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reveal() {
        guard !isSaving, currentTask != nil, !isRevealed else { return }
        isRevealed = true
    }

    func answer(_ answer: ReviewResult) async {
        guard !isSaving,
              isRevealed,
              let task = currentTask,
              let sessionID else { return }

        isSaving = true
        do {
            _ = try await repository.recordAnswer(
                stateID: task.state.id,
                sessionID: sessionID,
                mode: mode,
                answer: answer,
                isSameSessionRetry: task.isRetry
            )

            var remaining = Array(queue.dropFirst())
            switch mode {
            case .scheduled:
                if task.isRetry {
                    retryAnswered += 1
                } else {
                    baseAnswered += 1
                    if answer == .known { knownCount += 1 } else { unknownCount += 1 }
                }

                if answer == .unknown {
                    remaining = ReviewQueueBuilder.insertingRetry(
                        for: task,
                        attempt: task.retryAttempt + 1,
                        into: remaining
                    )
                }
            case .extraPractice:
                baseAnswered += 1
                if answer == .known { knownCount += 1 } else { unknownCount += 1 }
            }

            queue = remaining
            isRevealed = false
            if let next = queue.first {
                currentTask = next
                isSaving = false
            } else {
                currentTask = nil
                try await completeSession()
            }
        } catch {
            isSaving = false
            phase = .failed(error.localizedDescription)
        }
    }

    func exitSession() async {
        guard let sessionID else { return }
        isSaving = true
        do {
            if answeredCount == 0 {
                try await repository.discardSessionIfEmpty(id: sessionID)
            } else {
                try await repository.finishSession(id: sessionID, completed: false)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        isSaving = false
    }

    func restart() async {
        sessionID = nil
        queue = []
        currentTask = nil
        isRevealed = false
        isSaving = false
        baseTaskCount = 0
        baseAnswered = 0
        knownCount = 0
        unknownCount = 0
        retryAnswered = 0
        await start()
    }

    private func completeSession() async throws {
        guard let sessionID else { return }
        try await repository.finishSession(id: sessionID, completed: true)
        let remainingDue = mode == .scheduled
            ? try await repository.dueStates().count
            : 0
        phase = .summary(
            SessionSummary(
                mode: mode,
                answered: baseAnswered,
                known: knownCount,
                unknown: unknownCount,
                retries: retryAnswered,
                remainingDue: remainingDue
            )
        )
        isSaving = false
    }
}
