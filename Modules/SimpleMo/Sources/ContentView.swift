//
//  ContentView.swift
//  默写小程序
//
//  Created by 胡天翼 on 2026/8/12.
//

import SwiftUI
import StudyShell

struct ContentView: View {
    @EnvironmentObject private var moduleSession: ModuleSession
    @StateObject private var session = DictationSession()
    @AppStorage("dictation.input") private var inputText = "苹果\n认真\n美丽\numbrella\nwonderful"
    @AppStorage("dictation.shuffle") private var shuffleWords = false
    @AppStorage("dictation.rate") private var speechRate = 0.42
    @AppStorage("dictation.repeatAfter") private var repeatAfterSeconds = DictationTimingConfiguration.defaultRepeatAfterSeconds
    @AppStorage("dictation.advanceAfter") private var advanceAfterSeconds = DictationTimingConfiguration.defaultAdvanceAfterSeconds
    @Environment(\.scenePhase) private var scenePhase

    /// 响应式布局：中央内容最大宽度。
    /// iPhone / 小窗口自然收缩；iPad 横屏限制阅读宽度，避免无限拉宽。
    private static let maxContentWidth: CGFloat = 960

    private var words: [String] { DictationCore.parseWords(from: inputText) }
    private var timing: DictationTimingConfiguration {
        DictationTimingConfiguration(repeatAfterSeconds: repeatAfterSeconds, advanceAfterSeconds: advanceAfterSeconds)
    }
    var body: some View {
        Group {
            switch session.phase {
            case .setup: setupView
            case .dictating: dictatingView
            case .finished: finishedView
            }
        }
        .onAppear(perform: normalizeSettings)
        .onChange(of: session.phase, initial: true) { _, phase in
            moduleSession.setBusy(phase == .dictating, reason: "mo.study")
        }
        .onDisappear { session.returnToSetup(); moduleSession.setBusy(false, reason: "mo.study") }
        .onChange(of: scenePhase) { session.handleScenePhase($0) }
    }

    private var setupView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "text.book.closed.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.blue)
                        Text("简单默")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("粘贴词语，逐个听写")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("默写内容").font(.headline)
                                Spacer()
                                Text("共 \(words.count) 个").foregroundStyle(.secondary)
                                Button {
                                    inputText = ""
                                } label: {
                                    Label("清空", systemImage: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(inputText.isEmpty)
                                .accessibilityIdentifier("clearInputButton")
                            }
                            TextEditor(text: $inputText)
                                .font(.body)
                                .frame(minHeight: 220)
                                .padding(8)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("默写内容")
                            Text("空格、换行、逗号和分号都可以分隔词语。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                }
                .padding()
                .frame(maxWidth: Self.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 内层 ViewThatFits 优先横排，窄窗口 / 大字号时退化为竖排；
                // 外层 frame 链先限制内容宽度（960），再占满整个窗口宽度，
                // 使 ultraThinMaterial 背景横向铺满窗口而不是只覆盖中央内容。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        NavigationLink("数据") { MoDataView() }.buttonStyle(.bordered)
                        settingsLink()
                        startButton
                    }
                    VStack(spacing: 12) {
                        settingsLink(fillWidth: true)
                        startButton
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: Self.maxContentWidth)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        }
    }

    private func settingsLink(fillWidth: Bool = false) -> some View {
        NavigationLink {
            DictationSettingsView(
                session: session,
                shuffleWords: $shuffleWords,
                repeatAfterSeconds: $repeatAfterSeconds,
                advanceAfterSeconds: $advanceAfterSeconds,
                speechRate: $speechRate
            )
        } label: {
            Label("设置", systemImage: "gearshape")
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var startButton: some View {
        Button {
            session.start(words: words, shuffled: shuffleWords, rate: speechRate, timing: timing)
        } label: {
            Label("开始默写", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(words.isEmpty || !timing.isValid)
    }

    private var dictatingView: some View {
        // 全屏背景铺满整个窗口，实际内容限制在中央 960pt 内。
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                HStack {
                    Button("结束") { session.returnToSetup() }
                    Spacer()
                    Text("第 \(session.currentIndex + 1) 个，共 \(session.totalCount) 个")
                        .font(.headline.monospacedDigit())
                }
                ProgressView(value: session.progress).tint(.blue)
                Spacer()
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 86))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("正在默写")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("答案已隐藏，请听语音").foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    Text("还剩 \(session.secondsRemaining) 秒")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("将在开始后 \(session.timing.advanceAfterSeconds) 秒自动进入下一个")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(countdownColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("本词剩余 \(session.secondsRemaining) 秒")
                // 正常宽度横排；窄窗口 / 大字号空间不足时自动退化为竖排。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        repeatCurrentButton
                        nextButton
                    }
                    VStack(spacing: 14) {
                        repeatCurrentButton
                        nextButton
                    }
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: Self.maxContentWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var repeatCurrentButton: some View {
        Button {
            session.repeatCurrent()
        } label: {
            Label("重复读两遍", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var nextButton: some View {
        Button {
            session.next()
        } label: {
            Label("下一个", systemImage: "forward.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var finishedView: some View {
        // 全屏背景铺满整个窗口，实际内容限制在中央 960pt 内。
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(.green)
                Text("默写结束")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("今天完成了 \(session.totalCount) 个词语").foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        editWordsButton
                        restartButton
                    }
                    VStack(spacing: 14) {
                        editWordsButton
                        restartButton
                    }
                }
                .controlSize(.large)
                Spacer()
            }
            .padding()
            .frame(maxWidth: Self.maxContentWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editWordsButton: some View {
        Button("修改词语") { session.returnToSetup() }.buttonStyle(.bordered)
    }

    private var restartButton: some View {
        Button("再默写一遍") { session.restart() }.buttonStyle(.borderedProminent)
    }

    private var countdownColor: Color {
        if session.secondsRemaining <= 5 { return .red }
        if session.secondsRemaining <= session.timing.remainingSecondsAfterRepeat { return .orange }
        return .blue
    }

    private func normalizeSettings() {
        advanceAfterSeconds = min(max(advanceAfterSeconds, DictationTimingConfiguration.minimumAdvanceAfterSeconds), DictationTimingConfiguration.maximumAdvanceAfterSeconds)
        advanceAfterSeconds -= advanceAfterSeconds % DictationTimingConfiguration.stepSeconds
        repeatAfterSeconds = max(DictationTimingConfiguration.stepSeconds, repeatAfterSeconds)
        repeatAfterSeconds -= repeatAfterSeconds % DictationTimingConfiguration.stepSeconds
        if repeatAfterSeconds > advanceAfterSeconds - DictationTimingConfiguration.minimumGapSeconds {
            repeatAfterSeconds = advanceAfterSeconds - DictationTimingConfiguration.minimumGapSeconds
        }
    }
}

private struct DictationSettingsView: View {
    @ObservedObject var session: DictationSession
    @Binding var shuffleWords: Bool
    @Binding var repeatAfterSeconds: Int
    @Binding var advanceAfterSeconds: Int
    @Binding var speechRate: Double

    var body: some View {
        Form {
            Section("朗读") {
                HStack {
                    Label("朗读速度", systemImage: "speaker.wave.2")
                    Slider(value: $speechRate, in: 0.32...0.55, step: 0.01)
                    Text(String(format: "%.2f", speechRate))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Section("系统声音") {
                Text("中文跟随系统朗读声音；英文词会自动使用系统英语声音。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("默写流程") {
                Toggle("随机顺序", isOn: $shuffleWords)
                Stepper(value: $repeatAfterSeconds, in: 5...(advanceAfterSeconds - 5), step: 5) {
                    settingRow(title: "自动重读", seconds: repeatAfterSeconds)
                }
                Stepper(value: $advanceAfterSeconds, in: (repeatAfterSeconds + 5)...DictationTimingConfiguration.maximumAdvanceAfterSeconds, step: 5) {
                    settingRow(title: "自动进入下一个", seconds: advanceAfterSeconds)
                }
            }

            Section {
                Text("即使静音开关开启，语音仍会播放。默写期间屏幕会保持常亮。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink("数据") { MoDataView() } } }
            .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func settingRow(title: String, seconds: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("开始后 \(seconds) 秒").foregroundStyle(.secondary)
        }
    }

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
