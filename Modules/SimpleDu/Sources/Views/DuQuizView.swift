import SwiftUI
import StudyShell

struct DuQuizView: View {
    let store: DuStore
    let book: DuBook
    let readEvidence: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if book.progress.stage == .result { result }
                else { questionView }
            }.padding(28).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(StudyAppearance.background)
    }
    private var question: DuQuestion {
        book.article.questions.first { $0.id == book.progress.currentQuestionID } ??
        book.article.questions.first { book.progress.answers[$0.id] == nil } ?? book.article.questions.last!
    }
    private var questionIndex: Int { book.article.questions.firstIndex { $0.id == question.id } ?? 0 }
    private var submitted: Int? { book.progress.answers[question.id] }

    private var questionView: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("读一读，想一想").font(.title2.bold())
                Spacer(); Text("第 \(questionIndex + 1) / \(book.article.questions.count) 题").monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: Double(book.progress.answers.count), total: Double(book.article.questions.count)).tint(.teal)
            Text(question.prompt).font(.system(size: 28, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("du.question")
            VStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { option in
                    Button {
                        Task { await store.change(book.id) { try $0.select(option, question: question) } }
                    } label: {
                        HStack(alignment: .top, spacing: 16) {
                            Text(String(UnicodeScalar(65 + option)!)).font(.title3.bold())
                                .frame(width: 36, height: 36).background(optionColor(option).opacity(0.15), in: Circle())
                            Text(question.options[option]).font(.system(size: 24)).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: optionSymbol(option)).font(.title2)
                        }.padding(20).foregroundStyle(optionColor(option))
                            .background(StudyAppearance.surface, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(optionColor(option).opacity(isMarked(option) ? 0.9 : 0.15), lineWidth: isMarked(option) ? 2 : 1))
                    }.buttonStyle(.plain).disabled(submitted != nil)
                        .accessibilityIdentifier("du.option.\(option)")
                        .accessibilityAddTraits(book.progress.selections[question.id] == option ? .isSelected : [])
                }
            }
            if let submitted {
                VStack(alignment: .leading, spacing: 12) {
                    Label(submitted == question.answer ? "答对了！" : "再看看这道题", systemImage: submitted == question.answer ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title2.bold()).foregroundStyle(submitted == question.answer ? Color.green : Color.orange)
                        .accessibilityIdentifier("du.feedback")
                    if submitted != question.answer {
                        Text("正确答案：\(String(UnicodeScalar(65 + question.answer)!)) · \(question.options[question.answer])").font(.title3)
                    }
                    if !question.explanation.isEmpty { Text(question.explanation).font(.title3).foregroundStyle(.secondary) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudyAppearance.surface, in: RoundedRectangle(cornerRadius: 18))
                HStack(spacing: 20) {
                    Button("回文章看看", systemImage: "book") { readEvidence(question.evidence.first) }.buttonStyle(.bordered)
                    Spacer()
                    Button(questionIndex + 1 == book.article.questions.count ? "查看结果" : "下一题", systemImage: "arrow.right") {
                        Task {
                            await store.change(book.id) { progress in
                                if questionIndex + 1 < book.article.questions.count {
                                    progress.currentQuestionID = book.article.questions[questionIndex + 1].id
                                } else { progress.stage = .result }
                            }
                        }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("du.nextQuestion")
                }.font(.headline)
            } else {
                Text("先选答案，可以改选；确认后再看结果。").font(.subheadline).foregroundStyle(.secondary)
                Button("确认答案") {
                    Task { await store.change(book.id) { try $0.submit(question, article: book.article) } }
                }.buttonStyle(StudyPrimaryButtonStyle())
                    .disabled(book.progress.selections[question.id] == nil).accessibilityIdentifier("du.submit")
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label(book.progress.hasCompletedStudy ? "阅读完成！" : "答题完成！", systemImage: "checkmark.seal.fill").font(.largeTitle.bold()).foregroundStyle(.tint)
            Text(book.article.title).font(.title2)
            HStack(alignment: .firstTextBaseline) {
                Text("\(book.progress.score(book.progress.answers, article: book.article)) / \(book.article.questions.count)").font(.system(size: 48, weight: .bold, design: .rounded))
                Text("本次答对").font(.title3).foregroundStyle(.secondary)
            }.accessibilityIdentifier("du.result")
            if !book.progress.firstAnswers.isEmpty {
                Text("首次作答：答对 \(book.progress.score(book.progress.firstAnswers, article: book.article)) / \(book.article.questions.count) 题")
                    .foregroundStyle(.secondary)
            }
            ForEach(book.article.questions.filter { book.progress.answers[$0.id] != $0.answer }) { question in
                VStack(alignment: .leading, spacing: 12) {
                    Text(question.prompt).font(.title3.bold())
                    Text("正确答案：\(String(UnicodeScalar(65 + question.answer)!)) · \(question.options[question.answer])")
                    if !question.explanation.isEmpty { Text(question.explanation).foregroundStyle(.secondary) }
                    Button("回文章看看", systemImage: "book") { readEvidence(question.evidence.first) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudyAppearance.surface, in: RoundedRectangle(cornerRadius: 18))
            }
            if book.progress.attempts.count > 1 {
                DisclosureGroup("共完成 \(book.progress.attempts.count) 次练习") {
                    ForEach(book.progress.attempts.reversed(), id: \.run) { attempt in
                        HStack {
                            Text(attempt.finishedAt.formatted(date: .abbreviated, time: .shortened))
                            Spacer(); Text("\(book.progress.score(attempt.answers, article: book.article))/\(book.article.questions.count)")
                        }.padding(.vertical, 6)
                    }
                }
            }
            if book.isRead {
                Text("文章已标为已读，阅读和做题记录已保留。").font(.subheadline).foregroundStyle(.secondary)
            }
            if !book.isRead && book.progress.readingCompleted != true {
                Text("正文尚未读完，读完后会自动标为已读。").font(.subheadline).foregroundStyle(.secondary)
                Button("继续阅读文章", systemImage: "book") { readEvidence(nil) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("du.finishReading")
            }
            Button("返回文章列表", systemImage: "list.bullet") { dismiss() }
                .buttonStyle(StudyPrimaryButtonStyle()).accessibilityIdentifier("du.archiveResult")
            HStack {
                Button("再读一遍", systemImage: "book") { readEvidence(book.article.units.first?.paragraphs.first?.id) }
                Spacer()
                Button("重新答题", systemImage: "arrow.clockwise") {
                    Task { await store.change(book.id) { $0.restart(article: book.article) } }
                }.accessibilityIdentifier("du.retry")
            }.buttonStyle(.bordered).font(.headline)
        }
    }
    private func isMarked(_ index: Int) -> Bool {
        book.progress.selections[question.id] == index || (submitted != nil && question.answer == index)
    }
    private func optionColor(_ index: Int) -> Color {
        if let submitted {
            if index == question.answer { return .green }
            if index == submitted { return .red }
        }
        return isMarked(index) ? .teal : .primary
    }
    private func optionSymbol(_ index: Int) -> String {
        if submitted != nil && index == question.answer { return "checkmark.circle.fill" }
        if submitted == index && index != question.answer { return "xmark.circle.fill" }
        return book.progress.selections[question.id] == index ? "largecircle.fill.circle" : "circle"
    }
}
