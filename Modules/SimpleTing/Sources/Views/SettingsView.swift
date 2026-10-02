import SwiftUI
import StudyShell

struct ListenSettingsView: View {
    let speech: SpeechService
    let store: LibraryStore
    @Bindable var settings: ListenSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("语音") {
                    if speech.voices.isEmpty { Text("没有可用英语声音，请在 iPad 系统设置中准备英语语音。").foregroundStyle(.secondary) }
                    else {
                        Picker("英语声音", selection: $settings.voiceIdentifier) {
                            if !speech.voices.contains(where: { $0.id == settings.voiceIdentifier }) {
                                Text("所选声音当前不可用").tag(settings.voiceIdentifier)
                            }
                            ForEach(speech.voices) { voice in
                                Text("\(voice.name) · \(voice.language) · \(voice.quality)").tag(voice.id)
                            }
                        }
                    }
                    Button("刷新声音列表") { speech.refreshVoices() }
                    if !speech.actualVoiceName.isEmpty { Text("本次实际声音：\(speech.actualVoiceName)").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("播放") {
                    Picker("语速", selection: $settings.rate) {
                        ForEach(SpeechRatePreset.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("播放顺序", selection: Binding(get: { settings.order }, set: { speech.changeOrder($0) })) {
                        ForEach(PlaybackOrder.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("循环整个文章库", isOn: Binding(get: { settings.loopEnabled }, set: { speech.changeLoop($0) }))
                    Text("播放中更改声音或语速，从下一篇生效。正序按首次入库先后；倒序同时反转 Day 和篇目。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("定时结束") {
                    Picker("定时结束", selection: Binding(get: { speech.timerMinutes ?? 0 }, set: { speech.setSleepTimer($0 == 0 ? nil : $0) })) {
                        Text("关闭").tag(0)
                        ForEach([10, 15, 20, 30, 60], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }.disabled(speech.playback.state == .stopping)
                    Text("选择后立即计时；暂停和切歌不重置时间，停止播放会取消定时。").font(.footnote).foregroundStyle(.secondary)
                }
                backupSection
            }
            .navigationTitle("简单听设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.onAppear { speech.refreshVoices() }
    }
    private var backupSection: some View {
        Section("文章备份") {
            NavigationLink {
                ListenDataView(store: store, speech: speech, settings: settings)
            } label: { Label("备份与恢复", systemImage: "externaldrive") }
                .disabled(speech.playback.hasSession)
                .accessibilityIdentifier("listen.backup")
            Text(speech.playback.hasSession ? "请先停止播放和定时，再备份或恢复。" : "备份包含全部文章、原文和播放设置。内部安全副本只保留最近 10 份，请另行导出保存。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct ListenDataView: View {
    let store: LibraryStore
    let speech: SpeechService
    let settings: ListenSettings
    var body: some View {
        TransferView(title: "简单听", exportData: {
            try store.exportData(preferences: settings.snapshot)
        }, preview: { data in
            let backup = try ListenBackup.decode(data)
            return "材料：\(backup.library.days.count) 份\n文章：\(backup.library.days.reduce(0) { $0 + $1.articles.count }) 篇\n将替换当前文章库\(backup.preferences == nil ? "，保留当前播放设置。" : "和播放设置。")"
        }, restore: { data in
            guard !speech.playback.hasSession else { throw ListenError.message("请先停止播放和定时，再恢复文章库。") }
            let backup = try ListenBackup.decode(data)
            try store.restore(backup, settings: settings)
            speech.changeOrder(settings.order); speech.changeLoop(settings.loopEnabled)
            speech.replaceLibrary(store.library)
        })
    }
}
