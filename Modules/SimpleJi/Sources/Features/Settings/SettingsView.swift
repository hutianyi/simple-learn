import CoreData
import SwiftUI
import StudyShell
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var moduleSession: ModuleSession
    @ObservedObject var settings: SettingsStore
    @ObservedObject var speech: SpeechService
    @EnvironmentObject private var router: AppRouter
    @StateObject private var backup: BackupViewModel

    init(
        settings: SettingsStore,
        speech: SpeechService,
        container: NSPersistentContainer
    ) {
        self.settings = settings
        self.speech = speech
        _backup = StateObject(
            wrappedValue: BackupViewModel(container: container, settings: settings)
        )
    }

    var body: some View {
        Form {
            Section {
                Text("正式复习不限制每轮卡片数量")

                Picker("额外加练范围", selection: $settings.extraPracticeScope) {
                    ForEach(ExtraPracticeScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Button("开始额外加练") {
                    router.push(.extraPractice)
                }
            } header: {
                Text("复习")
            }

            Section {
                Picker("每日默写上限", selection: $settings.dictationLimit) {
                    ForEach(DictationLimitOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Text("默写默认每天 20 个，到期和逾期的词一起安排，超出上限的留到后续日期。调整后当天立即生效，已默写的词计入上限；已开始的题和错词订正会保留。旧词摸底也遵守设置的上限，选择不限时每天最多 50 个。补上连续记录不会额外加量。")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.textSecondary)
            } header: {
                Text("默写")
            }

            Section {
                Picker("英文语音", selection: $settings.englishVoiceIdentifier) {
                    Text("自动选择 Zoe").tag(String?.none)
                    ForEach(speech.englishVoices) { voice in
                        Text(voice.displayName).tag(Optional(voice.identifier))
                    }
                }
                Picker("中文语音", selection: $settings.chineseVoiceIdentifier) {
                    Text("自动选择语舒").tag(String?.none)
                    ForEach(speech.chineseVoices) { voice in
                        Text(voice.displayName).tag(Optional(voice.identifier))
                    }
                }
                speechRateRow(
                    title: "英文语速",
                    value: $settings.englishSpeechRate
                )
                speechRateRow(
                    title: "中文语速",
                    value: $settings.chineseSpeechRate
                )
                Toggle("自动朗读正面", isOn: $settings.autoSpeakFront)
                Toggle("自动朗读答案", isOn: $settings.autoSpeakBack)
                Button("试听英文") {
                    speech.speak(
                        "apple",
                        language: .english,
                        preferredIdentifier: settings.englishVoiceIdentifier,
                        rate: settings.englishSpeechRate
                    )
                }
                Button("试听中文") {
                    speech.speak(
                        "苹果",
                        language: .chinese,
                        preferredIdentifier: settings.chineseVoiceIdentifier,
                        rate: settings.chineseSpeechRate
                    )
                }
            } header: {
                Text("发音")
            } footer: {
                Text("这里只显示设备实际提供的系统语音；最终声音效果以 iPad 真机为准。")
            }

            Section {
                Toggle("触觉反馈", isOn: $settings.hapticsEnabled)
            } header: {
                Text("反馈")
            }

            Section {
                Button("复制全部英文到剪贴板") {
                    Task { await backup.copyAllEnglish() }
                }
                .accessibilityIdentifier("settings.copyAllEnglish")
                Button("导出完整备份") {
                    Task { await backup.prepareExport() }
                }
                Button("从备份恢复") {
                    backup.isShowingImporter = true
                }
                .foregroundStyle(.red)
                Button("清除全部学习记录", role: .destructive) {
                    backup.requestResetConfirmation()
                }
                .accessibilityIdentifier("settings.resetProgress")
            } header: {
                Text("数据管理")
            } footer: {
                Text("复制英文：按词库顺序，一行一个单词或词组。完整备份为 JSON 格式，包含词库、卡片与默写学习记录、未完成任务和设置；恢复前会先校验，并自动保存当前数据的安全备份。")
            }

            Section {
                Text("所有单词和学习记录只保存在这台 iPad，不会上传。")
                    .foregroundStyle(AppPalette.textSecondary)
            } header: {
                Text("隐私")
            }
        }
        .onChange(of: backup.isBusy) { _, busy in moduleSession.setBusy(busy, reason: "ji.backup") }
        .onDisappear { moduleSession.setBusy(false, reason: "ji.backup") }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { speech.refreshVoices() }
        .disabled(backup.isBusy)
        .overlay {
            if backup.isBusy {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("正在处理数据…")
                        .padding(24)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .fileExporter(
            isPresented: $backup.isShowingExporter,
            document: backup.exportDocument,
            contentType: .json,
            defaultFilename: backup.defaultFilename
        ) { result in
            if case .failure(let error) = result {
                backup.alertState = .message(
                    title: "备份操作失败",
                    message: error.localizedDescription
                )
            }
        }
        .fileImporter(
            isPresented: $backup.isShowingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            Task {
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        await backup.handleImport(.success(url))
                    } else {
                        await backup.handleImport(.failure(CocoaError(.fileReadNoSuchFile)))
                    }
                case .failure(let error):
                    await backup.handleImport(.failure(error))
                }
            }
        }
        .alert(item: $backup.alertState, content: makeAlert)
    }

    private func speechRateRow(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            Slider(value: value, in: 0.30...0.62) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: "tortoise.fill")
            } maximumValueLabel: {
                Image(systemName: "hare.fill")
            }
        }
    }

    private func makeAlert(_ state: BackupAlertState) -> Alert {
        switch state {
        case .confirmRestore:
            return Alert(
                title: Text("确认恢复备份？"),
                message: Text(backup.pendingSummaryText),
                primaryButton: .destructive(Text("恢复并替换当前数据")) {
                    Task { await backup.confirmRestore() }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        case .confirmReset:
            return Alert(
                title: Text("清除全部学习记录？"),
                message: Text("所有单词会保留。卡片复习、加练、默写进度与未完成任务都会清除。清除前会自动生成本地安全备份。"),
                primaryButton: .destructive(Text("确认清除")) {
                    Task { await backup.confirmResetLearningProgress() }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        case .message(let title, let message):
            return Alert(
                title: Text(title),
                message: Text(message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}
