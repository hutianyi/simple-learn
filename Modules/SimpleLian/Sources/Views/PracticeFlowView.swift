import SwiftData
import SwiftUI

struct PracticeFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var session: PracticeSession
    @State private var errorMessage: String?

    private var initialAttempts: [Attempt] { session.attempts.filter { $0.context != .correction }.sorted { $0.orderIndex < $1.orderIndex } }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .answering: AnsweringView(session: session, attempts: initialAttempts)
                case .marking: MarkingView(session: session, attempts: initialAttempts)
                case .correction: CorrectionView(session: session)
                case .summary, .completed: SummaryView(session: session, finish: finish)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if session.phase != .summary && session.phase != .completed {
                    ToolbarItem(placement: .cancellationAction) { Button("稍后继续") { dismiss() } }
                }
            }
            .alert("操作失败", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
                Button("好") { errorMessage = nil }
            } message: { Text($0) }
        }
        .interactiveDismissDisabled(session.phase != .summary && session.phase != .completed)
    }

    private func finish() {
        do { try PracticeService.complete(session, context: context); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct AnsweringView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: PracticeSession
    let attempts: [Attempt]

    private var current: Attempt? { attempts.indices.contains(session.currentIndex) ? attempts[session.currentIndex] : nil }

    var body: some View {
        VStack(spacing: 0) {
            if let current, let question = current.question {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(current.group?.title ?? "练习").font(.headline).foregroundStyle(.secondary)
                        MarkdownView(text: question.promptMarkdown).font(.title2)
                        Divider().padding(.vertical, 8)
                        Label("请在纸上完成，做完后再统一核对答案。", systemImage: "pencil.and.list.clipboard")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity)
                }
                .onAppear { PracticeService.markPresented(current, context: context) }
            }
            HStack {
                Button("上一题") { session.currentIndex -= 1; save() }.disabled(session.currentIndex == 0)
                Spacer()
                Text("\(min(session.currentIndex + 1, attempts.count)) / \(attempts.count)").foregroundStyle(.secondary)
                Spacer()
                if session.currentIndex + 1 < attempts.count {
                    Button("下一题") { session.currentIndex += 1; save() }.buttonStyle(.borderedProminent)
                } else {
                    Button("开始核对") { session.phase = .marking; save() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(24).background(.bar)
        }
        .navigationTitle("做题")
    }
    private func save() { try? context.save() }
}

private struct MarkingView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: PracticeSession
    let attempts: [Attempt]
    @State private var confirms = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(attempts) { attempt in
                    MarkingCard(attempt: attempt) { try? context.save() }
                }
                Button("确认判定结果") { confirms = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(attempts.contains { $0.draftResult == nil })
                    .padding(.vertical, 20)
            }
            .frame(maxWidth: 850).padding(28).frame(maxWidth: .infinity)
        }
        .navigationTitle("核对答案")
        .confirmationDialog("确认后会更新复习安排", isPresented: $confirms, titleVisibility: .visible) {
            Button("确认并继续") { commit() }
        }
        .alert("无法确认", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in Button("好") { errorMessage = nil } } message: { Text($0) }
    }

    private func commit() {
        do { try PracticeService.commitMarking(session: session, context: context) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct MarkingCard: View {
    @Bindable var attempt: Attempt
    let save: () -> Void
    @State private var showsExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(attempt.group?.title ?? "题目").font(.headline).foregroundStyle(.secondary)
            if let question = attempt.question {
                MarkdownView(text: question.promptMarkdown)
                Divider()
                Text("参考答案").font(.caption.bold()).foregroundStyle(.secondary)
                MarkdownView(text: question.answerMarkdown)
                if !question.explanationMarkdown.isEmpty {
                    DisclosureGroup("查看解析", isExpanded: $showsExplanation) { MarkdownView(text: question.explanationMarkdown).padding(.top, 8) }
                }
            }
            HStack {
                ForEach(AttemptResult.allCases, id: \.self) { result in
                    Button {
                        attempt.draftResult = result
                        save()
                    } label: {
                        Label(result.label, systemImage: result == attempt.draftResult ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(tint(for: result))
                }
            }
        }
        .padding(20).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tint(for result: AttemptResult) -> Color {
        switch result {
        case .correct: .accentColor
        case .wrong: .orange
        case .excluded: .gray
        }
    }
}

private struct CorrectionView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: PracticeSession
    @State private var errorMessage: String?

    private var current: SessionGroupProgress? {
        session.groupProgress.first { ![.passed, .needsExplanation, .materialShortage].contains($0.stage) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let progress = current, let group = progress.group {
                    Text(group.title).font(.largeTitle.bold())
                    switch progress.stage {
                    case .pendingReview:
                        Text("先看懂刚才的错误").font(.title2.bold())
                        ForEach(wrongAttempts(for: group)) { attempt in
                            if let question = attempt.question {
                                VStack(alignment: .leading, spacing: 10) {
                                    MarkdownView(text: question.promptMarkdown)
                                    Divider()
                                    MarkdownView(text: question.answerMarkdown)
                                    if !question.explanationMarkdown.isEmpty { MarkdownView(text: question.explanationMarkdown).foregroundStyle(.secondary) }
                                }.padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        Button("我已订正，做一道同类题") { prepare(progress) }.buttonStyle(.borderedProminent).controlSize(.large)
                    case .pendingFollowup:
                        if let attempt = openCorrectionAttempt(for: group), let question = attempt.question {
                            Text("订正跟进题").font(.title2.bold())
                            MarkdownView(text: question.promptMarkdown).font(.title3)
                            Label("请先在纸上完成，再查看答案。", systemImage: "doc.text") .foregroundStyle(.secondary)
                            Button("查看答案") { progress.stage = .awaitingGrade; PracticeService.markPresented(attempt, context: context); save() }
                                .buttonStyle(.borderedProminent)
                        }
                    case .awaitingGrade:
                        if let attempt = openCorrectionAttempt(for: group), let question = attempt.question {
                            MarkdownView(text: question.promptMarkdown)
                            Divider()
                            Text("参考答案").font(.caption.bold()).foregroundStyle(.secondary)
                            MarkdownView(text: question.answerMarkdown)
                            if !question.explanationMarkdown.isEmpty { MarkdownView(text: question.explanationMarkdown).foregroundStyle(.secondary) }
                            HStack {
                                Button("做对了") { grade(.correct, progress) }.buttonStyle(.borderedProminent)
                                Button("做错了") { grade(.wrong, progress) }.buttonStyle(.bordered).tint(.orange)
                                Button("题目有问题") { grade(.excluded, progress) }.buttonStyle(.bordered).tint(.gray)
                            }
                        }
                    default: EmptyView()
                    }
                } else {
                    ProgressView().task { session.phase = .summary; save() }
                }
            }
            .frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity)
        }
        .navigationTitle("订正")
        .alert("订正遇到问题", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in Button("好") { errorMessage = nil } } message: { Text($0) }
    }

    private func wrongAttempts(for group: ProblemGroup) -> [Attempt] {
        session.attempts.filter { $0.group?.id == group.id && $0.result == .wrong }.sorted { $0.orderIndex < $1.orderIndex }
    }
    private func openCorrectionAttempt(for group: ProblemGroup) -> Attempt? {
        session.attempts.filter { $0.group?.id == group.id && $0.context == .correction && $0.result == nil }.max { $0.orderIndex < $1.orderIndex }
    }
    private func prepare(_ progress: SessionGroupProgress) {
        do { _ = try PracticeService.makeCorrectionAttempt(for: progress, context: context) }
        catch { errorMessage = error.localizedDescription }
    }
    private func grade(_ result: AttemptResult, _ progress: SessionGroupProgress) {
        do { try PracticeService.gradeCorrection(result, progress: progress, context: context) }
        catch { errorMessage = error.localizedDescription }
    }
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
}

private struct SummaryView: View {
    let session: PracticeSession
    let finish: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(.green)
            Text("这次练习完成了").font(.largeTitle.bold())
            let correct = session.attempts.filter { $0.result == .correct }.count
            let wrong = session.attempts.filter { $0.result == .wrong }.count
            Text("做对 \(correct) 道，做错 \(wrong) 道。后续题目会按掌握情况自动安排。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if session.groupProgress.contains(where: { $0.stage == .needsExplanation }) {
                Label("有题型连续订正三次未通过，已放到“需要讲解”。", systemImage: "person.wave.2.fill").foregroundStyle(.orange)
            }
            if session.groupProgress.contains(where: { $0.stage == .materialShortage }) {
                Label("有题型缺少可用近似题，请补充题库。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Button("完成", action: finish).buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: 640).padding(40).navigationTitle("完成")
    }
}
