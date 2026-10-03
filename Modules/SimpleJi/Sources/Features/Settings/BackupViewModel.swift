import CoreData
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum BackupAlertState: Identifiable {
    case confirmRestore
    case confirmReset
    case message(title: String, message: String)

    var id: String {
        switch self {
        case .confirmRestore: return "confirmRestore"
        case .confirmReset: return "confirmReset"
        case .message(let title, let message): return "message|\(title)|\(message)"
        }
    }
}

@MainActor
final class BackupViewModel: ObservableObject {
    @Published var exportDocument: BackupDocument?
    @Published var isShowingExporter = false
    @Published var isShowingImporter = false
    @Published var alertState: BackupAlertState?
    @Published private(set) var isBusy = false

    private let container: NSPersistentContainer
    private let settings: SettingsStore
    private var pendingEnvelope: BackupEnvelope?

    init(container: NSPersistentContainer, settings: SettingsStore) {
        self.container = container
        self.settings = settings
    }

    var pendingSummaryText: String {
        pendingEnvelope.map { BackupSummary(envelope: $0).confirmationText } ?? ""
    }

    var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "简单记-Backup-\(formatter.string(from: Date()))"
    }

    func copyAllEnglish() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let context = container.newBackgroundContext()
            let entries: [String] = try await context.perform {
                let request = WordEntity.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(keyPath: \WordEntity.createdAt, ascending: false),
                    NSSortDescriptor(keyPath: \WordEntity.importPosition, ascending: true),
                    NSSortDescriptor(keyPath: \WordEntity.normalizedEnglish, ascending: true)
                ]
                return try context.fetch(request).map { word in
                    word.english.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                }
            }
            guard !entries.isEmpty else {
                alertState = .message(title: "词库为空", message: "还没有可复制的英文单词或词组。")
                return
            }
            UIPasteboard.general.string = entries.joined(separator: "\n")
            alertState = .message(
                title: "已复制",
                message: "已将 \(entries.count) 个英文单词或词组复制到剪贴板，一行一个。"
            )
        } catch {
            alertState = .message(title: "复制失败", message: error.localizedDescription)
        }
    }

    func prepareExport() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let envelope = try await currentEnvelope()
            exportDocument = BackupDocument(data: try BackupService.encode(envelope))
            isShowingExporter = true
        } catch {
            showError(error)
        }
    }

    func handleImport(_ result: Result<URL, Error>) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try result.get()
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            pendingEnvelope = try BackupService.decodeAndValidate(data)
            alertState = .confirmRestore
        } catch {
            showError(error)
        }
    }

    func confirmRestore() async {
        guard let pendingEnvelope else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let safetyEnvelope = try await currentEnvelope()
            let safetyData = try BackupService.encode(safetyEnvelope)
            try writeSafetyBackup(safetyData, reason: "PreRestore")

            try await BackupService.restore(pendingEnvelope, into: container)
            apply(pendingEnvelope.data.settings)
            NotificationCenter.default.post(name: .simpleJiDidRestore, object: nil)
            self.pendingEnvelope = nil
            alertState = .message(
                title: "操作完成",
                message: "恢复完成。当前词库、学习记录和设置已替换；恢复前安全备份已保存在 App 本地。"
            )
        } catch {
            showError(error)
        }
    }

    func confirmResetLearningProgress() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let safetyEnvelope = try await currentEnvelope()
            let safetyData = try BackupService.encode(safetyEnvelope)
            try writeSafetyBackup(safetyData, reason: "PreReset")
            try await LearningProgressResetService.reset(container: container)
            settings.baselineCampaign = nil
            settings.masteredDictationTerms = []
            alertState = .message(
                title: "操作完成",
                message: "学习记录已清除。单词全部保留，卡片两个方向和默写进度均已重置。"
            )
        } catch {
            showError(error)
        }
    }

    func requestResetConfirmation() {
        alertState = .confirmReset
    }

    private func currentEnvelope() async throws -> BackupEnvelope {
        try await BackupService.makeEnvelope(
            container: container,
            settings: settingsSnapshot,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
        )
    }

    var settingsSnapshot: BackupSettings {
        BackupSettings(
            sessionLimit: settings.sessionLimit.rawValue,
            englishVoiceIdentifier: settings.englishVoiceIdentifier,
            chineseVoiceIdentifier: settings.chineseVoiceIdentifier,
            englishSpeechRate: settings.englishSpeechRate,
            chineseSpeechRate: settings.chineseSpeechRate,
            autoSpeakFront: settings.autoSpeakFront,
            autoSpeakBack: settings.autoSpeakBack,
            hapticsEnabled: settings.hapticsEnabled,
            extraPracticeScope: settings.extraPracticeScope.rawValue,
            dictationLimit: settings.dictationLimit.rawValue,
            baselineCampaign: settings.baselineCampaign,
            masteredDictationTerms: settings.masteredDictationTerms.sorted()
        )
    }

    func apply(_ snapshot: BackupSettings) {
        settings.sessionLimit = SessionLimitOption(rawValue: snapshot.sessionLimit) ?? .thirty
        settings.englishVoiceIdentifier = snapshot.englishVoiceIdentifier
        settings.chineseVoiceIdentifier = snapshot.chineseVoiceIdentifier
        settings.englishSpeechRate = snapshot.englishSpeechRate
        settings.chineseSpeechRate = snapshot.chineseSpeechRate
        settings.autoSpeakFront = snapshot.autoSpeakFront
        settings.autoSpeakBack = snapshot.autoSpeakBack
        settings.hapticsEnabled = snapshot.hapticsEnabled
        settings.extraPracticeScope = ExtraPracticeScope(rawValue: snapshot.extraPracticeScope) ?? .weakest20
        settings.dictationLimit = DictationLimitOption(rawValue: snapshot.dictationLimit ?? 20) ?? .twenty
        settings.baselineCampaign = snapshot.baselineCampaign
        settings.masteredDictationTerms = Set(snapshot.masteredDictationTerms ?? [])
    }

    private func writeSafetyBackup(_ data: Data, reason: String) throws {
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("SimpleXue/SimpleJi/SafetyBackups", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "WordMemoryCards-\(reason)-\(formatter.string(from: Date())).json"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func showError(_ error: Error) {
        alertState = .message(
            title: "备份操作失败",
            message: error.localizedDescription
        )
    }
}
