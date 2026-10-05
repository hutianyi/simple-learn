import CoreData
import SwiftUI

struct RootView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var speech: SpeechService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.scenePhase) private var scenePhase
    @State private var celebrationReady = true
    @State private var homeDate = Date()
    @State private var baselineErrorMessage: String?
    @State private var repairOffer: StudyRepairOffer?
    @State private var repairFlow: StudyRepairOffer?

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
                .onPreferenceChange(StudyCelebrationReadyKey.self) { celebrationReady = $0 }
                .background {
                    StudyCelebrationObserver(settings: settings, ready: celebrationReady && repairFlow == nil && repairOffer == nil)
                        .id(DictationEligibility.dayKey(for: homeDate))
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
        .alert("无法准备今日学习记录", isPresented: baselineErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(baselineErrorMessage ?? "发生未知错误。")
        }
        .alert("补上昨天，接回连续记录？", isPresented: Binding(
            get: { repairOffer != nil }, set: { if !$0 { repairOffer = nil } }), presenting: repairOffer) { offer in
            Button("补上昨天") { decideRepair(offer, accepted: true) }
            Button("放弃连续记录", role: .cancel) { decideRepair(offer, accepted: false) }
        } message: { offer in Text(offer.message) }
        .fullScreenCover(item: $repairFlow) { offer in
            StudyRepairFlowView(dayKey: offer.todayKey, container: persistence.container, settings: settings, speech: speech)
                .interactiveDismissDisabled()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { homeDate = Date() }
        }
        .task(id: "\(persistence.isReady)|\(DictationEligibility.dayKey(for: homeDate))") {
            guard persistence.isReady else { return }
            do {
                if settings.baselineCampaign == nil {
                    settings.baselineCampaign = try await DictationRepository(container: persistence.container)
                        .automaticBaselineCampaign(masteredTerms: settings.masteredDictationTerms)
                }
                try await StudyCompletionRepository(container: persistence.container).refresh(
                    scope: StudyCompletionScope(
                        baselineWordIDs: settings.baselineCampaign.map { Set($0.selectedWordIDs) },
                        masteredTerms: settings.masteredDictationTerms))
                repairOffer = try await StudyRepairRepository(container: persistence.container).prepare()
            } catch {
                baselineErrorMessage = error.localizedDescription
            }
        }
    }

    private func decideRepair(_ offer: StudyRepairOffer, accepted: Bool) {
        Task {
            do {
                try await StudyRepairRepository(container: persistence.container).decide(offer, accepted: accepted)
                if accepted { repairFlow = offer }
            } catch { baselineErrorMessage = error.localizedDescription }
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
            StatisticsView(settings: settings)
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

// Do not interrupt the final answer, its spoken feedback, or keyboard verification.
struct StudyCelebrationReadyKey: PreferenceKey {
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value && nextValue() }
}

private struct StudyCelebrationObserver: View {
    @ObservedObject var settings: SettingsStore
    let ready: Bool
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("simpleJi.lastCelebratedCompletionDay") private var lastCelebratedKey = ""
    @State private var showingCelebration = false
    @State private var presentedDayKey = ""
    @State private var recordError: String?
    @FetchRequest private var days: FetchedResults<StudyCompletionDayEntity>
    private var todayKey: String { DictationEligibility.dayKey(for: Date()) }
    private var todayData: Data? { days.first(where: { $0.dayKey == todayKey })?.snapshotData }

    init(settings: SettingsStore, ready: Bool) {
        self.settings = settings
        self.ready = ready
        let request = StudyCompletionDayEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "dayKey", ascending: false)]
        _days = FetchRequest(fetchRequest: request)
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: Trigger(data: todayData, ready: ready, active: scenePhase == .active)) {
                guard ready, scenePhase == .active, let data = todayData else { return }
                do {
                    let day = try JSONDecoder().decode(StudyCompletionDay.self, from: data)
                    guard StudyStreak.shouldCelebrate(day: day, todayKey: todayKey,
                        lastCelebratedKey: lastCelebratedKey) else { return }
                    presentedDayKey = day.dayKey
                    showingCelebration = true
                } catch { recordError = error.localizedDescription }
            }
            .fullScreenCover(isPresented: $showingCelebration) {
                NavigationStack {
                    StatisticsView(settings: settings, celebration: true)
                }
                .onAppear { lastCelebratedKey = presentedDayKey }
            }
            .alert("无法读取今日完成记录", isPresented: Binding(
                get: { recordError != nil }, set: { if !$0 { recordError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(recordError ?? "发生未知错误。") }
    }

    private struct Trigger: Equatable {
        let data: Data?
        let ready: Bool
        let active: Bool
    }
}
