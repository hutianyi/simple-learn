import CoreData
import SwiftUI

struct ReviewSessionView: View {
    @StateObject private var viewModel: ReviewSessionViewModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var speech: SpeechService
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingExitConfirmation = false

    private let mode: PracticeMode

    init(
        container: NSPersistentContainer,
        settings: SettingsStore,
        speech: SpeechService,
        mode: PracticeMode = .scheduled,
        sessionLimit: Int? = nil,
        extraPracticeScope: ExtraPracticeScope = .weakest20
    ) {
        self.settings = settings
        self.speech = speech
        self.mode = mode
        _viewModel = StateObject(
            wrappedValue: ReviewSessionViewModel(
                container: container,
                mode: mode,
                sessionLimit: sessionLimit,
                extraPracticeScope: extraPracticeScope
            )
        )
    }

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()
            content
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task { await viewModel.start() }
        .confirmationDialog(
            "退出本轮复习？",
            isPresented: $showingExitConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出", role: .destructive) {
                Task { await exitAndReturnHome() }
            }
            Button("继续复习", role: .cancel) {}
        } message: {
            Text("已经完成的回答会保留。未完成的卡片下次会重新进入队列。")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView("正在准备卡片…")
                .font(.title3)
        case .empty:
            emptyView
        case .active:
            activeView
        case .summary(let summary):
            SessionSummaryView(
                summary: summary,
                onAgain: { Task { await viewModel.restart() } },
                onHome: returnHome
            )
        case .failed(let message):
            failureView(message)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 18) {
            Image(systemName: mode == .scheduled ? "checkmark.circle.fill" : "sparkles")
                .font(.system(size: 54))
                .foregroundStyle(AppPalette.accent)
            Text(mode == .scheduled ? "今天没有待复习卡片" : "暂时没有薄弱卡片")
                .font(.title2.bold())
            Button("返回首页", action: returnHome)
                .buttonStyle(LargePrimaryButtonStyle())
                .frame(maxWidth: 360)
        }
        .padding(30)
    }

    private var activeView: some View {
        VStack(spacing: 18) {
            sessionBar

            if let task = viewModel.currentTask {
                flashcard(task)
                    .id(task.id)
                    .task(id: task.id) {
                        if settings.autoSpeakFront {
                            speak(task.frontText, language: frontLanguage(for: task))
                        }
                    }

                if viewModel.isRevealed {
                    answerButtons
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Text("想好后，轻点卡片查看答案")
                        .font(.headline)
                        .foregroundStyle(AppPalette.textSecondary)
                        .frame(minHeight: 68)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var sessionBar: some View {
        VStack(spacing: 9) {
            HStack {
                Button(action: requestExit) {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.textPrimary)
                .disabled(viewModel.isSaving)

                Spacer()

                if viewModel.currentTask?.isRetry == true {
                    Text("重试")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.textSecondary)
                } else if mode == .extraPractice {
                    Text("额外加练")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.textSecondary)
                }

                Text("\(viewModel.baseAnswered) / \(viewModel.baseTaskCount)")
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 76, alignment: .trailing)
            }

            ProgressView(value: viewModel.progress)
                .tint(AppPalette.accent)
        }
        .frame(maxWidth: 760)
    }

    private func flashcard(_ task: ReviewTask) -> some View {
        VStack(spacing: 30) {
            Spacer(minLength: 20)

            Text(task.frontText)
                .font(cardFont(for: task.frontText, language: frontLanguage(for: task)))
                .foregroundStyle(AppPalette.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.55)
                .lineLimit(3)

            if viewModel.isRevealed {
                Divider().frame(maxWidth: 340)
                Text(task.backText)
                    .font(cardFont(for: task.backText, language: backLanguage(for: task)))
                    .foregroundStyle(AppPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.55)
                    .lineLimit(4)
            }

            Button {
                let text = viewModel.isRevealed ? task.backText : task.frontText
                let language = viewModel.isRevealed
                    ? backLanguage(for: task)
                    : frontLanguage(for: task)
                speak(text, language: language)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title2)
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.accent)

            Spacer(minLength: 20)
        }
        .padding(30)
        .frame(maxWidth: 760, maxHeight: 560)
        .background(AppPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .onTapGesture {
            guard !viewModel.isSaving, !viewModel.isRevealed else { return }
            Haptics.tap(enabled: settings.hapticsEnabled)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                viewModel.reveal()
            }
            if settings.autoSpeakBack {
                speak(task.backText, language: backLanguage(for: task))
            }
        }
        .accessibilityLabel(viewModel.isRevealed
            ? "正面：\(task.frontText)，答案：\(task.backText)"
            : "卡片：\(task.frontText)，轻点查看答案")
        .accessibilityIdentifier("review.card")
    }

    private var answerButtons: some View {
        HStack(spacing: 18) {
            Button {
                answer(.unknown)
            } label: {
                Text("不认识")
                    .font(.title3.bold())
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(AppPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.red.opacity(0.55), lineWidth: 2)
                    )
            }
            .accessibilityIdentifier("review.unknown")

            Button {
                answer(.known)
            } label: {
                Text("认识")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .accessibilityIdentifier("review.known")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 760)
        .disabled(viewModel.isSaving)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("复习暂时无法继续")
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(AppPalette.textSecondary)
                .multilineTextAlignment(.center)
            Button("返回首页", action: returnHome)
                .buttonStyle(LargePrimaryButtonStyle())
                .frame(maxWidth: 360)
        }
        .padding(30)
    }

    private func answer(_ answer: ReviewResult) {
        guard !viewModel.isSaving else { return }
        speech.stop()
        Haptics.answer(answer, enabled: settings.hapticsEnabled)
        Task {
            await viewModel.answer(answer)
            if case .summary = viewModel.phase {
                Haptics.milestone(enabled: settings.hapticsEnabled)
            }
        }
    }

    private func requestExit() {
        speech.stop()
        if viewModel.shouldConfirmExit {
            showingExitConfirmation = true
        } else {
            Task { await exitAndReturnHome() }
        }
    }

    private func exitAndReturnHome() async {
        await viewModel.exitSession()
        if case .failed = viewModel.phase { return }
        returnHome()
    }

    private func returnHome() {
        speech.stop()
        router.reset()
    }

    private func speak(_ text: String, language: SpeechLanguage) {
        speech.speak(
            text,
            language: language,
            preferredIdentifier: language == .english
                ? settings.englishVoiceIdentifier
                : settings.chineseVoiceIdentifier,
            rate: language == .english
                ? settings.englishSpeechRate
                : settings.chineseSpeechRate
        )
    }

    private func frontLanguage(for task: ReviewTask) -> SpeechLanguage {
        task.direction == .englishToChinese ? .english : .chinese
    }

    private func backLanguage(for task: ReviewTask) -> SpeechLanguage {
        task.direction == .englishToChinese ? .chinese : .english
    }

    private func cardFont(for text: String, language: SpeechLanguage) -> Font {
        let baseSize: CGFloat = language == .english ? 62 : 56
        let adjusted = text.count > 28 ? baseSize * 0.72 : baseSize
        return .system(size: adjusted, weight: .bold, design: .rounded)
    }
}

private struct SessionSummaryView: View {
    let summary: ReviewSessionViewModel.SessionSummary
    let onAgain: () -> Void
    let onHome: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62))
                .foregroundStyle(.green)
            Text(summary.mode == .scheduled ? "本轮完成" : "额外加练完成")
                .font(.largeTitle.bold())

            VStack(spacing: 10) {
                summaryRow(summary.mode == .scheduled ? "正式复习" : "练习", "\(summary.answered)")
                summaryRow("认识", "\(summary.known)")
                summaryRow("不认识", "\(summary.unknown)")
                summaryRow(summary.mode == .scheduled ? "首答正确率" : "正确率", "\(summary.accuracy)%")
                if summary.mode == .scheduled, summary.retries > 0 {
                    summaryRow("当天重试", "\(summary.retries) 次")
                }
            }
            .font(.title3)
            .frame(maxWidth: 420)

            if summary.mode == .scheduled {
                Text(summary.remainingDue == 0
                    ? "今天的复习完成了"
                    : "今天还有 \(summary.remainingDue) 张待复习")
                    .foregroundStyle(AppPalette.textSecondary)
            } else {
                Text("正式 SRS 进度未被改变。")
                    .foregroundStyle(AppPalette.textSecondary)
            }

            VStack(spacing: 12) {
                Button(summary.mode == .scheduled ? "再来一轮" : "再练一轮", action: onAgain)
                    .buttonStyle(LargePrimaryButtonStyle())
                Button("返回首页", action: onHome)
                    .buttonStyle(LargeSecondaryButtonStyle())
            }
            .frame(maxWidth: 380)
        }
        .padding(30)
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(AppPalette.textSecondary)
            Spacer()
            Text(value).bold().monospacedDigit()
        }
    }
}
