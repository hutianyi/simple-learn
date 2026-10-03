import SwiftUI
import StudyShell

public struct SimpleJiModuleView: View {
    @StateObject private var persistence = PersistenceController()
    @StateObject private var settings = SettingsStore(defaults: UserDefaults(suiteName: "com.hutianyi.SimpleXue.SimpleJi")!)
    @StateObject private var speech = SpeechService()
    @StateObject private var router = AppRouter()
    @EnvironmentObject private var session: ModuleSession
    @State private var revision = UUID()

    public init() {}
    public var body: some View {
        RootView(settings: settings, speech: speech)
            .id(revision)
            .environment(\.managedObjectContext, persistence.container.viewContext)
            .environmentObject(persistence).environmentObject(settings)
            .environmentObject(router).environmentObject(speech)
            .onChange(of: router.path, initial: true) { _, path in
                session.setBusy(path.contains(.review) || path.contains(.dictation) || path.contains(.extraPractice), reason: "ji.study")
            }
            .onReceive(NotificationCenter.default.publisher(for: .simpleJiDidRestore)) { _ in
                speech.stop(); router.reset(); revision = UUID()
            }
            .onDisappear { speech.stop(); session.setBusy(false, reason: "ji.study") }
    }
}

extension Notification.Name {
    static let simpleJiDidRestore = Notification.Name("SimpleXue.SimpleJi.didRestore")
}

// Logical export/restore keeps the database model and migration rules inside this module.
@MainActor
public enum SimpleJiBackupTransfer {
    private static func open() async throws -> PersistenceController {
        let persistence = PersistenceController()
        for _ in 0..<1000 {
            if let error = persistence.loadErrorMessage { throw WholeBackupError.message(error) }
            if persistence.isReady { return persistence }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw WholeBackupError.message("简单记数据库打开超时，未继续备份或恢复。")
    }
    public static func exportData() async throws -> Data {
        let persistence = try await open()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.hutianyi.SimpleXue.SimpleJi")!)
        let model = BackupViewModel(container: persistence.container, settings: settings)
        var envelope = try await BackupService.makeEnvelope(container: persistence.container,
            settings: model.settingsSnapshot,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        envelope.lastCelebratedCompletionDay = UserDefaults.standard.string(forKey: "simpleJi.lastCelebratedCompletionDay") ?? ""
        return try BackupService.encode(envelope)
    }
    public static func validate(_ data: Data) throws -> String {
        let backup = try BackupService.decodeAndValidate(data)
        return "单词 \(backup.data.words.count) 个 · 学习会话 \(backup.data.studySessions.count) 次"
    }
    public static func restore(_ data: Data) async throws {
        let backup = try BackupService.decodeAndValidate(data)
        let persistence = try await open()
        try await BackupService.restore(backup, into: persistence.container)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.hutianyi.SimpleXue.SimpleJi")!)
        BackupViewModel(container: persistence.container, settings: settings).apply(backup.data.settings)
        UserDefaults.standard.set(backup.lastCelebratedCompletionDay ?? "", forKey: "simpleJi.lastCelebratedCompletionDay")
    }
}
