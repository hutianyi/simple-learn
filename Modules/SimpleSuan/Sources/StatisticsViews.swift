import SwiftUI
import Charts

struct SessionResultView: View {
    let session: SessionRecord
    let saved: Bool
    let done: () -> Void
    @EnvironmentObject private var store: AppDataStore
    private var statistics: SessionStatistics { StatisticsCalculator.statistics(for: session.questions) }
    var body: some View {
        let activity = PracticeActivity(sessions: store.sessions)
        NavigationStack {
            ScrollView { VStack(spacing: 20) {
                if saved {
                    celebrationHeader(activity: activity)
                    PracticeHeatmapView(activity: activity)
                } else {
                    Text("本次练习完成").font(.largeTitle.bold())
                    Text("\(statistics.total) 题 · 等待保存").font(.title2).foregroundStyle(.secondary)
                }
                Text("本次练习成绩").font(.title2.bold())
                MetricsGrid(statistics: statistics)
                if session.practiceMode == .mixed { OperationBreakdown(session: session) }
                Button(saved ? "太棒了，继续加油！" : "重试保存") { done() }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(.top)
                    .accessibilityIdentifier("dismissSuanCelebration")
            }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity) }
            .toolbar {
                if saved {
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { done() } }
                }
            }
            .overlay {
                if saved {
                    PracticeCelebrationConfetti()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func celebrationHeader(activity: PracticeActivity) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 64)).foregroundStyle(Color.purple.gradient)
            Text("又完成一批口算，太棒了！")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("本次完成 \(statistics.total) 题 · 今天累计 \(activity.todayCount) 题")
                .font(.title2.weight(.semibold))
            Label("连续练习 \(activity.streak) 天", systemImage: "flame.fill")
                .font(.title3.bold()).foregroundStyle(.purple)
            Text(activity.streak > 1
                ? "每天坚持一点点，你的计算本领正在积累！"
                : "每一道题都是一次进步，今天的努力已经点亮！")
                .font(.title3).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.vertical, 20)
        .accessibilityIdentifier("suanPracticeCelebration")
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
                PracticeHeatmapView(activity: PracticeActivity(sessions: store.sessions))
            }
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

private struct PracticeHeatmapView: View {
    let activity: PracticeActivity
    @State private var selectedDate: Date?
    private let purple = Color(red: 0.48, green: 0.25, blue: 0.82)
    private var selection: Date { selectedDate ?? activity.today }

    var body: some View {
        let weeks = activity.weeks
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("每天进步一点点", systemImage: "sparkles").font(.title3.bold())
                    Text("近一年练习 \(activity.annualPracticeDays) 天 · 今天累计 \(activity.todayCount) 题")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(activity.streak) 天")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .monospacedDigit().foregroundStyle(purple)
                    Label("连续练习", systemImage: "flame.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }

            GeometryReader { geometry in
                let cell = min(14, max(7, (geometry.size.width - 48 - CGFloat(weeks.count - 1) * 3) / CGFloat(max(1, weeks.count))))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        VStack(spacing: 3) {
                            Color.clear.frame(height: 20)
                            ForEach(0..<7) { row in
                                Text(row == 0 ? "一" : row == 2 ? "三" : row == 4 ? "五" : "")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: 21, height: cell)
                            }
                        }
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(monthLabel(week))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .fixedSize().frame(width: cell, height: 20, alignment: .leading)
                                ForEach(week, id: \.self) { date in
                                    Button { selectedDate = date } label: {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(color(date: date))
                                            .overlay {
                                                if activity.calendar.isDate(date, inSameDayAs: selection) {
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .stroke(Color.primary.opacity(0.65), lineWidth: 1.5)
                                                }
                                            }
                                            .frame(width: cell, height: cell)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(date < activity.firstDay || date > activity.today)
                                    .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))，完成 \(activity.count(on: date)) 题")
                                }
                            }
                        }
                    }.padding(.trailing, 24)
                }.defaultScrollAnchor(.trailing)
            }.frame(height: 140)

            HStack {
                Text("\(selection.formatted(.dateTime.month().day())) · 完成 \(activity.count(on: selection)) 题")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("少")
                    ForEach([0, 10, 20, 40, 80], id: \.self) { count in
                        RoundedRectangle(cornerRadius: 3).fill(color(count: count))
                            .frame(width: 12, height: 12)
                    }
                    Text("多")
                }.font(.caption).accessibilityLabel("题数越多，紫色越深")
            }.foregroundStyle(.secondary)
            Text("按当天所有已完成批次的答题数累计，答错也计入；做得越多，紫色越深。点格子查看当天题数。")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("suanPracticeHeatmap")
    }

    private func color(date: Date) -> Color {
        guard date >= activity.firstDay && date <= activity.today else { return .clear }
        return color(count: activity.count(on: date))
    }

    private func color(count: Int) -> Color {
        count == 0 ? Color.secondary.opacity(0.10) : purple.opacity(PracticeActivity.intensity(for: count))
    }

    private func monthLabel(_ week: [Date]) -> String {
        if week.contains(activity.firstDay) { return "\(activity.calendar.component(.month, from: activity.firstDay))月" }
        guard let first = week.first(where: {
            $0 >= activity.firstDay && $0 <= activity.today && activity.calendar.component(.day, from: $0) == 1
        }) else { return "" }
        return "\(activity.calendar.component(.month, from: first))月"
    }
}

private struct PracticeCelebrationConfetti: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var running = true
    private let colors: [Color] = [.purple, .pink, .orange, .blue, .green]

    var body: some View {
        Group {
            if !reduceMotion && running {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    Canvas { context, size in
                        let elapsed = timeline.date.timeIntervalSince(start)
                        for index in 0..<70 {
                            let age = elapsed - Double(index % 7) * 0.04
                            guard age >= 0 && age < 3 else { continue }
                            let velocity = Double((index * 73) % 480) - 240
                            let x = size.width / 2 + velocity * age
                            let y = 80 - Double(140 + index % 100) * age + 210 * age * age
                            let rect = CGRect(x: x, y: y, width: index % 2 == 0 ? 7 : 5, height: 11)
                            var particle = context
                            particle.opacity = min(1, (3 - age) / 0.7)
                            particle.fill(Path(roundedRect: rect, cornerRadius: 2),
                                with: .color(colors[index % colors.count]))
                        }
                    }
                }
            }
        }
        .task {
            start = Date()
            do { try await Task.sleep(for: .seconds(3.3)) }
            catch { return }
            running = false
        }
    }
}

func seconds(_ value: Double) -> String { String(format: "%.1f秒", value) }
func totalTime(_ value: Double) -> String { let rounded = Int(value.rounded()); return rounded >= 60 ? "\(rounded / 60)分\(rounded % 60)秒" : "\(rounded)秒" }
