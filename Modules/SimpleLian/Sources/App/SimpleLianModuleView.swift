import SwiftData
import SwiftUI
import StudyShell

enum AppSchema {
    static let schema = Schema([ImportBatch.self, ProblemGroup.self, Question.self, ReviewState.self,
        PracticeSession.self, Attempt.self, SessionGroupProgress.self])
}

@MainActor
private final class LianStorage: ObservableObject {
    let container: ModelContainer?
    let error: String?
    init() {
        do {
            let url = try ModuleStorage.directory("SimpleLian").appendingPathComponent("SimpleLian.store")
            let config = ModelConfiguration("SimpleLian", schema: AppSchema.schema, url: url, cloudKitDatabase: .none)
            container = try ModelContainer(for: AppSchema.schema, configurations: config)
            error = nil
        } catch { container = nil; self.error = error.localizedDescription }
    }
}

public struct SimpleLianModuleView: View {
    @StateObject private var storage = LianStorage()
    public init() {}
    public var body: some View {
        if let container = storage.container { RootView().modelContainer(container) }
        else {
            ContentUnavailableView("无法打开简单练题库", systemImage: "externaldrive.badge.exclamationmark",
                description: Text(storage.error ?? "请保留现有数据。"))
        }
    }
}

@MainActor
public enum SimpleLianBackupTransfer {
    private static func open() throws -> ModelContainer {
        let storage = LianStorage()
        guard let container = storage.container else {
            throw WholeBackupError.message(storage.error ?? "简单练数据库无法打开。")
        }
        return container
    }
    public static func exportData() throws -> Data {
        let container = try open()
        return try BackupService.exportData(context: container.mainContext)
    }
    public static func learningOverview(now: Date = Date()) throws -> String {
        let container = try open()
        return try PracticeService.overview(context: container.mainContext, day: DayKey.make(from: now))
    }
    public static func validate(_ data: Data) throws -> String {
        let backup = try BackupService.validate(data)
        return "题目 \(backup.questions.count) 道 · 练习会话 \(backup.sessions.count) 次"
    }
    public static func restore(_ data: Data) throws {
        let backup = try BackupService.validate(data)
        let container = try open()
        try BackupService.restore(backup, context: container.mainContext)
    }
}
