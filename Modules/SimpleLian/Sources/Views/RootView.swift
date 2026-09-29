import SwiftUI
import SwiftData
import StudyShell

struct RootView: View {
    @Query private var sessions: [PracticeSession]
    @EnvironmentObject private var moduleSession: ModuleSession
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
    }
}
