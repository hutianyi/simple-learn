import CoreData
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @ObservedObject var settings: SettingsStore

    @FetchRequest private var dueStates: FetchedResults<ReviewStateEntity>
    @FetchRequest private var words: FetchedResults<WordEntity>
    @FetchRequest private var dictationStates: FetchedResults<DictationStateEntity>
    @FetchRequest private var dictationDays: FetchedResults<DictationDayEntity>
    @FetchRequest private var dictationEvents: FetchedResults<DictationEventEntity>
    private let today: String
    private let startOfToday: Date
    private let tomorrow: Date

    init(settings: SettingsStore, calendar: Calendar = .current, now: Date = Date()) {
        self.settings = settings
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
    }

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 30)

                Text("简单记")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(AppPalette.textPrimary)

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

                VStack(spacing: 14) {
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
            return hasPendingBaseline && count < max(50, Int(todayDay.limit))
        }
        if hasPendingBaseline { return true }
        return dictationStates.contains {
            ($0.initialCopyCompletedAt != nil || $0.totalFormal > 0)
                && ($0.nextReviewDate.map { $0 < tomorrow } ?? false)
                && ($0.word.map { !isMasteredForDictation($0) } ?? false)
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
