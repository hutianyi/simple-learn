import Charts
import CoreData
import SwiftUI
import StudyShell

struct StatisticsView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var persistence: PersistenceController
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    private let celebration: Bool
    @State private var completionError: String?
    @FetchRequest private var completionDays: FetchedResults<StudyCompletionDayEntity>
    @FetchRequest private var words: FetchedResults<WordEntity>
    @FetchRequest private var states: FetchedResults<ReviewStateEntity>
    @FetchRequest private var events: FetchedResults<ReviewEventEntity>
    @FetchRequest private var sessions: FetchedResults<StudySessionEntity>
    @FetchRequest private var dictationDays: FetchedResults<DictationDayEntity>
    @FetchRequest private var dictationEvents: FetchedResults<DictationEventEntity>

    private let calendar = Calendar.current

    init(settings: SettingsStore, celebration: Bool = false) {
        self.celebration = celebration
        self.settings = settings
        let completionRequest = StudyCompletionDayEntity.fetchRequest()
        completionRequest.sortDescriptors = [NSSortDescriptor(key: "dayKey", ascending: false)]
        _completionDays = FetchRequest(fetchRequest: completionRequest)
        let wordRequest = WordEntity.fetchRequest()
        wordRequest.sortDescriptors = [NSSortDescriptor(keyPath: \WordEntity.createdAt, ascending: true)]
        _words = FetchRequest(fetchRequest: wordRequest)
        let stateRequest = ReviewStateEntity.fetchRequest()
        stateRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ReviewStateEntity.nextReviewDate, ascending: true)]
        _states = FetchRequest(fetchRequest: stateRequest)
        let eventRequest = ReviewEventEntity.fetchRequest()
        eventRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ReviewEventEntity.reviewedAt, ascending: false)]
        _events = FetchRequest(fetchRequest: eventRequest)
        let sessionRequest = StudySessionEntity.fetchRequest()
        sessionRequest.sortDescriptors = [NSSortDescriptor(keyPath: \StudySessionEntity.startedAt, ascending: false)]
        _sessions = FetchRequest(fetchRequest: sessionRequest)
        let dayRequest = DictationDayEntity.fetchRequest()
        dayRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        _dictationDays = FetchRequest(fetchRequest: dayRequest)
        let dictationEventRequest = DictationEventEntity.fetchRequest()
        dictationEventRequest.sortDescriptors = []
        _dictationEvents = FetchRequest(fetchRequest: dictationEventRequest)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if celebration { celebrationHeader }
                completionHeatmap

                if celebration {
                    Button("太棒了，明天继续！") { dismiss() }
                        .buttonStyle(LargePrimaryButtonStyle())
                        .accessibilityIdentifier("dismissDailyCelebration")
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                        spacing: 14
                    ) {
                        metric("总单词", value: words.count, symbol: "books.vertical")
                        metric("今日待复习卡", value: dueCount, symbol: "calendar.badge.clock")
                        metric("已熟练单词", value: masteredWordCount, symbol: "star.fill")
                        metric("今日已正式复习", value: todayFormalEvents.count, symbol: "checkmark.circle")
                        metric("今日首答正确率", value: todayAccuracyText, symbol: "percent")
                        metric("今日默写首次正确率", value: todayDictationAccuracyText, symbol: "pencil")
                        metric("旧词摸底首次正确", value: baselineAccuracyText, symbol: "list.clipboard")
                        metric("累计正式复习次数", value: formalEvents.count, symbol: "arrow.triangle.2.circlepath")
                        metric("累计不认识次数", value: formalUnknownCount, symbol: "xmark.circle")
                    }

                    if trend.count >= 2 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("最近正式复习正确率")
                                .font(.title3.bold())
                            Chart(trend) { point in
                                BarMark(
                                    x: .value("复习", point.index),
                                    y: .value("正确率", point.accuracy)
                                )
                                .foregroundStyle(AppPalette.accent.gradient)
                                .cornerRadius(5)
                            }
                            .chartYScale(domain: 0...100)
                            .chartYAxis {
                                AxisMarks(values: [0, 50, 100]) { value in
                                    AxisGridLine()
                                    AxisValueLabel {
                                        if let number = value.as(Int.self) {
                                            Text("\(number)%")
                                        }
                                    }
                                }
                            }
                            .frame(height: 210)
                        }
                        .padding(20)
                        .background(AppPalette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("容易忘记的卡片")
                                .font(.title3.bold())
                            Spacer()
                            Button("额外加练") { router.push(.extraPractice) }
                                .font(.headline)
                        }

                        if weakStates.isEmpty {
                            Text("正式复习中还没有答错过的卡片。")
                                .foregroundStyle(AppPalette.textSecondary)
                        } else {
                            ForEach(weakStates, id: \.objectID) { state in
                                if let word = state.word {
                                    NavigationLink {
                                        WordDetailView(word: word)
                                    } label: {
                                        HStack(spacing: 14) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(word.english)
                                                    .font(.headline)
                                                    .foregroundStyle(AppPalette.textPrimary)
                                                Text(directionTitle(state.direction))
                                                    .font(.subheadline)
                                                    .foregroundStyle(AppPalette.textSecondary)
                                            }
                                            Spacer()
                                            Text(state.nextReviewDate.formatted(date: .abbreviated, time: .omitted))
                                                .font(.subheadline.monospacedDigit())
                                                .foregroundStyle(AppPalette.textSecondary)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.bold())
                                                .foregroundStyle(AppPalette.textSecondary)
                                        }
                                        .padding(.vertical, 8)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                    .background(AppPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding(22)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .task(id: "\(events.count)|\(dictationEvents.count)|\(states.count)|\(settings.dictationLimit.rawValue)|\(settings.masteredDictationTerms.count)") {
            do {
                try await StudyCompletionRepository(container: persistence.container).refresh(
                    scope: StudyCompletionScope(
                        baselineWordIDs: settings.baselineCampaign.map { Set($0.selectedWordIDs) },
                        masteredTerms: settings.masteredDictationTerms))
                completionError = nil
            } catch { completionError = "无法核对当天完成情况：\(error.localizedDescription)" }
        }
        .background(AppPalette.background.ignoresSafeArea())
        .overlay {
            if celebration { StudyCelebrationConfetti().allowsHitTesting(false).accessibilityHidden(true) }
        }
        .navigationTitle(celebration ? "今日任务全部完成" : "学习统计")
        .celebrationSound(enabled: celebration, owner: "ji")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if celebration {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var celebrationHeader: some View {
        VStack(spacing: 14) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.purple.gradient)
            Text("今天的你，太棒了！")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            Text("卡片复习、默写和错词订正都完成了。\n今天的格子已经点亮，看看你坚持的足迹！")
                .font(.title3)
                .foregroundStyle(AppPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .accessibilityIdentifier("dailyCompletionCelebration")
    }

    private func metric(_ title: String, value: Int, symbol: String) -> some View {
        metric(title, value: "\(value)", symbol: symbol)
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(AppPalette.accent)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(AppPalette.textPrimary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AppPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(18)
        .background(AppPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var dueCount: Int {
        let today = calendar.startOfDay(for: Date())
        return states.filter { calendar.startOfDay(for: $0.nextReviewDate) <= today }.count
    }

    private var todayDictationAccuracyText: String {
        let key = DictationEligibility.dayKey(for: Date())
        guard let day = dictationDays.first(where: { $0.dayKey == key }),
              let items = try? JSONDecoder().decode([DictationItem].self, from: day.tasksData) else {
            return "暂无"
        }
        let answered = items.filter { $0.formalResult != nil }.count
        guard answered > 0 else { return "暂无" }
        let correct = items.filter { $0.formalResult == true }.count
        return "\(Int((Double(correct) / Double(answered) * 100).rounded()))%"
    }

    private var baselineAccuracyText: String {
        let firstResults = dictationEvents.filter { $0.kind == "baselineFormal" }
        guard !firstResults.isEmpty else { return "暂无" }
        let correct = firstResults.filter { $0.result == "correct" }.count
        return "\(correct) / \(firstResults.count)"
    }

    private var masteredWordCount: Int {
        let threshold = calendar.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        return words.filter { word in
            let reviewStates = word.reviewStates
            return reviewStates.count == ReviewDirection.allCases.count
                && reviewStates.allSatisfy {
                    $0.totalReviews > 0 && $0.nextReviewDate >= threshold
                }
        }.count
    }

    private var formalEvents: [ReviewEventEntity] {
        events.filter {
            $0.practiceMode == PracticeMode.scheduled.rawValue && !$0.isSameSessionRetry
        }
    }

    private var todayFormalEvents: [ReviewEventEntity] {
        formalEvents.filter { calendar.isDateInToday($0.reviewedAt) }
    }

    private var formalUnknownCount: Int {
        formalEvents.filter { $0.result == ReviewResult.unknown.rawValue }.count
    }

    private var todayAccuracyText: String {
        guard !todayFormalEvents.isEmpty else { return "—" }
        let known = todayFormalEvents.filter { $0.result == ReviewResult.known.rawValue }.count
        return "\(Int((Double(known) / Double(todayFormalEvents.count) * 100).rounded()))%"
    }

    private var completionHeatmap: some View {
        let history = completionHistory
        let activityKeys = Set(events.map { DictationEligibility.dayKey(for: $0.reviewedAt, calendar: calendar) })
            .union(dictationEvents.filter { $0.result == "correct" || $0.result == "incorrect" }
                .map { DictationEligibility.dayKey(for: $0.submittedAt, calendar: calendar) })
        return StudyHeatmapView(completedKeys: history.keys, activityKeys: activityKeys,
            streak: history.streak, error: completionError ?? history.error, calendar: calendar)
    }

    private var completionHistory: (keys: Set<String>, streak: Int, error: String?) {
        do {
            let records = try completionDays.map {
                try JSONDecoder().decode(StudyCompletionDay.self, from: $0.snapshotData)
            }
            let cutoff = records.map(\.dayKey).min() ?? DictationEligibility.dayKey(for: Date(), calendar: calendar)
            let scheduled = Dictionary(grouping: sessions.filter { $0.mode == PracticeMode.scheduled.rawValue }) {
                DictationEligibility.dayKey(for: $0.startedAt, calendar: calendar)
            }
            var historicalKeys = Set<String>()
            for day in dictationDays where day.dayKey < cutoff {
                let dayCalendar = DictationEligibility.calendar(timeZone: TimeZone(identifier: day.timeZoneID) ?? calendar.timeZone)
                let items = try JSONDecoder().decode([DictationItem].self, from: day.tasksData)
                let retests = Dictionary(grouping: dictationEvents.filter {
                    $0.dayID == day.id && $0.kind == "retest" && $0.result == "correct"
                }, by: \.wordID).mapValues { $0.map(\.submittedAt) }
                let cardSessions = (scheduled[day.dayKey] ?? []).map {
                    StudyStreak.HistoricalSession(startedAt: $0.startedAt, finishedAt: $0.finishedAt,
                        completed: $0.completed, required: Int($0.baseTaskCount), answered: Int($0.formalAnswered))
                }
                if StudyStreak.historicalCardsFinished(sessions: cardSessions, calendar: dayCalendar)
                    && StudyStreak.historicalDictationFinished(dayKey: day.dayKey, phase: day.phase,
                        items: items, successfulRetests: retests, calendar: dayCalendar) {
                    historicalKeys.insert(day.dayKey)
                }
            }
            return (StudyStreak.completionKeys(completedDays: records, historicalKeys: historicalKeys, calendar: calendar),
                StudyStreak.count(completedDays: records, calendar: calendar, historicalKeys: historicalKeys), nil)
        } catch { return ([], 0, "无法读取完成记录：\(error.localizedDescription)") }
    }

    private var weakStates: [ReviewStateEntity] {
        states
            .filter { $0.unknownCount > 0 && $0.word != nil }
            .sorted { weakness($0) > weakness($1) }
            .prefix(10)
            .map { $0 }
    }

    private func weakness(_ state: ReviewStateEntity) -> Double {
        let attempts = state.knownCount + state.unknownCount
        guard attempts > 0 else { return WeaknessScorer.unseenScore }
        var score = (Double(state.unknownCount) + 0.5) / (Double(attempts) + 1)
        if state.lastResult == ReviewResult.unknown.rawValue { score += 0.35 }
        score -= Double(min(max(state.consecutiveKnown, 0), 5)) * 0.06
        return score
    }

    private var trend: [TrendPoint] {
        let recent = sessions
            .filter {
                $0.mode == PracticeMode.scheduled.rawValue && $0.formalAnswered > 0
            }
            .prefix(12)
            .reversed()
        return recent.enumerated().map { offset, session in
            TrendPoint(
                index: offset + 1,
                accuracy: Double(session.formalKnown) / Double(session.formalAnswered) * 100
            )
        }
    }

    private func directionTitle(_ rawValue: String) -> String {
        ReviewDirection(rawValue: rawValue)?.displayName ?? rawValue
    }
}

private struct TrendPoint: Identifiable {
    let index: Int
    let accuracy: Double
    var id: Int { index }
}

private struct StudyHeatmapView: View {
    let completedKeys: Set<String>
    let activityKeys: Set<String>
    let streak: Int
    let error: String?
    let calendar: Calendar
    @State private var selectedDate = Date()

    private let purple = Color(red: 0.48, green: 0.25, blue: 0.82)
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var firstDay: Date { calendar.date(byAdding: .day, value: -364, to: today) ?? today }
    private var weeks: [[Date]] { StudyStreak.heatmapWeeks(now: today, calendar: calendar) }
    private var annualCompletions: Int {
        let firstKey = key(firstDay)
        let lastKey = key(today)
        return completedKeys.filter { $0 >= firstKey && $0 <= lastKey }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("每天进步一点点", systemImage: "sparkles")
                        .font(.title3.bold())
                    Text("近一年完成 \(annualCompletions) 天 · 每一个格子都是你的努力")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.textSecondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(error == nil ? "\(streak) 天" : "—")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(purple)
                    Label("连续完成", systemImage: "flame.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.textSecondary)
                }
            }

            GeometryReader { geometry in
                let cell = max(7, (geometry.size.width - 48 - CGFloat(weeks.count - 1) * 3) / CGFloat(weeks.count))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        VStack(spacing: 3) {
                            Color.clear.frame(height: 20)
                            ForEach(0..<7) { row in
                                Text(row == 0 ? "一" : row == 2 ? "三" : row == 4 ? "五" : "")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppPalette.textSecondary)
                                    .frame(width: 21, height: cell)
                            }
                        }
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(monthLabel(week))
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppPalette.textSecondary)
                                    .fixedSize()
                                    .frame(width: cell, height: 20, alignment: .leading)
                                ForEach(week, id: \.self) { date in
                                    Button { selectedDate = date } label: {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(color(date))
                                            .overlay {
                                                if calendar.isDate(date, inSameDayAs: selectedDate) {
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .stroke(AppPalette.textPrimary.opacity(0.65), lineWidth: 1.5)
                                                }
                                            }
                                            .frame(width: cell, height: cell)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(date < firstDay || date > today)
                                    .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))，\(status(date))")
                                }
                            }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .defaultScrollAnchor(.trailing)
            }
            .frame(height: 150)

            HStack(spacing: 14) {
                Text("\(selectedDate.formatted(.dateTime.month().day())) · \(status(selectedDate))")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                legend("暂无记录", color: AppPalette.textSecondary.opacity(0.10))
                legend("有学习", color: purple.opacity(0.25))
                legend("全部完成", color: purple)
            }
            .foregroundStyle(AppPalette.textSecondary)

            Text(error ?? "卡片复习、默写和错词抄写与重默全部完成，点亮深紫色。旧版按当天已完成的复习会话和默写订正记录认定。")
                .font(.footnote)
                .foregroundStyle(error == nil ? AppPalette.textSecondary : .red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .background(AppPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func key(_ date: Date) -> String {
        DictationEligibility.dayKey(for: date, calendar: calendar)
    }

    private func status(_ date: Date) -> String {
        if completedKeys.contains(key(date)) { return "全部完成" }
        return activityKeys.contains(key(date)) ? "有学习记录" : "暂无学习记录"
    }

    private func color(_ date: Date) -> Color {
        guard date >= firstDay && date <= today else { return .clear }
        if completedKeys.contains(key(date)) { return purple }
        return activityKeys.contains(key(date)) ? purple.opacity(0.25) : AppPalette.textSecondary.opacity(0.10)
    }

    private func monthLabel(_ week: [Date]) -> String {
        if week.contains(firstDay) { return "\(calendar.component(.month, from: firstDay))月" }
        guard let first = week.first(where: { $0 >= firstDay && $0 <= today && calendar.component(.day, from: $0) == 1 }) else { return "" }
        return "\(calendar.component(.month, from: first))月"
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(title).font(.caption)
        }
    }
}

private struct StudyCelebrationConfetti: View {
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
