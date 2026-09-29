import CoreData
import SwiftUI

struct WordDetailView: View {
    @ObservedObject var word: WordEntity
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var english: String
    @State private var chinese: String
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    init(word: WordEntity) {
        self.word = word
        _english = State(initialValue: word.english)
        _chinese = State(initialValue: word.chinese)
    }

    var body: some View {
        Form {
            Section {
                TextField("英文", text: $english)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("中文", text: $chinese)
            } header: {
                Text("词条")
            } footer: {
                Text("修改中文保留学习进度；实质修改英文后，需要重新建立默写资格与抄写进度。已排除默写的词仍保持排除。")
            }

            Section {
                Toggle("不再参加默写", isOn: dictationExcludedBinding)
                    .accessibilityIdentifier("wordDetail.excludeDictation")
            } header: {
                Text("默写设置")
            } footer: {
                Text("立即保存。开启后，此词不再参加摸底、抄写和正式默写；卡片复习与已有记录保留。关闭后恢复参加默写。")
            }

            ForEach(sortedStates, id: \.objectID) { state in
                Section(directionTitle(state.direction)) {
                    LabeledContent("下次复习", value: state.nextReviewDate.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("正式认识", value: "\(state.knownCount)")
                    LabeledContent("正式不认识", value: "\(state.unknownCount)")
                    LabeledContent("最近 5 次", value: recentResults(for: state))
                }
            }

            if let dictation = word.dictationState {
                Section("默写") {
                    if dictation.totalFormal > 0 && dictation.initialCopyCompletedAt == nil {
                        LabeledContent("入门方式", value: "旧词摸底")
                    } else {
                        LabeledContent("首次抄写", value: "\(dictation.initialCopyCount) / 3")
                    }
                    LabeledContent("正式默写次数", value: "\(dictation.totalFormal)")
                    if !isExcludedFromDictation, let due = dictation.nextReviewDate {
                        LabeledContent("下次默写", value: due.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }

            Section {
                Button("保存修改") { save() }
                Button("删除这个单词", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(word.english)
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除 \(word.english)？", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) { deleteWord() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会同时删除两个方向的复习状态、默写进度及该词的全部历史学习记录。此操作不可撤销。")
        }
        .alert("无法保存", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("已保存", isPresented: savedBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(savedMessage ?? "")
        }
    }

    private var isExcludedFromDictation: Bool {
        settings.masteredDictationTerms.contains(EnglishNormalizer.normalize(word.english))
    }

    private var dictationExcludedBinding: Binding<Bool> {
        Binding(
            get: { isExcludedFromDictation },
            set: { excluded in
                let term = EnglishNormalizer.normalize(word.english)
                if excluded {
                    settings.masteredDictationTerms.insert(term)
                } else {
                    settings.masteredDictationTerms.remove(term)
                }
            }
        )
    }

    private var sortedStates: [ReviewStateEntity] {
        word.reviewStates.sorted { $0.direction < $1.direction }
    }

    private func directionTitle(_ rawValue: String) -> String {
        ReviewDirection(rawValue: rawValue)?.displayName ?? rawValue
    }

    private func recentResults(for state: ReviewStateEntity) -> String {
        let symbols = state.events
            .filter {
                $0.practiceMode == PracticeMode.scheduled.rawValue
                    && !$0.isSameSessionRetry
            }
            .sorted { $0.reviewedAt > $1.reviewedAt }
            .prefix(5)
            .map { $0.result == ReviewResult.known.rawValue ? "✓" : "✕" }
        return (symbols + Array(repeating: "·", count: max(0, 5 - symbols.count)))
            .joined(separator: "  ")
    }

    private func save() {
        let trimmedEnglish = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChinese = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = EnglishNormalizer.normalize(trimmedEnglish)

        guard !normalized.isEmpty,
              VocabularyParser.isValid(english: trimmedEnglish, chinese: trimmedChinese) else {
            errorMessage = "请输入有效的英文和中文释义。"
            return
        }

        let request = WordEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(
            format: "normalizedEnglish == %@ AND self != %@",
            normalized,
            word
        )

        do {
            if try context.count(for: request) > 0 {
                errorMessage = "这个英文已经存在，不能保存重复词条。"
                return
            }
            let previousTerm = word.normalizedEnglish
            let wasExcluded = isExcludedFromDictation
            let resetsDictation = normalized != previousTerm
            if resetsDictation {
                try DictationRepository.reconcileTasks(
                    for: word.id, preservingHistory: true, in: context
                )
                if let state = word.dictationState { context.delete(state) }
            }
            word.english = trimmedEnglish
            word.normalizedEnglish = normalized
            word.chinese = trimmedChinese
            word.updatedAt = Date()
            try context.save()
            if resetsDictation && wasExcluded {
                var terms = settings.masteredDictationTerms
                terms.remove(previousTerm)
                terms.insert(normalized)
                settings.masteredDictationTerms = terms
            }
            if resetsDictation {
                savedMessage = wasExcluded
                    ? "词条已更新。原卡片进度保留，此词仍排除默写。"
                    : "词条已更新。原卡片进度保留；此词的默写资格和抄写进度需重新建立。"
            } else {
                savedMessage = "词条已更新，学习记录保持不变。"
            }
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func deleteWord() {
        do {
            try DictationRepository.reconcileTasks(
                for: word.id, preservingHistory: false, in: context
            )
            context.delete(word)
            try context.save()
            dismiss()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var savedBinding: Binding<Bool> {
        Binding(
            get: { savedMessage != nil },
            set: { if !$0 { savedMessage = nil } }
        )
    }
}
