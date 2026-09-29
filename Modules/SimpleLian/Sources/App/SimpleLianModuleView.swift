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
