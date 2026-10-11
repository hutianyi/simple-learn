import SwiftUI
import SwiftData
import StudyShell

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var sessions: [PracticeSession]
    @EnvironmentObject private var moduleSession: ModuleSession
    @State private var repairError: String?
    var body: some View {
        TabView {
            Tab("今天", systemImage: "checkmark.circle") {
                TodayView()
            }
            Tab("题库", systemImage: "books.vertical") {
                LibraryView()
            }
            Tab("数据", systemImage: "externaldrive") {
                DataView()
            }
        }
        .onChange(of: sessions.contains { $0.completedAt == nil }, initial: true) { _, busy in
            moduleSession.setBusy(busy, reason: "lian.study")
        }
        .onDisappear { moduleSession.setBusy(false, reason: "lian.study") }
        .task {
            do { try PracticeService.discardEmptySessions(context: context) }
            catch { repairError = error.localizedDescription }
        }
        .alert("无法整理未完成练习", isPresented: Binding(get: { repairError != nil }, set: { if !$0 { repairError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(repairError ?? "") }
    }
}
