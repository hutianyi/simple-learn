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
                    Text("语速：\(rateDescription)")
                    Slider(value: $preferences.speechRate, in: 0.1...0.65, step: 0.01)
                    HStack {
                        Button("慢") { preferences.speechRate = 0.35 }
                        Button("正常") { preferences.speechRate = 0.45 }
                        Button("快") { preferences.speechRate = 0.55 }
                    }.buttonStyle(.bordered)
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
    private var rateDescription: String { preferences.speechRate < 0.4 ? "慢" : (preferences.speechRate > 0.5 ? "快" : "正常") }
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
