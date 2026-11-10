import AVFoundation
import SwiftUI

struct BeiSettingsView: View {
    let store: BeiLibraryStore
    let probe: BeiVoicePreview
    @State private var preferences: BeiPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(store: BeiLibraryStore, probe: BeiVoicePreview) {
        self.store = store; self.probe = probe
        _preferences = State(initialValue: store.library.preferences)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("朗读声音") {
                    Text("请选择这台 iPad 上的语舒（优化音质）和 Zoe（高音质），试听后保存。找不到时请检查系统声音下载；不会自动换成其他声音。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    voicePicker(language: .chinese, selection: $preferences.chineseVoiceID)
                    voicePicker(language: .english, selection: $preferences.englishVoiceID)
                    if let error = probe.error { Text(error).foregroundStyle(.red) }
                    if probe.active { Button("停止当前操作") { probe.end() }.disabled(probe.state == .stopping) }
                }
                Section("常用播放设置") {
                    BeiSpeechRateControl(rate: $preferences.speechRate)
                    Toggle("无限循环", isOn: Binding(get: { preferences.totalPasses == nil }, set: { preferences.totalPasses = $0 ? nil : 3 }))
                    if preferences.totalPasses != nil {
                        Stepper("总遍数：\(preferences.totalPasses ?? 3)", value: Binding(get: { preferences.totalPasses ?? 3 }, set: { preferences.totalPasses = $0 }), in: 1...10000)
                    }
                    Stepper("句间额外停顿：\(preferences.sentencePause, specifier: "%.1f") 秒", value: $preferences.sentencePause, in: 0...60, step: 0.5)
                    Stepper("段间额外停顿：\(preferences.paragraphPause, specifier: "%.1f") 秒", value: $preferences.paragraphPause, in: 0...60, step: 0.5)
                    Stepper("每遍之间停顿：\(preferences.repeatPause, specifier: "%.1f") 秒", value: $preferences.repeatPause, in: 0...60, step: 0.5)
                    Text("保存后用于听课文与练习；正在进行的会话按开始时的设置播放。") .font(.caption).foregroundStyle(.secondary)
                }.disabled(probe.active)
                Section("正文显示") { Stepper("字号：\(Int(preferences.fontSize))", value: $preferences.fontSize, in: 16...48, step: 2) }.disabled(probe.active)
                if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("播放与显示设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("放弃修改") { dismiss() }.disabled(store.busy || probe.active) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { if await store.savePreferences(preferences) { dismiss() } } }.disabled(store.busy || probe.active)
                }
            }
            .disabled(store.busy)
        }
        .interactiveDismissDisabled()
        .onChange(of: scenePhase) { _, value in probe.sceneChanged(String(describing: value)) }
    }
    @ViewBuilder private func voicePicker(language: PassageLanguage, selection: Binding<String?>) -> some View {
        let candidates = probe.voices.filter { BeiVoicePreview.isRequestedVoice($0, language: language) }
        Picker("\(language.title)声音", selection: selection) {
            Text("请选择声音").tag(String?.none)
            if let saved = selection.wrappedValue, !candidates.contains(where: { $0.identifier == saved }) {
                Text("原声音暂不可用，请重新选择").tag(Optional(saved))
            }
            ForEach(candidates, id: \.identifier) { voice in
                Text("\(voice.name) · \(voice.language) · \(quality(voice))").tag(Optional(voice.identifier))
            }
        }.disabled(probe.active)
        Button("试听\(language.title)声音") {
            probe.audition(text: language == .chinese ? "春天来了，小树长出了新叶。" : "Spring is here. The trees have new leaves.", language: language, voiceID: selection.wrappedValue, rate: preferences.speechRate)
        }.disabled(probe.active)
    }
    private func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality { case .default: "系统基础音质"; case .enhanced: "系统优化音质"; case .premium: "系统高音质"; @unknown default: "系统音质" }
    }
}

// Keep drag updates local so the lesson and sentence list only refresh on release.
struct BeiSpeechRateControl: View {
    @Binding var rate: Float
    var onCommit: () -> Void = {}
    @State private var selection: Double
    private static let rates: [Float] = [0.1, 0.35, 0.45, 0.55, 0.65]
    private static let titles = ["很慢", "慢", "正常", "快", "很快"]

    init(rate: Binding<Float>, onCommit: @escaping () -> Void = {}) {
        _rate = rate
        self.onCommit = onCommit
        _selection = State(initialValue: Self.nearestIndex(to: rate.wrappedValue))
    }

    var body: some View {
        HStack {
            Text("语速")
            Slider(value: $selection, in: 0...4, step: 1) { editing in
                if !editing {
                    commitSelection()
                }
            }
            .accessibilityLabel("语速")
            .accessibilityValue(Self.titles[Int(selection)])
            .accessibilityIdentifier("bei.speechRate")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: selection = min(4, selection + 1)
                case .decrement: selection = max(0, selection - 1)
                @unknown default: return
                }
                commitSelection()
            }
            Text(Self.titles[Int(selection)])
                .frame(width: 44, alignment: .trailing)
        }
        .onChange(of: rate) { _, value in selection = Self.nearestIndex(to: value) }
    }

    private func commitSelection() {
        let selectedRate = Self.rates[Int(selection)]
        guard selectedRate != rate else { return }
        rate = selectedRate
        onCommit()
    }

    private static func nearestIndex(to rate: Float) -> Double {
        Double(rates.indices.min(by: { abs(rates[$0] - rate) < abs(rates[$1] - rate) }) ?? 2)
    }
}
