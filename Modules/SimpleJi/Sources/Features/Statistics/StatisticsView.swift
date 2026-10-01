import Charts
import CoreData
import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject private var router: AppRouter
    @FetchRequest private var words: FetchedResults<WordEntity>
    @FetchRequest private var states: FetchedResults<ReviewStateEntity>
    @FetchRequest private var events: FetchedResults<ReviewEventEntity>
    @FetchRequest private var sessions: FetchedResults<StudySessionEntity>
    @FetchRequest private var dictationDays: FetchedResults<DictationDayEntity>
    @FetchRequest private var dictationEvents: FetchedResults<DictationEventEntity>

    private let calendar = Calendar.current

    init() {
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
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 14)],
                    spacing: 14
                ) {
                    metric("总单词", value: words.count, symbol: "books.vertical")
                    metric("今日待复习卡", value: dueCount, symbol: "calendar.badge.clock")
                    metric("已熟练单词", value: masteredWordCount, symbol: "star.fill")
                    metric("今日已正式复习", value: todayFormalEvents.count, symbol: "checkmark.circle")
                    metric("今日首答正确率", value: todayAccuracyText, symbol: "percent")
                    metric("今日默写首次正确率", value: todayDictationAccuracyText, symbol: "pencil")
                    metric("旧词摸底首次正确", value: baselineAccuracyText, symbol: "list.clipboard")
                    metric("连续学习天数", value: "\(studyStreak) 天", symbol: "flame.fill")
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
            .padding(22)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(AppPalette.background.ignoresSafeArea())
        .navigationTitle("学习统计")
        .navigationBarTitleDisplayMode(.inline)
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

    private var studyStreak: Int {
        let studiedDays = Set(
            events
                .filter { !$0.isSameSessionRetry }
                .map { calendar.startOfDay(for: $0.reviewedAt) }
        )
        var cursor = calendar.startOfDay(for: Date())
        var count = 0
        while studiedDays.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
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
