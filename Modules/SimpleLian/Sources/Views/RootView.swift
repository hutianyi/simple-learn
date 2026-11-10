import SwiftUI
import SwiftData
import StudyShell

struct RootView: View {
    private enum Page: Hashable { case today, library }
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var moduleSession: ModuleSession
    @State private var presentedSession: PracticeSession?
    @State private var repairError: String?
    @State private var selectedPage: Page = .today
    var body: some View {
        VStack(spacing: 0) {
            if let presentedSession {
                PracticeFlowView(session: presentedSession, close: { self.presentedSession = nil })
            } else {
                TabView(selection: $selectedPage) {
                    Tab("今天", systemImage: "checkmark.circle", value: Page.today) {
                        TodayView(openSession: { presentedSession = $0 })
                            .toolbarVisibility(.hidden, for: .tabBar)
                    }
                    Tab("题库", systemImage: "books.vertical", value: Page.library) {
                        LibraryView()
                            .toolbarVisibility(.hidden, for: .tabBar)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack(spacing: 30) {
                        StudyNavigationButton("今天", symbol: "checkmark.circle", isSelected: selectedPage == .today) {
                            selectedPage = .today
                        }
                        .accessibilityIdentifier("lian.page.today")
                        StudyNavigationButton("题库", symbol: "books.vertical", isSelected: selectedPage == .library) {
                            selectedPage = .library
                        }
                        .accessibilityIdentifier("lian.page.library")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .background(StudyAppearance.background)
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
