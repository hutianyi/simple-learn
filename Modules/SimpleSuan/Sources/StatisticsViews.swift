import SwiftUI
import Charts

struct SessionResultView: View {
    let session: SessionRecord
    let done: () -> Void
    private var statistics: SessionStatistics { StatisticsCalculator.statistics(for: session.questions) }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(spacing: 20) {
                Text("本次练习完成").font(.largeTitle.bold())
                Text("\(statistics.total) 题").font(.title2).foregroundStyle(.secondary)
                MetricsGrid(statistics: statistics)
                if session.practiceMode == .mixed { OperationBreakdown(session: session) }
                Button("完成") { done() }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top)
            }.padding() }
        }
    }
}

struct MetricsGrid: View {
    let statistics: SessionStatistics
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            Metric("正确", "\(statistics.correct)"); Metric("错误", "\(statistics.incorrect)")
            Metric("正确率", String(format: "%.0f%%", statistics.accuracy * 100)); Metric("总用时", totalTime(statistics.totalDuration))
            Metric("平均用时", seconds(statistics.averageDuration)); Metric("最快", seconds(statistics.fastest)); Metric("最慢", seconds(statistics.slowest))
        }.frame(maxWidth: 620)
    }
}
struct Metric: View { let label: String; let value: String; init(_ label: String, _ value: String) { self.label = label; self.value = value }; var body: some View { VStack(spacing: 6) { Text(value).font(.title2.bold()); Text(label).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) } }

struct OperationBreakdown: View {
    let session: SessionRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("各题型表现").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow { Text("题型").bold(); Text("题数").bold(); Text("正确率").bold(); Text("平均时间").bold() }
                ForEach(OperationType.allCases) { operation in
                    if let stats = StatisticsCalculator.statistics(for: session, operation: operation) {
                        GridRow { Text(operation.title); Text("\(stats.total)"); Text(String(format: "%.0f%%", stats.accuracy * 100)); Text(seconds(stats.averageDuration)) }
                    }
                }
            }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }.frame(maxWidth: 620, alignment: .leading)
    }
}

struct StatisticsView: View {
    @EnvironmentObject private var store: AppDataStore
    @State private var selected: PracticeMode = .mixed
    @State private var showAllHistory = false
    @State private var sessionPendingDeletion: SessionRecord?
    @State private var deletionError: String?
    private var operation: OperationType? { selected.operation }
    private var points: [TrendPoint] { StatisticsCalculator.trend(sessions: store.sessions, operation: operation) }
    private var historySessions: [SessionRecord] {
        store.sessions.filter { session in
            operation == nil || session.questions.contains { $0.operationType == operation }
        }
    }
    private var visibleHistorySessions: [SessionRecord] {
        showAllHistory ? historySessions : Array(historySessions.prefix(10))
    }
    private var total: SessionStatistics? {
        let questions = store.sessions.flatMap(\.questions).filter { operation == nil || $0.operationType == operation }
        return questions.isEmpty ? nil : StatisticsCalculator.statistics(for: questions)
    }

    var body: some View {
        List {
            Section {
                Picker("筛选题型", selection: $selected) {
                    ForEach(PracticeMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            if let total {
                Section("累计数据") { MetricsGrid(statistics: total) }
                Section {
                    TrendCharts(points: points)
                }
                Section("历史练习") {
                    ForEach(visibleHistorySessions) { session in
                        NavigationLink { SessionDetailView(session: session) } label: {
                            SessionRow(session: session, operation: operation)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { sessionPendingDeletion = session } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    if historySessions.count > 10 {
                        Button(showAllHistory ? "收起历史记录" : "更多历史记录") { showAllHistory.toggle() }
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 42)).foregroundStyle(.secondary)
                        Text("还没有练习记录").font(.title2.bold())
                        Text("完成第一次练习后，这里会显示正确率和速度趋势。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 360)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("统计")
        .onChange(of: selected) { _, _ in showAllHistory = false }
        .alert("删除这次练习记录？", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { sessionPendingDeletion = nil }
            Button("删除", role: .destructive) { deletePendingSession() }
        } message: {
            Text("删除后无法恢复；累计统计、趋势和历史列表会立即按剩余记录重新计算。")
        }
        .alert("未能删除记录", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("好", role: .cancel) { deletionError = nil }
        } message: { Text(deletionError ?? "") }
    }

    private func deletePendingSession() {
        guard let session = sessionPendingDeletion else { return }
        do {
            try store.delete(session)
            sessionPendingDeletion = nil
        } catch {
            sessionPendingDeletion = nil
            deletionError = "练习记录未被删除，请稍后重试。"
        }
    }
}

struct TrendCharts: View {
    let points: [TrendPoint]
    var body: some View {
        Group {
            Text("正确率趋势").font(.title2.bold())
            Chart(points) { point in LineMark(x: .value("日期", point.session.completedAt), y: .value("正确率", point.statistics.accuracy * 100)).foregroundStyle(.blue); PointMark(x: .value("日期", point.session.completedAt), y: .value("正确率", point.statistics.accuracy * 100)) }.chartYScale(domain: 0...100).frame(height: 180)
            Text("平均用时趋势").font(.title2.bold())
            Chart(points) { point in LineMark(x: .value("日期", point.session.completedAt), y: .value("秒", point.statistics.averageDuration)).foregroundStyle(.orange); PointMark(x: .value("日期", point.session.completedAt), y: .value("秒", point.statistics.averageDuration)) }.frame(height: 180)
        }
    }
}

struct SessionRow: View {
    let session: SessionRecord; let operation: OperationType?
    var body: some View { if let stats = StatisticsCalculator.statistics(for: session, operation: operation) { HStack { VStack(alignment: .leading, spacing: 4) { Text(session.completedAt.formatted(date: .abbreviated, time: .shortened)); Text("\(session.practiceTitle) · \(stats.total)题").font(.headline); Text(String(format: "正确率 %.0f%% · 平均 %@", stats.accuracy * 100, seconds(stats.averageDuration))).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) } }
}

struct SessionDetailView: View {
    let session: SessionRecord
    var body: some View {
        List {
            Section { MetricsGrid(statistics: StatisticsCalculator.statistics(for: session.questions)) }
            ForEach(session.questions) { question in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(question.sequenceNumber). \(question.expression)").font(.headline)
                    Text("你的答案：\(question.userAnswer)    正确答案：\(question.correctAnswer)")
                    Label(question.isCorrect ? "正确" : "错误", systemImage: question.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(question.isCorrect ? .green : .red)
                    Text(seconds(question.durationSeconds)).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            }
        }.navigationTitle("练习详情")
    }
}

func seconds(_ value: Double) -> String { String(format: "%.1f秒", value) }
func totalTime(_ value: Double) -> String { let rounded = Int(value.rounded()); return rounded >= 60 ? "\(rounded / 60)分\(rounded % 60)秒" : "\(rounded)秒" }
