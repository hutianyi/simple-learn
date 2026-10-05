import SwiftUI
import StudyShell

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack { StartPracticeView() }
                .tabItem { Label("练习", systemImage: "plus.forwardslash.minus") }
            NavigationStack { SuanDataView() }.tabItem { Label("数据", systemImage: "externaldrive") }
            NavigationStack { StatisticsView() }
                .tabItem { Label("统计", systemImage: "chart.line.uptrend.xyaxis") }
        }
    }
}

struct StartPracticeView: View {
    @EnvironmentObject private var store: AppDataStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: PracticeMode = .mixed
    @State private var mixedOperations = Set(OperationType.allCases)
    @State private var questionCount = 40
    @State private var practice: PracticeViewModel?
    @State private var repairOffer: OneDayStreakRepair.Offer?
    @State private var repairError: String?
    @State private var checkedDayKey = ""
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("简单算").font(.system(size: 48, weight: .bold))
            Text("选择题型和题目数量，开始心算练习。")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("题型").font(.headline)
                Picker("题型", selection: $mode) { ForEach(PracticeMode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
            }
            .frame(maxWidth: 600)
            if mode == .mixed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("混合题型").font(.headline)
                    Text("至少选择两种题型；题目会在已选类型间尽量均衡。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(OperationType.allCases) { operation in
                            Button(operation.title) { toggle(operation) }
                                .buttonStyle(.borderedProminent)
                                .tint(mixedOperations.contains(operation) ? .accentColor : .gray)
                        }
                    }
                }.frame(maxWidth: 600, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("题目数量").font(.headline)
                HStack { ForEach([10, 20, 30, 40], id: \.self) { count in Button("\(count)题") { questionCount = count }.buttonStyle(.borderedProminent).tint(questionCount == count ? .accentColor : .gray) }
                    Stepper("\(questionCount) 题", value: $questionCount, in: 1...100).font(.title3).padding(.leading, 12) }
            }.frame(maxWidth: 600)
            Button { practice = PracticeViewModel(mode: mode, questionCount: questionCount, selectedOperations: mixedOperations) } label: { Text("开始练习").font(.title2.bold()).frame(maxWidth: 600).padding() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(mode == .mixed && mixedOperations.count < 2)
            Spacer()
        }.padding()
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $practice) { PracticeFlowView(viewModel: $0).interactiveDismissDisabled() }
        .onAppear(perform: checkRepair)
        .onChange(of: scenePhase) { _, phase in if phase == .active { checkRepair() } }
        .alert("补上昨天，接回连续记录？", isPresented: Binding(
            get: { repairOffer != nil }, set: { if !$0 { repairOffer = nil } }), presenting: repairOffer) { offer in
            Button("补上昨天") { decideRepair(offer, accepted: true) }
            Button("放弃连续记录", role: .cancel) { decideRepair(offer, accepted: false) }
        } message: { offer in
            Text("你之前已经连续完成了 \(offer.previousStreak) 天！\n昨天还没完成。补昨天 \(questionCount) 题，加今天 \(questionCount) 题，共 \(questionCount * 2) 题，接着一次做完就能恢复连续记录。\n主动结束或过了今天，这次机会就结束。")
        }
        .alert("无法准备补学", isPresented: Binding(get: { repairError != nil }, set: { if !$0 { repairError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(repairError ?? "发生未知错误。") }
    }

    private func checkRepair() {
        let key = OneDayStreakRepair.dayKey(Date())
        guard practice == nil, key != checkedDayKey else { return }
        checkedDayKey = key
        repairOffer = store.repairOffer()
    }

    private func decideRepair(_ offer: OneDayStreakRepair.Offer, accepted: Bool) {
        do {
            try store.handleRepair(offer)
            if accepted {
                practice = PracticeViewModel(mode: mode, questionCount: questionCount * 2,
                    selectedOperations: mixedOperations, repairDayKey: offer.yesterdayKey)
            }
        } catch { repairError = error.localizedDescription }
    }

    private func toggle(_ operation: OperationType) {
        if mixedOperations.contains(operation) {
            mixedOperations.remove(operation)
        } else {
            mixedOperations.insert(operation)
        }
    }
}
