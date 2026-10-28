import SwiftUI
import SwiftData
import StudyShell

struct RootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var moduleSession: ModuleSession
    @State private var presentedSession: PracticeSession?
    @State private var repairError: String?
    var body: some View {
        VStack(spacing: 0) {
            if let presentedSession {
                PracticeFlowView(session: presentedSession, close: { self.presentedSession = nil })
            } else {
                TabView {
                    Tab("今天", systemImage: "checkmark.circle") {
                        TodayView(openSession: { presentedSession = $0 })
                    }
                    Tab("题库", systemImage: "books.vertical") {
                        LibraryView()
                    }
                    Tab("数据", systemImage: "externaldrive") {
                        DataView()
                    }
                }
            }
        }
        .onAppear {
            moduleSession.prepareToLeave = { try context.save() }
        }
        .onDisappear { moduleSession.prepareToLeave = nil }
        .task {
            do {
                try PracticeService.discardEmptySessions(context: context)
                presentedSession = try PracticeService.activeSession(context: context)
            }
            catch { repairError = error.localizedDescription }
        }
        .alert("无法整理未完成练习", isPresented: Binding(get: { repairError != nil }, set: { if !$0 { repairError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(repairError ?? "") }
    }
}
