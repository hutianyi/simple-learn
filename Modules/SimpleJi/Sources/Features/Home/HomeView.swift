import CoreData
import SwiftUI
import StudyShell

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var settings: SettingsStore

    @FetchRequest private var dueStates: FetchedResults<ReviewStateEntity>
    @FetchRequest private var words: FetchedResults<WordEntity>
    @FetchRequest private var completionDays: FetchedResults<StudyCompletionDayEntity>
    @State private var dictationStatus: Result<DictationDay, Error>?
    private let calendar: Calendar
    private let now: Date

    init(settings: SettingsStore, calendar: Calendar = .current, now: Date = Date()) {
        self.settings = settings
        self.calendar = calendar
        self.now = now
        let start = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? now

        let dueRequest = ReviewStateEntity.fetchRequest()
        dueRequest.sortDescriptors = []
        dueRequest.predicate = NSPredicate(format: "nextReviewDate < %@", tomorrow as NSDate)
        _dueStates = FetchRequest(fetchRequest: dueRequest, animation: .default)
        let wordRequest = WordEntity.fetchRequest()
        wordRequest.sortDescriptors = [NSSortDescriptor(keyPath: \WordEntity.createdAt, ascending: true)]
        _words = FetchRequest(fetchRequest: wordRequest, animation: .default)
        let completionRequest = StudyCompletionDayEntity.fetchRequest()
        completionRequest.sortDescriptors = []
        completionRequest.predicate = NSPredicate(format: "dayKey == %@",
            DictationEligibility.dayKey(for: now, calendar: calendar))
        _completionDays = FetchRequest(fetchRequest: completionRequest)
    }

    var body: some View {
        let weekend = weekendStatus
        let complete = todayIsComplete
        ZStack {
            AppPalette.background.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 30)

                if !complete {
                    Text("今天的单词学习")
                        .font(StudyAppearance.title)
                        .foregroundStyle(AppPalette.textPrimary)
                }

                if FreeDayStore.isUsedToday(now: now) {
                    Text("免做卡 · 今天已打卡，以下学习可自愿进行。未完成内容留待之后学习。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = weekend.error {
                    Text("无法读取周末打卡记录：\(error)")
                        .font(.footnote).foregroundStyle(.red)
                }

                if complete {
                    completionCard
                } else if weekend.isComplete {
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
                    if !complete && !weekend.isComplete {
                        if !dueStates.isEmpty {
                            reviewButton.buttonStyle(LargePrimaryButtonStyle())
                        }

                        dictationEntry
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
                } else if !complete {
                    Text("词库共有 \(words.count) 个单词")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.textSecondary)
                }

                Spacer()

            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: refreshDictationStatus)
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)) { _ in
            refreshDictationStatus()
        }
    }

    private var weekendStatus: (isComplete: Bool, error: String?) {
        do { return (try StudyCompletionRepository.isWeekendComplete(in: context, now: now, calendar: calendar), nil) }
        catch { return (false, error.localizedDescription) }
    }

    private var todayIsComplete: Bool {
        guard dueStates.isEmpty, case .success(let day) = dictationStatus,
              day.items.allSatisfy({
                  StudyStreak.dictationFinished(phase: DictationPhase.complete.rawValue, items: [$0])
              }), let snapshot = completionDays.first else { return false }
        return (try? JSONDecoder().decode(StudyCompletionDay.self, from: snapshot.snapshotData))?.isComplete == true
    }

    private var completionCard: some View {
        StudyCompletionCard("今天的单词学习已完成")
            .accessibilityIdentifier("home.studyComplete")
    }

    private var dictationButton: some View {
        Button { router.push(.dictation) } label: {
            Label("开始默写", systemImage: "pencil.line")
        }
        .accessibilityIdentifier("home.startDictation")
    }

    private var reviewButton: some View {
        Button { router.push(.review) } label: {
            Label("开始复习卡片", systemImage: "play.fill")
        }
        .disabled(dueStates.isEmpty)
        .accessibilityIdentifier("home.startReview")
    }

    @ViewBuilder
    private var dictationEntry: some View {
        switch dictationStatus {
        case .success(let day):
            let pending = day.items.contains {
                !StudyStreak.dictationFinished(phase: DictationPhase.complete.rawValue, items: [$0])
            }
            if pending {
                if dueStates.isEmpty {
                    dictationButton.buttonStyle(LargePrimaryButtonStyle())
                } else {
                    dictationButton.buttonStyle(LargeSecondaryButtonStyle())
                }
            } else {
                Label(day.items.isEmpty ? "今天没有到期的默写词" : "今天的默写已完成",
                      systemImage: day.items.isEmpty ? "checkmark.circle" : "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(AppPalette.textSecondary)
                    .accessibilityIdentifier("home.dictationStatus")
            }
        case .failure(let error):
            Text("无法读取默写任务：\(error.localizedDescription)")
                .font(.footnote).foregroundStyle(.red)
            Button("重试读取默写任务", action: refreshDictationStatus)
                .buttonStyle(LargeSecondaryButtonStyle())
        case nil:
            ProgressView("正在读取默写任务")
        }
    }

    private func refreshDictationStatus() {
        dictationStatus = Result {
            try DictationRepository.previewDay(in: context, limit: settings.dictationLimit.rawValue,
                campaign: settings.baselineCampaign, masteredTerms: settings.masteredDictationTerms,
                now: now, calendar: calendar)
        }
    }
}
