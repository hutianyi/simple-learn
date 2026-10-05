import CoreData
import SwiftUI
import StudyShell

struct StudyRepairFlowView: View {
    let dayKey: String
    let container: NSPersistentContainer
    @ObservedObject var settings: SettingsStore
    @ObservedObject var speech: SpeechService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var moduleSession: ModuleSession
    @AppStorage("simpleJi.lastCelebratedCompletionDay") private var lastCelebratedKey = ""
    @State private var stage = Stage.loading
    @State private var stageID = UUID()
    @State private var isAdvancing = false
    @State private var errorMessage: String?

    private enum Stage {
        case loading, cards, dictation, complete, expired
        var title: String {
            switch self {
            case .cards: return "先完成今天的卡片"
            case .dictation: return "接着完成默写和订正"
            default: return "补上昨天＋完成今天"
            }
        }
    }
    private var repository: StudyRepairRepository { StudyRepairRepository(container: container) }

    var body: some View {
        VStack(spacing: 0) {
            if case .complete = stage {} else {
                Text(stage.title).font(.headline).padding(12)
                Text("跟着这一轮做完，就能接回连续记录。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            content.id(stageID)
        }
        .background(AppPalette.background)
        .task {
            moduleSession.setBusy(true, reason: "ji.repair")
            await advance()
        }
        .onDisappear {
            speech.stop()
            moduleSession.setBusy(false, reason: "ji.repair")
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in checkExpiry() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { checkExpiry() } }
        .alert("补学暂时无法继续", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("重试") { Task { await advance() } }
            Button("结束补学", role: .destructive) { end() }
        } message: { Text(errorMessage ?? "请保留当前页面后重试。") }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .loading:
            ProgressView("正在衔接下一项学习…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cards:
            ReviewSessionView(container: container, settings: settings, speech: speech,
                onComplete: { Task { await advance() } }, onExit: end)
        case .dictation:
            DictationView(container: container, settings: settings,
                onComplete: { Task { await advance() } }, onExit: end)
        case .complete:
            NavigationStack { StatisticsView(settings: settings, celebration: true) }
                .onAppear { lastCelebratedKey = dayKey }
        case .expired:
            VStack(spacing: 20) {
                Text("今天的补学机会已结束").font(.title.bold())
                Text("已经跨天，连续记录从新的一天开始。做过的学习记录会保留。")
                    .multilineTextAlignment(.center)
                Button("返回首页", action: end).buttonStyle(LargePrimaryButtonStyle())
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func advance() async {
        guard !isAdvancing else { return }
        guard OneDayStreakRepair.dayKey(Date()) == dayKey else { stage = .expired; return }
        isAdvancing = true
        defer { isAdvancing = false }
        do {
            let day = try await repository.today()
            guard let plan = day.repair else { throw StudyRepairRepository.RepairError.unavailable }
            if plan.status == .completed && day.isComplete {
                speech.stop()
                stage = .complete
            } else if plan.status != .accepted {
                throw StudyRepairRepository.RepairError.expired
            } else if !day.cardsComplete {
                stage = .cards
            } else if !day.dictationComplete {
                stage = .dictation
            } else {
                throw StudyRepairRepository.RepairError.unavailable
            }
            stageID = UUID()
        } catch { errorMessage = error.localizedDescription }
    }

    private func checkExpiry() {
        guard OneDayStreakRepair.dayKey(Date()) != dayKey else { return }
        if case .complete = stage { return }
        if case .expired = stage { return }
        speech.stop()
        stage = .expired
        stageID = UUID()
    }

    private func end() {
        Task {
            do {
                try await repository.abandon(dayKey: dayKey)
                speech.stop()
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
