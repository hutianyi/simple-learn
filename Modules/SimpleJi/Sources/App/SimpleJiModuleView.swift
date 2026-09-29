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
