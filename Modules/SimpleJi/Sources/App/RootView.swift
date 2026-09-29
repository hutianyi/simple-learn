import SwiftUI

struct RootView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var speech: SpeechService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.scenePhase) private var scenePhase
    @State private var homeDate = Date()
    @State private var baselineErrorMessage: String?

    var body: some View {
        Group {
            if persistence.isReady {
                NavigationStack(path: $router.path) {
                    HomeView(settings: settings, now: homeDate)
                        .id(DictationEligibility.dayKey(for: homeDate))
                        .navigationDestination(for: AppRoute.self) { route in
                            destination(for: route)
                        }
                }
            } else {
                ProgressView("正在准备学习记录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppPalette.background.ignoresSafeArea())
            }
        }
        .alert("无法打开本地数据库", isPresented: loadErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(persistence.loadErrorMessage ?? "发生未知错误。")
        }
        .alert("无法准备旧词摸底", isPresented: baselineErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(baselineErrorMessage ?? "发生未知错误。")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { homeDate = Date() }
        }
        .task(id: persistence.isReady) {
            guard persistence.isReady, settings.baselineCampaign == nil else { return }
            do {
                let campaign = try await DictationRepository(container: persistence.container)
                    .automaticBaselineCampaign(masteredTerms: settings.masteredDictationTerms)
                if settings.baselineCampaign == nil { settings.baselineCampaign = campaign }
            } catch {
                baselineErrorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .addWords:
            AddWordsView(container: persistence.container)
        case .review:
            ReviewSessionView(
                container: persistence.container,
                settings: settings,
                speech: speech
            )
        case .dictation:
            DictationView(
                container: persistence.container,
                settings: settings
            )
        case .extraPractice:
            ReviewSessionView(
                container: persistence.container,
                settings: settings,
                speech: speech,
                mode: .extraPractice,
                sessionLimit: extraPracticeLimit,
                extraPracticeScope: settings.extraPracticeScope
            )
        case .settings:
            SettingsView(
                settings: settings,
                speech: speech,
                container: persistence.container
            )
        case .statistics:
            StatisticsView()
        case .wordLibrary:
            WordLibraryView()
        }
    }

    private var extraPracticeLimit: Int? {
        switch settings.extraPracticeScope {
        case .weakest20: return 20
        case .weakest50: return 50
        case .allWeak, .everything: return nil
        }
    }

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { persistence.loadErrorMessage != nil },
            set: { isPresented in
                if !isPresented { persistence.dismissLoadError() }
            }
        )
    }

    private var baselineErrorBinding: Binding<Bool> {
        Binding(
            get: { baselineErrorMessage != nil },
            set: { if !$0 { baselineErrorMessage = nil } }
        )
    }
}
