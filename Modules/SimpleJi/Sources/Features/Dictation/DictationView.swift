import CoreData
import PencilKit
import SwiftUI

struct DictationView: View {
    @StateObject private var viewModel: DictationViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var speech: SpeechService
    @ObservedObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var drawing = PKDrawing()
    @State private var remaining: TimeInterval = 30
    @State private var budgetAtStart: TimeInterval = 30
    @State private var startedUptime: TimeInterval?
    @State private var isClockRunning = false
    @State private var isSubmitting = false
    @State private var timerPersistenceTask: Task<Void, Never>?
    @State private var keyboardPrompt: KeyboardPrompt?
    @State private var verificationAlertPresented = false

    private struct KeyboardPrompt: Identifiable {
        let id: String
        let chinese: String
        let answer: String?
    }

    init(container: NSPersistentContainer, settings: SettingsStore) {
        self.settings = settings
        _viewModel = StateObject(
            wrappedValue: DictationViewModel(container: container, settings: settings)
        )
    }

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()
            content
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task { speech.stop(); await viewModel.start(); presentPendingVerification() }
        .onChange(of: copyNarrationKey, initial: true) { _, _ in narrateCurrentCopy() }
        .task(id: feedbackNarrationKey) { narrateFeedback() }
        .onDisappear { speech.stop() }
        .onChange(of: viewModel.verificationKey) { _, _ in presentPendingVerification() }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            tick()
        }
        .onChange(of: viewModel.questionKey) { _, _ in
            drawing = PKDrawing()
            pauseClock()
            remaining = viewModel.activeItem?.remainingSeconds ?? 30
            if viewModel.isTimed && viewModel.feedback == nil && scenePhase == .active {
                startClock()
            }
        }
        .onChange(of: viewModel.feedback?.id) { _, newValue in
            if newValue == nil && viewModel.isTimed && scenePhase == .active {
                startClock()
            } else {
                pauseClock()
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue != .active {
                speech.stop()
                pauseClock()
                persistTimerState(isWriting: false)
            } else {
                narrateCurrentCopy()
            }
        }
        .sheet(item: $keyboardPrompt, onDismiss: {
            if scenePhase == .active {
                startClock()
                narrateCurrentCopy()
            }
        }) { prompt in
            DictationKeyboardSheet(
                chinese: prompt.chinese, answer: prompt.answer,
                submissionError: { viewModel.errorMessage },
                startClock: prompt.answer == nil ? { await viewModel.beginVerificationKeyboard() } : nil
            ) { text, reason in
                guard viewModel.questionKey == prompt.id else { return true }
                let close = await viewModel.submitKeyboard(text, reason: reason)
                if close { drawing = PKDrawing() }
                return close
            }
            .interactiveDismissDisabled(prompt.answer == nil || viewModel.isBusy)
        }
        .onChange(of: viewModel.recognitionNotice) { _, newValue in
            if newValue != nil {
                speech.stop()
                pauseClock()
            } else if scenePhase == .active {
                startClock()
                narrateCurrentCopy()
            }
        }
        .alert(viewModel.errorMessage == nil ? "手写识别结果" : "默写暂时无法继续", isPresented: alertBinding) {
            if viewModel.errorMessage == nil && verificationAlertPresented {
                Button("改用字母键盘（60秒）", action: openVerificationKeyboard)
                Button("按本次结果提交") { Task { await viewModel.acceptHandwritingResult() } }
            } else {
                Button("知道了", role: .cancel) {
                    viewModel.errorMessage = nil
                    viewModel.dismissRecognitionNotice()
                }
            }
        } message: {
            Text(viewModel.errorMessage ?? (verificationAlertPresented ? viewModel.verificationMessage : viewModel.recognitionNotice) ?? "发生未知错误。")
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView("正在准备默写…")
        } else if let feedback = viewModel.feedback {
            feedbackView(feedback)
        } else if viewModel.awaitsVerification {
            verificationView
        } else if viewModel.isInitialCopy {
            if viewModel.activeCopy != nil { practiceView }
            else if viewModel.hasDeferredWork { deferredView }
            else { initialCopyCompleteView }
        } else if let day = viewModel.day {
            switch day.phase {
            case .firstPass, .remediationCopy, .retest:
                if viewModel.hasDeferredWork { deferredView }
                else if viewModel.activeItem != nil { practiceView }
                else { statusView("当前没有可练习的单词，请返回首页重新进入。", symbol: "exclamationmark.triangle") }
            case .firstPassSummary:
                firstPassSummary(day)
            case .complete:
                completeView(day)
            }
        } else {
            statusView("暂时无法载入默写任务", symbol: "exclamationmark.triangle")
        }
    }

    private var verificationView: some View {
        VStack(spacing: 22) {
            Text(prompt?.chinese ?? "").font(.largeTitle.bold())
            Text(viewModel.verificationMessage)
                .font(.title3).multilineTextAlignment(.center)
            if viewModel.activeItem?.keyboardDeadline == nil {
                Button("改用字母键盘（60秒）", action: openVerificationKeyboard)
                    .buttonStyle(LargePrimaryButtonStyle())
                Button("按本次结果提交") { Task { await viewModel.acceptHandwritingResult() } }
                    .buttonStyle(LargeSecondaryButtonStyle())
            } else {
                Button("继续键盘复核", action: openVerificationKeyboard)
                    .buttonStyle(LargePrimaryButtonStyle())
            }
            Button("稍后继续", action: returnHome)
        }
        .disabled(viewModel.isBusy)
        .frame(maxWidth: 620)
        .padding(28)
    }

    private var practiceView: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        Button(action: returnHome) {
                            Image(systemName: "xmark")
                                .font(.title2.bold())
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("暂停并返回首页")
                        .disabled(viewModel.isBusy)
                        Spacer()
                        Text(progressTitle)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(AppPalette.textSecondary)
                    }

                    Text(prompt?.chinese ?? "")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 72)

                    if isCopyStage {
                        Text(prompt?.english ?? "")
                            .font(.system(size: 31, weight: .medium, design: .rounded))
                            .foregroundStyle(AppPalette.accent)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("dictation.copyAnswer")
                    }

                    PencilCanvas(drawing: $drawing)
                        .allowsHitTesting(!isSubmitting && !viewModel.isBusy)
                        .frame(maxWidth: 820)
                        .frame(height: max(280, min(440, geometry.size.height * 0.52)))
                        .background(AppPalette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(AppPalette.textSecondary.opacity(0.2))
                        )

                    if viewModel.isTimed {
                        HStack(spacing: 18) {
                            Text(String(format: "%02d:%02d", Int(remaining) / 60, Int(remaining) % 60))
                                .font(.title2.monospacedDigit().bold())
                                .foregroundStyle(remaining < 10 ? .red : AppPalette.textPrimary)
                                .accessibilityIdentifier("dictation.timer")
                            if !isClockRunning && !viewModel.isBusy && !isSubmitting {
                                Button("继续计时", action: startClock)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }

                    if let notice = viewModel.notice {
                        Text(notice)
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.textSecondary)
                            .accessibilityIdentifier("dictation.notice")
                    }

                    HStack(spacing: 16) {
                        Button("清除") { drawing = PKDrawing() }
                            .buttonStyle(LargeSecondaryButtonStyle())
                            .disabled(drawing.strokes.isEmpty || viewModel.isBusy || isSubmitting)
                        Button("确认") { submit() }
                            .buttonStyle(LargePrimaryButtonStyle())
                            .disabled(drawing.strokes.isEmpty || viewModel.isBusy || isSubmitting ||
                                      (viewModel.isTimed && !isClockRunning))
                            .accessibilityIdentifier("dictation.confirm")
                    }
                    .frame(maxWidth: 620)

                    if viewModel.keyboardAllowed {
                        VStack(spacing: 8) {
                            Text("手写连续三次未通过，可以用键盘输入一次完成剩余抄写。")
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.textSecondary)
                            Button("改用键盘输入", action: openKeyboard)
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("dictation.keyboardFallback")
                        }
                        .disabled(viewModel.isBusy || isSubmitting)
                    }
                    if viewModel.canDefer {
                        Button("稍后再练这个词", action: deferCurrent)
                            .disabled(viewModel.isBusy || isSubmitting)
                            .accessibilityIdentifier("dictation.deferWord")
                    }
                    if viewModel.isTimed {
                        Button("不会") { submit(reason: .unknown) }
                            .font(.headline)
                            .foregroundStyle(.red)
                            .disabled(viewModel.isBusy || isSubmitting || !isClockRunning)
                            .accessibilityIdentifier("dictation.unknown")
                    }
                }
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
    }

    private var prompt: (chinese: String, english: String)? {
        if let copy = viewModel.activeCopy { return (copy.chinese, copy.english) }
        if let item = viewModel.activeItem { return (item.chinese, item.english) }
        return nil
    }

    private var isCopyStage: Bool {
        viewModel.isInitialCopy || viewModel.day?.phase == .remediationCopy
    }

    private var copyNarrationKey: String? {
        guard !viewModel.isLoading, isCopyStage, viewModel.feedback == nil else { return nil }
        return viewModel.questionKey
    }

    private var feedbackNarrationKey: UUID? {
        guard scenePhase == .active, keyboardPrompt == nil,
              viewModel.recognitionNotice == nil, viewModel.errorMessage == nil else { return nil }
        return viewModel.feedback?.id
    }

    private func narrateFeedback() {
        guard let id = feedbackNarrationKey, let feedback = viewModel.feedback else { return }
        speech.speak(
            feedback.answer,
            language: .english,
            preferredIdentifier: settings.englishVoiceIdentifier,
            rate: settings.englishSpeechRate,
            repetitions: 2,
            onCompletion: { viewModel.finishFeedbackNarration(id) }
        )
    }

    private func narrateCurrentCopy() {
        guard viewModel.feedback == nil else { return }
        speech.stop()
        guard copyNarrationKey != nil, scenePhase == .active,
              keyboardPrompt == nil, viewModel.recognitionNotice == nil,
              viewModel.errorMessage == nil, let prompt else { return }
        speech.speak(
            prompt.english,
            language: .english,
            preferredIdentifier: settings.englishVoiceIdentifier,
            rate: settings.englishSpeechRate
        )
    }

    private var progressTitle: String {
        if let copy = viewModel.activeCopy {
            return "首次抄写 · 第 \(copy.completedCopies + 1) / 3 遍"
        }
        guard let day = viewModel.day, let item = viewModel.activeItem else { return "默写" }
        switch day.phase {
        case .firstPass:
            let title = item.belongsToBaseline ? "旧词摸底" : "正式默写"
            return "\(title) · 第 \(day.firstPassAnswered + 1) / \(day.items.count) 题"
        case .remediationCopy:
            return "错词抄写 · 第 \(item.remediationCopyCount + 1) / 3 遍"
        case .retest:
            let finished = day.items.filter { $0.formalResult == false && $0.retestAttempted }.count
            return "错词重默 · 第 \(finished + 1) 题"
        case .firstPassSummary, .complete:
            return "默写"
        }
    }

    private func firstPassSummary(_ day: DictationDay) -> some View {
        VStack(spacing: 20) {
            Text("今日第一轮完成").font(.largeTitle.bold())
            Text("\(day.items.count) 个单词 · 首次正确 \(day.firstPassCorrect) · 需要强化 \(day.firstPassWrong)")
            if day.items.contains(where: \.belongsToBaseline) {
                Text("本轮旧词摸底 \(day.items.filter(\.belongsToBaseline).count) 个；首次结果已记录。")
            }
            Text(accuracyText(day))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(AppPalette.accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(day.items.filter { $0.formalResult == false }) { item in
                        Text(item.english).font(.title3)
                    }
                }
            }
            .frame(maxHeight: 240)
            Button("开始错词抄写") { Task { await viewModel.beginRemediation() } }
                .buttonStyle(LargePrimaryButtonStyle())
                .frame(maxWidth: 400)
            Button("稍后继续", action: returnHome)
        }
        .padding(28)
    }

    private func completeView(_ day: DictationDay) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(AppPalette.accent)
            Text(day.items.isEmpty ? "今天没有到期的默写词" : "今天的默写已完成")
                .font(.title.bold())
            if !day.items.isEmpty {
                Text("首次正确 \(day.firstPassCorrect) / \(day.items.count) · \(accuracyText(day))")
                    .font(.title3)
            }
            if let progress = viewModel.baselineProgress, progress.total > 0 {
                Text("旧词摸底已测 \(progress.completed) / \(progress.total) 个")
                    .foregroundStyle(AppPalette.textSecondary)
                if progress.remaining > 0 {
                    Text(day.limit > 0 && day.items.count >= day.limit
                         ? "今天已达到默写上限，剩余旧词下一个学习日继续。"
                         : "剩余旧词会按每日默写额度继续安排。")
                        .foregroundStyle(AppPalette.textSecondary)
                }
            }
            Button("开始新词抄写") { Task { await viewModel.startInitialCopy() } }
                .buttonStyle(LargePrimaryButtonStyle())
                .frame(maxWidth: 400)
            Button("返回首页", action: returnHome)
        }
        .padding(28)
    }

    private var deferredView: some View {
        VStack(spacing: 20) {
            Text("其他词已练完，暂缓的词还没完成")
                .font(.title2.bold())
            Text("这些词会保留待练状态，下次进入可以继续。")
                .foregroundStyle(AppPalette.textSecondary)
            Button("继续练暂缓的词") { Task { await viewModel.resumeDeferred() } }
                .buttonStyle(LargePrimaryButtonStyle())
                .frame(maxWidth: 400)
            Button("返回首页", action: returnHome)
        }
        .padding(28)
    }

    private var initialCopyCompleteView: some View {
        statusView("今天可开始的首次抄写已完成", symbol: "checkmark.circle.fill")
    }

    private func statusView(_ title: String, symbol: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: symbol).font(.system(size: 56)).foregroundStyle(AppPalette.accent)
            Text(title).font(.title2.bold())
            Button("返回首页", action: returnHome)
                .buttonStyle(LargePrimaryButtonStyle())
                .frame(maxWidth: 400)
        }
        .padding(28)
    }

    private func feedbackView(_ feedback: DictationViewModel.Feedback) -> some View {
        VStack(spacing: 20) {
            Text("需要强化").font(.title.bold())
            Text(feedback.answer)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(AppPalette.accent)
            if let recognized = feedback.recognized, !recognized.isEmpty {
                Text("识别为：\(recognized)")
                    .foregroundStyle(AppPalette.textSecondary)
            }
            Text("看一看正确拼写，听两遍发音后继续")
                .foregroundStyle(AppPalette.textSecondary)
        }
        .padding(28)
    }

    private func accuracyText(_ day: DictationDay) -> String {
        guard let accuracy = day.firstPassAccuracy else { return "暂无首次成绩" }
        return "首次正确率 \(Int((accuracy * 100).rounded()))%"
    }

    private func submit(reason: DictationFailureReason? = nil) {
        guard !isSubmitting else { return }
        isSubmitting = true
        speech.stop()
        pauseClock()
        let effectiveReason: DictationFailureReason? = viewModel.isTimed && remaining <= 0
            ? .timeout : reason
        let submittedAt = Date()
        let snapshot = drawing
        Task {
            if viewModel.isTimed {
                persistTimerState(isWriting: false)
                await timerPersistenceTask?.value
            }
            let retry = await viewModel.submit(
                drawing: snapshot, explicitReason: effectiveReason, submittedAt: submittedAt
            )
            if viewModel.errorMessage == nil { drawing = PKDrawing() }
            isSubmitting = false
            if retry && viewModel.errorMessage == nil && scenePhase == .active {
                startClock()
            } else if viewModel.feedback == nil && viewModel.isTimed
                        && viewModel.errorMessage == nil && scenePhase == .active {
                startClock()
            }
        }
    }

    private func presentPendingVerification() {
        guard !viewModel.isLoading, viewModel.awaitsVerification else { return }
        pauseClock()
        if viewModel.activeItem?.keyboardDeadline == nil {
            verificationAlertPresented = true
        } else if keyboardPrompt == nil {
            openVerificationKeyboard()
        }
    }

    private func openVerificationKeyboard() {
        guard viewModel.awaitsVerification, let key = viewModel.questionKey, let prompt else { return }
        verificationAlertPresented = false
        pauseClock()
        keyboardPrompt = KeyboardPrompt(id: key, chinese: prompt.chinese, answer: nil)
    }

    private func openKeyboard() {
        guard viewModel.keyboardAllowed, let key = viewModel.questionKey, let prompt else { return }
        speech.stop()
        pauseClock()
        let request = KeyboardPrompt(id: key, chinese: prompt.chinese, answer: prompt.english)
        isSubmitting = true
        Task {
            persistTimerState(isWriting: false)
            await timerPersistenceTask?.value
            keyboardPrompt = request
            isSubmitting = false
        }
    }

    private func deferCurrent() {
        guard !isSubmitting else { return }
        speech.stop()
        pauseClock()
        isSubmitting = true
        Task {
            persistTimerState(isWriting: false)
            await timerPersistenceTask?.value
            await viewModel.deferCurrent()
            drawing = PKDrawing()
            isSubmitting = false
            if scenePhase == .active { startClock() }
        }
    }

    private func startClock() {
        guard viewModel.isTimed, viewModel.activeItem != nil,
              viewModel.feedback == nil, viewModel.recognitionNotice == nil, !viewModel.awaitsVerification, !viewModel.isBusy, !isSubmitting,
              keyboardPrompt == nil, !isClockRunning, remaining > 0 else { return }
        budgetAtStart = remaining
        startedUptime = ProcessInfo.processInfo.systemUptime
        isClockRunning = true
        persistTimerState(isWriting: true)
    }

    private func pauseClock() {
        guard isClockRunning, let startedUptime else { return }
        remaining = max(0, budgetAtStart - (ProcessInfo.processInfo.systemUptime - startedUptime))
        isClockRunning = false
        self.startedUptime = nil
    }

    private func tick() {
        guard isClockRunning, let startedUptime else { return }
        remaining = max(0, budgetAtStart - (ProcessInfo.processInfo.systemUptime - startedUptime))
        if remaining <= 0 { submit(reason: .timeout) }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil || viewModel.recognitionNotice != nil || verificationAlertPresented },
            set: { if !$0 {
                verificationAlertPresented = false
                viewModel.errorMessage = nil
                viewModel.dismissRecognitionNotice()
            } }
        )
    }

    private func returnHome() {
        speech.stop()
        pauseClock()
        Task {
            persistTimerState(isWriting: false)
            await timerPersistenceTask?.value
            router.reset()
        }
    }

    private func persistTimerState(isWriting: Bool) {
        guard let dayID = viewModel.day?.id,
              let wordID = viewModel.activeItem?.wordID,
              viewModel.isTimed else { return }
        let previous = timerPersistenceTask
        let savedRemaining = remaining
        timerPersistenceTask = Task {
            await previous?.value
            await viewModel.setTimerState(
                dayID: dayID, wordID: wordID,
                remaining: savedRemaining, isWriting: isWriting
            )
        }
    }
}

private struct DictationKeyboardSheet: View {
    let chinese: String
    let answer: String?
    let submissionError: () -> String?
    let startClock: (() async -> Date?)?
    let submit: (String, DictationFailureReason?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var message: String?
    @State private var deadline: Date?
    @State private var remaining: TimeInterval = 60
    @State private var automaticTimeoutAttempted = false

    private var isVerification: Bool { answer == nil }
    private var ready: Bool { deadline != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(chinese).font(.title.bold())
                    if let answer {
                        Text(answer).font(.title).foregroundStyle(AppPalette.accent)
                        Text("60秒内输入完整单词，完成这个词剩余的抄写。")
                    } else {
                        Text("请自己拼出英文；只有一次提交机会。")
                    }
                    Text(String(format: "%02d:%02d", Int(ceil(remaining)) / 60, Int(ceil(remaining)) % 60))
                        .font(.title.monospacedDigit().bold())
                        .foregroundStyle(remaining <= 10 ? .red : AppPalette.textPrimary)
                        .accessibilityIdentifier("dictation.keyboardTimer")
                    // Plain display plus our own keys prevents suggestions, correction, paste, and dictation.
                    Text(text.isEmpty ? "输入英文" : text)
                        .font(.title2.monospaced())
                        .foregroundStyle(text.isEmpty ? AppPalette.textSecondary : AppPalette.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .padding(.horizontal, 12)
                        .background(AppPalette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("dictation.keyboardText")
                    letterKeyboard
                        .disabled(!ready || isSubmitting || remaining <= 0)
                    if let message {
                        Text(message).foregroundStyle(.red)
                        if isVerification && remaining <= 0 {
                            Button("重试保存超时结果") { confirm(reason: .timeout) }
                                .disabled(isSubmitting)
                        }
                    }
                    Text(isVerification ? "确认后立即判定；错误或超时进入下一词。" : "本次记录为键盘辅助，不改写首次默写成绩。")
                        .font(.subheadline).foregroundStyle(AppPalette.textSecondary)
                    Button("确认输入") { confirm() }
                        .buttonStyle(LargePrimaryButtonStyle())
                        .disabled(!ready || isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("dictation.keyboardConfirm")
                }
                .padding(28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(isVerification ? "键盘复核" : "键盘辅助抄写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isVerification {
                        Button("不会") { confirm(reason: .unknown) }
                            .disabled(!ready || isSubmitting)
                    } else {
                        Button("继续手写") { dismiss() }.disabled(isSubmitting)
                    }
                }
            }
            .task {
                if let startClock {
                    deadline = await startClock()
                    if deadline == nil { message = "暂时无法载入计时，请关闭后重试。" }
                } else {
                    deadline = Date().addingTimeInterval(DictationKeyboardClock.duration)
                }
                checkDeadline()
            }
            .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in checkDeadline() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { checkDeadline() } }
            .overlay(alignment: .bottom) {
                if isVerification && deadline == nil && message != nil {
                    Button("关闭后重试") { dismiss() }.padding()
                }
            }
        }
    }

    private var letterKeyboard: some View {
        VStack(spacing: 8) {
            ForEach(["qwertyuiop", "asdfghjkl", "zxcvbnm"], id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(Array(row).map(String.init), id: \.self) { letter in
                        key(letter) { text += letter; message = nil }
                    }
                }
            }
            HStack(spacing: 8) {
                key("'") { text += "'"; message = nil }
                key("-") { text += "-"; message = nil }
                key("空格") { text += " "; message = nil }
                key("删除") { if !text.isEmpty { text.removeLast() }; message = nil }
            }
        }
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(AppPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.textSecondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dictation.key.\(title)")
    }

    private func checkDeadline() {
        guard let deadline, !isSubmitting else { return }
        remaining = DictationKeyboardClock.remaining(until: deadline)
        if remaining <= 0 && !automaticTimeoutAttempted {
            automaticTimeoutAttempted = true
            confirm(reason: .timeout)
        }
    }

    private func confirm(reason: DictationFailureReason? = nil) {
        guard ready, !isSubmitting,
              reason != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSubmitting = true
        Task {
            if await submit(text, reason) { dismiss(); return }
            message = submissionError() ?? (isVerification ? "暂时无法保存，请重试。" : "输入未通过，请核对完整单词后再试一次。")
            isSubmitting = false
        }
    }
}
