import CoreData
import Foundation
import PencilKit

@MainActor
final class DictationViewModel: ObservableObject {
    struct Feedback: Identifiable {
        let id = UUID()
        let answer: String
        let recognized: String?
        let reason: DictationFailureReason?
    }

    enum RecognitionError: LocalizedError {
        case englishUnavailable

        var errorDescription: String? {
            "这台 iPad 当前不支持英文手写识别，默写已暂停。"
        }
    }

    @Published private(set) var day: DictationDay?
    @Published private(set) var copyQueue: [InitialCopyPrompt] = []
    @Published private(set) var baselineProgress: BaselineProgress?
    @Published private(set) var isInitialCopy = false
    @Published private(set) var isLoading = true
    @Published private(set) var isBusy = false
    @Published private(set) var feedback: Feedback?
    @Published private(set) var notice: String?
    @Published private(set) var deferredCopies: [InitialCopyPrompt] = []
    @Published var errorMessage: String?
    @Published private(set) var recognitionNotice: String?

    private let repository: DictationRepository
    private let settings: SettingsStore
    private var feedbackTask: Task<Void, Never>?
    private var feedbackDelayElapsed = false
    private var feedbackNarrationFinished = false
    private let recognitionOverride: ((PKDrawing) async throws -> String?)?

    init(container: NSPersistentContainer, settings: SettingsStore,
         recognition: ((PKDrawing) async throws -> String?)? = nil) {
        recognitionOverride = recognition
        repository = DictationRepository(container: container)
        self.settings = settings
    }

    var activeItem: DictationItem? {
        guard !isInitialCopy, let day else { return nil }
        switch day.phase {
        case .firstPass:
            return day.items.first { $0.formalResult == nil }
        case .remediationCopy:
            return day.items.first { $0.needsRemediation && $0.remediationCopyCount < 3 && !$0.isDeferred }
        case .retest:
            return day.items.first { $0.needsRemediation && !$0.retestAttempted && !$0.isDeferred && $0.remediationCopyCount >= 3 }
        case .firstPassSummary, .complete:
            return nil
        }
    }

    var activeCopy: InitialCopyPrompt? {
        isInitialCopy ? copyQueue.first : nil
    }

    var awaitsVerification: Bool { !isInitialCopy && activeItem?.awaitsVerification == true }

    var verificationKey: String? {
        guard awaitsVerification, let day, let item = activeItem else { return nil }
        return "\(day.id)|\(day.phase.rawValue)|\(item.wordID)|\(item.remediationRound)|\(item.keyboardDeadline?.timeIntervalSince1970 ?? 0)"
    }

    var verificationMessage: String {
        let text = activeItem?.pendingHandwriting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "系统没有识别出文字。可以改用字母键盘复核，或按本次结果提交。"
            : "系统识别为：\(text)\n\n请核对识别结果。可以改用字母键盘复核，或按本次结果提交。"
    }

    var keyboardAllowed: Bool {
        if let copy = activeCopy { return copy.keyboardAllowed }
        guard day?.phase == .remediationCopy else { return false }
        return activeItem?.allowsKeyboard == true
    }

    var canDefer: Bool {
        activeCopy != nil || (activeItem != nil && (day?.phase == .remediationCopy || day?.phase == .retest))
    }

    var hasDeferredWork: Bool {
        isInitialCopy ? !deferredCopies.isEmpty : (day?.unresolved ?? 0) > 0 && activeItem == nil
    }

    var isTimed: Bool {
        !isInitialCopy && (day?.phase == .firstPass || day?.phase == .retest)
    }

    var questionKey: String? {
        if let copy = activeCopy {
            return "initial|\(copy.wordID)|\(copy.completedCopies)"
        }
        guard let day, let item = activeItem else { return nil }
        return "\(day.phase.rawValue)|\(item.wordID)|\(item.remediationRound)|\(item.remediationCopyCount)"
    }

    func start() async {
        guard day == nil || day?.limit != settings.dictationLimit.rawValue else { return }
        guard !isBusy else { return }
        isLoading = true
        do {
            if settings.baselineCampaign == nil {
                settings.baselineCampaign = try await repository.automaticBaselineCampaign(
                    masteredTerms: settings.masteredDictationTerms
                )
            }
            day = try await repository.loadOrCreateDay(
                limit: settings.dictationLimit.rawValue, campaign: settings.baselineCampaign,
                masteredTerms: settings.masteredDictationTerms
            )
            await refreshBaselineProgress()
            if let deadline = activeItem?.keyboardDeadline, deadline <= Date() {
                _ = await finishVerification(text: "", viaKeyboard: true, reason: .timeout)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func refreshBaselineProgress() async {
        guard let campaign = settings.baselineCampaign else {
            baselineProgress = nil
            return
        }
        do {
            baselineProgress = try await repository.baselineProgress(
                for: campaign, masteredTerms: settings.masteredDictationTerms
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startInitialCopy() async {
        guard !isBusy else { return }
        isBusy = true
        do {
            copyQueue = try await repository.initialCopyQueue(
                campaign: settings.baselineCampaign,
                masteredTerms: settings.masteredDictationTerms
            )
            isInitialCopy = true
            deferredCopies = []
            notice = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    func beginRemediation() async {
        guard !isBusy, let day else { return }
        isBusy = true
        do {
            self.day = try await repository.beginRemediation(dayID: day.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    func setTimerState(
        dayID: UUID, wordID: UUID, remaining: Double, isWriting: Bool
    ) async {
        do {
            try await repository.setTimerState(
                dayID: dayID, wordID: wordID,
                remaining: remaining, isWriting: isWriting
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submit(
        drawing: PKDrawing,
        explicitReason: DictationFailureReason? = nil,
        submittedAt: Date = Date(),
        keyboardText: String? = nil
    ) async -> Bool {
        guard !isBusy, !awaitsVerification else { return false }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let viaKeyboard = keyboardText != nil
            guard !viaKeyboard || keyboardAllowed else { return false }
            let recognized: String?
            if let keyboardText { recognized = keyboardText }
            else { recognized = explicitReason == nil ? try await recognize(drawing) : nil }
            if isInitialCopy, let copy = activeCopy {
                let updated = try await repository.recordInitialCopy(
                    wordID: copy.wordID, recognized: recognized ?? "", viaKeyboard: viaKeyboard,
                    explicitReason: explicitReason, now: submittedAt
                )
                if !viaKeyboard && !DictationAnswerMatcher.matches(recognized ?? "", answer: copy.english) {
                    showRecognitionNotice(recognized)
                }
                if updated.completedCopies >= 3 {
                    copyQueue.removeFirst()
                    notice = viaKeyboard ? "键盘辅助完成抄写；明天起可以正式默写。" : "已完成 3 遍；明天起可以正式默写。"
                } else {
                    copyQueue[0] = updated
                    notice = explicitReason == nil && DictationAnswerMatcher.matches(recognized ?? "", answer: copy.english)
                        ? "这一遍正确，继续下一遍。" : copyFailureNotice(recognized, viaKeyboard: viaKeyboard)
                }
                return false
            }
            guard let day, let item = activeItem else { return false }
            if isTimed && explicitReason == nil && !DictationAnswerMatcher.matches(recognized ?? "", answer: item.english) {
                self.day = try await repository.stageVerification(
                    dayID: day.id, wordID: item.wordID, recognized: recognized, now: submittedAt
                )
                notice = nil
                return false
            }
            switch day.phase {
            case .firstPass:
                let outcome = try await repository.submitFormal(
                    dayID: day.id, wordID: item.wordID,
                    recognized: recognized, explicitReason: explicitReason, now: submittedAt
                )
                let retry = handle(outcome, answer: item.english, recognized: recognized, showRecognition: explicitReason == nil)
                if item.belongsToBaseline, case .result = outcome {
                    await refreshBaselineProgress()
                }
                return retry
            case .remediationCopy:
                self.day = try await repository.recordRemediationCopy(
                    dayID: day.id, wordID: item.wordID, recognized: recognized ?? "",
                    viaKeyboard: viaKeyboard, explicitReason: explicitReason, now: submittedAt
                )
                if !viaKeyboard && !DictationAnswerMatcher.matches(recognized ?? "", answer: item.english) {
                    showRecognitionNotice(recognized)
                }
                notice = explicitReason == nil && DictationAnswerMatcher.matches(recognized ?? "", answer: item.english)
                    ? (viaKeyboard ? "键盘辅助完成抄写；接下来遮住答案再试一次。" : "这一遍正确。")
                    : copyFailureNotice(recognized, viaKeyboard: viaKeyboard)
                return false
            case .retest:
                let outcome = try await repository.submitRetest(
                    dayID: day.id, wordID: item.wordID,
                    recognized: recognized, explicitReason: explicitReason, now: submittedAt
                )
                return handle(outcome, answer: item.english, recognized: recognized, showRecognition: explicitReason == nil)
            case .firstPassSummary, .complete:
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func beginVerificationKeyboard() async -> Date? {
        guard !isBusy, awaitsVerification, let day, let item = activeItem else { return nil }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            self.day = try await repository.beginKeyboardVerification(dayID: day.id, wordID: item.wordID)
            return activeItem?.keyboardDeadline
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func acceptHandwritingResult() async {
        _ = await finishVerification(text: nil, viaKeyboard: false)
    }

    private func finishVerification(
        text: String?, viaKeyboard: Bool, reason: DictationFailureReason? = nil
    ) async -> Bool {
        guard !isBusy, awaitsVerification, let day, let item = activeItem else { return false }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let outcome: DictationSubmission
            if day.phase == .firstPass {
                outcome = try await repository.submitFormal(
                    dayID: day.id, wordID: item.wordID, recognized: text, explicitReason: reason,
                    resolvingVerification: true, viaKeyboard: viaKeyboard
                )
            } else {
                outcome = try await repository.submitRetest(
                    dayID: day.id, wordID: item.wordID, recognized: text, explicitReason: reason,
                    resolvingVerification: true, viaKeyboard: viaKeyboard
                )
            }
            _ = handle(outcome, answer: item.english,
                       recognized: viaKeyboard ? text : item.pendingHandwriting, showRecognition: false)
            if day.phase == .firstPass && item.belongsToBaseline { await refreshBaselineProgress() }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func submitKeyboard(_ text: String, reason: DictationFailureReason? = nil) async -> Bool {
        if awaitsVerification {
            return await finishVerification(text: text, viaKeyboard: true, reason: reason)
        }
        let answer = activeCopy?.english ?? activeItem?.english ?? ""
        guard keyboardAllowed else { return false }
        _ = await submit(drawing: PKDrawing(), explicitReason: reason, keyboardText: text)
        guard errorMessage == nil else { return false }
        if reason == .timeout {
            notice = "键盘抄写的60秒已到，当前抄写尚未完成。可以重新手写或再试一次。"
            return true
        }
        return DictationAnswerMatcher.matches(text, answer: answer)
    }

    func deferCurrent() async {
        guard !isBusy, canDefer else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if let copy = activeCopy {
                deferredCopies.append(copy)
                copyQueue.removeFirst()
            } else if let day, let item = activeItem {
                self.day = try await repository.deferRemediation(dayID: day.id, wordID: item.wordID)
            }
            notice = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func resumeDeferred() async {
        guard !isBusy else { return }
        if isInitialCopy {
            copyQueue = deferredCopies
            deferredCopies = []
            notice = nil
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            day = try await repository.loadOrCreateDay(
                limit: settings.dictationLimit.rawValue, campaign: settings.baselineCampaign,
                masteredTerms: settings.masteredDictationTerms
            )
            notice = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func copyFailureNotice(_ recognized: String?, viaKeyboard: Bool) -> String {
        if viaKeyboard { return "输入还不正确，请核对完整单词后再试一次。" }
        let text = recognized?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "这一遍未通过：没有识别出文字。请重新抄写。"
            : "这一遍未通过，识别为：\(text)。请照着答案重新抄写。"
    }

    private func handle(
        _ outcome: DictationSubmission, answer: String, recognized: String?, showRecognition: Bool
    ) -> Bool {
        switch outcome {
        case .retry(let day):
            self.day = day
            notice = "无法识别，请用剩余时间重新书写。"
            if showRecognition { showRecognitionNotice(recognized) }
            return true
        case .result(let day, let correct, let reason):
            self.day = day
            notice = nil
            if !correct {
                let item = Feedback(answer: answer, recognized: recognized, reason: reason)
                feedbackDelayElapsed = false
                feedbackNarrationFinished = false
                feedback = item
                if showRecognition { showRecognitionNotice(recognized) }
                else { scheduleFeedbackDismiss(item) }
            }
            return false
        }
    }

    private func showRecognitionNotice(_ recognized: String?) {
        let text = recognized?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        recognitionNotice = text.isEmpty
            ? "系统没有识别出文字。请检查笔迹，再试一次。"
            : "系统识别为：\(text)\n\n这次识别结果与答案不一致。请对照看看，是自己拼错了，还是系统识别出的内容和你想写的不同。"
    }

    func dismissRecognitionNotice() {
        guard recognitionNotice != nil else { return }
        recognitionNotice = nil
        if let feedback { scheduleFeedbackDismiss(feedback) }
    }

    private func scheduleFeedbackDismiss(_ item: Feedback) {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.feedback?.id == item.id else { return }
            self?.feedbackDelayElapsed = true
            self?.dismissFeedbackIfReady(item.id)
        }
    }

    func finishFeedbackNarration(_ id: UUID) {
        guard feedback?.id == id else { return }
        feedbackNarrationFinished = true
        dismissFeedbackIfReady(id)
    }

    private func dismissFeedbackIfReady(_ id: UUID) {
        guard feedback?.id == id, feedbackDelayElapsed, feedbackNarrationFinished else { return }
        feedback = nil
    }

    private func recognize(_ drawing: PKDrawing) async throws -> String? {
        if let recognitionOverride { return try await recognitionOverride(drawing) }
        guard !drawing.strokes.isEmpty else { return nil }
        guard let english = PKStrokeRecognizer.supportedLanguages.first(where: {
            $0.languageCode?.identifier == "en"
        }) else {
            throw RecognitionError.englishUnavailable
        }
        let recognizer = PKStrokeRecognizer(preferredLanguages: [english])
        await recognizer.updateDrawing(drawing)
        return await recognizer.recognizedText()
    }
}
