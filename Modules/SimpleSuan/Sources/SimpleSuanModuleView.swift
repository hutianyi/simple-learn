import SwiftUI
import StudyShell

public struct SimpleSuanModuleView: View {
    @StateObject private var store = AppDataStore()
    public init() {}
    public var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError {
                Text("历史记录读取失败，请保留数据：\(error)")
                    .font(.footnote).foregroundStyle(.red).padding()
            }
            ContentView().environmentObject(store)
        }
    }
}

@MainActor
public enum SimpleSuanBackupTransfer {
    public static func learningOverview(now: Date = Date()) throws -> String {
        try learningOverviewStatus(now: now).text
    }
    public static func learningOverviewStatus(now: Date = Date()) throws -> (text: String, isComplete: Bool) {
        let data = try PersistenceService.shared.load()
        let count = PracticeActivity(sessions: data.sessions, now: now).todayCount
        return count > 0 ? ("今日已完成", true) : ("今日待做40题", false)
    }
    public static func exportData() throws -> Data {
        try SuanBackup.encode(PersistenceService.shared.load())
    }
    public static func validate(_ data: Data) throws -> String {
        let backup = try SuanBackup.decode(data)
        return "练习 \(backup.sessions.count) 次 · 作答 \(backup.sessions.reduce(0) { $0 + $1.questions.count }) 题"
    }
    public static func restore(_ data: Data) throws {
        try PersistenceService.shared.save(SuanBackup.decode(data))
    }
}
