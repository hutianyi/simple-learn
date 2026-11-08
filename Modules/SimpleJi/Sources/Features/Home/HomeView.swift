import CoreData
import SwiftUI
import StudyShell

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var settings: SettingsStore

    @FetchRequest private var dueStates: FetchedResults<ReviewStateEntity>
    @FetchRequest private var words: FetchedResults<WordEntity>
    @FetchRequest private var dictationStates: FetchedResults<DictationStateEntity>
    @FetchRequest private var dictationDays: FetchedResults<DictationDayEntity>
    @FetchRequest private var dictationEvents: FetchedResults<DictationEventEntity>
    @FetchRequest private var completionDays: FetchedResults<StudyCompletionDayEntity>
    private let calendar: Calendar
    private let now: Date
    private let today: String
    private let startOfToday: Date
    private let tomorrow: Date

    init(settings: SettingsStore, calendar: Calendar = .current, now: Date = Date()) {
        self.settings = settings
        self.calendar = calendar
        self.now = now
        let start = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        self.today = DictationEligibility.dayKey(for: now, calendar: calendar)
        self.startOfToday = start
        self.tomorrow = tomorrow

        let dueRequest = ReviewStateEntity.fetchRequest()
        dueRequest.sortDescriptors = []
        dueRequest.predicate = NSPredicate(format: "nextReviewDate < %@", tomorrow as NSDate)
        _dueStates = FetchRequest(fetchRequest: dueRequest, animation: .default)
        let wordRequest = WordEntity.fetchRequest()
        wordRequest.sortDescriptors = [NSSortDescriptor(keyPath: \WordEntity.createdAt, ascending: true)]
        _words = FetchRequest(fetchRequest: wordRequest, animation: .default)
        let stateRequest = DictationStateEntity.fetchRequest()
        stateRequest.sortDescriptors = []
        _dictationStates = FetchRequest(fetchRequest: stateRequest)
        let dayRequest = DictationDayEntity.fetchRequest()
        dayRequest.sortDescriptors = []
        _dictationDays = FetchRequest(fetchRequest: dayRequest)
        let eventRequest = DictationEventEntity.fetchRequest()
        eventRequest.sortDescriptors = []
        _dictationEvents = FetchRequest(fetchRequest: eventRequest)
        let completionRequest = StudyCompletionDayEntity.fetchRequest()
        completionRequest.sortDescriptors = []
        var visibleCompletionKeys = [today]
        if calendar.component(.weekday, from: now) == 1,
           let saturday = calendar.date(byAdding: .day, value: -1, to: start) {
            visibleCompletionKeys.append(DictationEligibility.dayKey(for: saturday, calendar: calendar))
        }
        completionRequest.predicate = NSPredicate(format: "dayKey IN %@", visibleCompletionKeys)
        _completionDays = FetchRequest(fetchRequest: completionRequest)
    }

    var body: some View {
        let weekend = weekendStatus
        ZStack {
            AppPalette.background.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 30)

                Text("今天的单词学习")
                    .font(StudyAppearance.title)
                    .foregroundStyle(AppPalette.textPrimary)

                if FreeDayStore.isUsedToday(now: now) {
                    Text("免做卡 · 今天已打卡，以下学习可自愿进行。未完成内容留待之后学习。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = weekend.error {
                    Text("无法读取周末打卡记录：\(error)")
                        .font(.footnote).foregroundStyle(.red)
                }

                if weekend.isComplete {
                    Label("周末已完成", systemImage: "checkmark.circle.fill")
                        .font(.title2.bold()).foregroundStyle(AppPalette.accent)
                } else {
                    VStack(spacing: 8) {
                        Text("今天待复习卡片")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(AppPalette.textSecondary)
                        Text("\(dueStates.count) 张")
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AppPalette.accent)
                    }
                    .accessibilityElement(children: .combine)
                }

                VStack(spacing: 14) {
                    if !weekend.isComplete {
                        if dueStates.isEmpty {
                            reviewButton.buttonStyle(LargeSecondaryButtonStyle())
                        } else {
                            reviewButton.buttonStyle(LargePrimaryButtonStyle())
                        }

                        if hasPendingDictation && dueStates.isEmpty {
                            dictationButton.buttonStyle(LargePrimaryButtonStyle())
                        } else {
                            dictationButton.buttonStyle(LargeSecondaryButtonStyle())
                        }
                    }

                    Button {
                        router.push(.addWords)
                    } label: {
                        Label(words.isEmpty ? "添加第一个单词" : "添加单词", systemImage: "plus")
                    }
                    .buttonStyle(LargeSecondaryButtonStyle())
                    .accessibilityIdentifier("home.addWords")
                }
                .frame(maxWidth: 440)

                if words.isEmpty {
                    Text("还没有单词，先添加一些单词开始学习。")
                        .font(.body)
                        .foregroundStyle(AppPalette.textSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("词库共有 \(words.count) 个单词")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.textSecondary)
                }

                Spacer()

                HStack(spacing: 30) {
                    utilityButton("词库", symbol: "books.vertical", route: .wordLibrary)
                    utilityButton("统计", symbol: "chart.bar.xaxis", route: .statistics)
                    utilityButton("设置", symbol: "gearshape", route: .settings)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var weekendStatus: (isComplete: Bool, error: String?) {
        do { return (try StudyCompletionRepository.isWeekendComplete(in: context, now: now, calendar: calendar), nil) }
        catch { return (false, error.localizedDescription) }
    }

    private var dictationButton: some View {
        Button { router.push(.dictation) } label: {
            Label("开始默写", systemImage: "pencil.line")
        }
        .disabled(words.isEmpty)
        .accessibilityIdentifier("home.startDictation")
    }

    private var reviewButton: some View {
        Button { router.push(.review) } label: {
            Label("开始复习卡片", systemImage: "play.fill")
        }
        .disabled(dueStates.isEmpty)
        .accessibilityIdentifier("home.startReview")
    }

    private var uninitializedLegacyWordsExist: Bool {
        guard settings.baselineCampaign == nil,
              !words.isEmpty else { return false }
        return words.contains {
            $0.createdAt < startOfToday && ($0.dictationState?.totalFormal ?? 0) == 0
                && !isMasteredForDictation($0)
        }
    }

    private var hasPendingDictation: Bool {
        if uninitializedLegacyWordsExist { return true }
        let existing = Set(words.filter { !isMasteredForDictation($0) }.map(\.id))
        let completed = Set(dictationEvents.filter { $0.kind == "baselineFormal" }.map(\.wordID))
        let hasPendingBaseline = settings.baselineCampaign?.selectedWordIDs.contains {
            existing.contains($0) && !completed.contains($0)
        } ?? false
        if let todayDay = dictationDays.first(where: { $0.dayKey == today }) {
            if todayDay.phase != DictationPhase.complete.rawValue { return true }
            let count = (try? JSONDecoder().decode([DictationItem].self,
                                                    from: todayDay.tasksData))?.count ?? 0
            let baselineLimit = settings.dictationLimit.rawValue == 0 ? 50 : min(50, settings.dictationLimit.rawValue)
            if count == 0 && hasNewDictationWords && !completedToday { return true }
            return hasPendingBaseline && count < baselineLimit
        }
        if hasPendingBaseline { return true }
        if hasNewDictationWords && !completedToday { return true }
        return dictationStates.contains {
            ($0.initialCopyCompletedAt != nil || $0.totalFormal > 0)
                && ($0.nextReviewDate.map { $0 < tomorrow } ?? false)
                && ($0.word.map { !isMasteredForDictation($0) } ?? false)
        }
    }

    private var completedToday: Bool {
        completionDays.first(where: { $0.dayKey == today }).flatMap {
            try? JSONDecoder().decode(StudyCompletionDay.self, from: $0.snapshotData)
        }?.isComplete == true
    }

    private var hasNewDictationWords: Bool {
        words.contains {
            !isMasteredForDictation($0)
                && DictationEligibility.canStartDirectly(word: $0, now: now, calendar: calendar)
        }
    }

    private func isMasteredForDictation(_ word: WordEntity) -> Bool {
        settings.masteredDictationTerms.contains(EnglishNormalizer.normalize(word.english))
    }

    private func utilityButton(_ title: String, symbol: String, route: AppRoute) -> some View {
        Button {
            router.push(route)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(minWidth: 64, minHeight: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.textSecondary)
    }
}
