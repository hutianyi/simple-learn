import SwiftData
import SwiftUI

struct LibraryView: View {
    @Query(sort: \ImportBatch.importedAt, order: .reverse) private var batches: [ImportBatch]
    @State private var showsImport = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(batches) { batch in
                    NavigationLink {
                        BatchDetailView(batch: batch)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(batch.title).font(.headline)
                            Text("\(batch.groups.count) 个题型 · \(batch.importedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if batches.isEmpty {
                    ContentUnavailableView("还没有题库", systemImage: "books.vertical", description: Text("导入一个 JSON 或 simplelian-json 代码块开始使用。"))
                }
            }
            .navigationTitle("题库")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("导入", systemImage: "square.and.arrow.down") { showsImport = true } } }
            .sheet(isPresented: $showsImport) { ImportView() }
        }
    }
}

private struct BatchDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let batch: ImportBatch
    @State private var confirmsDelete = false
    @State private var deleteError: String?

    var body: some View {
        List {
            if let note = batch.sourceNote, !note.isEmpty { Section("说明") { Text(note) } }
            Section("题型") {
                ForEach(batch.groups.sorted { $0.createdAt < $1.createdAt }) { group in
                    NavigationLink { GroupDetailView(group: group) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(group.title)
                                Text(group.reviewState?.status.label ?? "未知").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(group.questions.filter { $0.kind != .original && $0.disabledAt == nil }.count) 题").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("删除整个批次", role: .destructive) { confirmsDelete = true }
            }
        }
        .navigationTitle(batch.title)
        .confirmationDialog("删除这个批次及其题目？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deleteBatch)
        } message: { Text("此操作不能撤销。练习记录中引用这些题目的内容也会失去关联。") }
        .alert("删除失败", isPresented: .constant(deleteError != nil), presenting: deleteError) { _ in Button("好") { deleteError = nil } } message: { Text($0) }
    }

    private func deleteBatch() {
        do {
            try PracticeService.deleteBatch(batch, context: context)
            dismiss()
        } catch { deleteError = error.localizedDescription }
    }
}

struct GroupDetailView: View {
    @Environment(\.modelContext) private var context
    let group: ProblemGroup
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("学习状态") {
                if let state = group.reviewState {
                    LabeledContent("状态", value: state.status.label)
                    LabeledContent("已累计做对", value: "\(state.creditedCorrectCount) / 3")
                    if let day = state.nextReviewDay { LabeledContent("下次安排", value: day) }
                }
                Toggle("暂停这个题型", isOn: Binding(get: { group.isArchived }, set: { group.isArchived = $0; save() }))
                Button("重新开始学习") { restart() }
            }
            ForEach(QuestionKind.allCases, id: \.self) { kind in
                let questions = group.questions.filter { $0.kind == kind }.sorted { $0.createdAt < $1.createdAt }
                if !questions.isEmpty {
                    Section(kind.label) {
                        ForEach(questions) { question in
                            DisclosureGroup {
                                Text("答案").font(.caption.bold()).foregroundStyle(.secondary)
                                MarkdownView(text: question.answerMarkdown)
                                if !question.explanationMarkdown.isEmpty {
                                    Text("解析").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
                                    MarkdownView(text: question.explanationMarkdown)
                                }
                                Toggle("停用这道题", isOn: Binding(
                                    get: { question.disabledAt != nil },
                                    set: { disabled in question.disabledAt = disabled ? .now : nil; question.disabledReason = disabled ? "题库中手动停用" : nil; save() }
                                ))
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(question.promptMarkdown).lineLimit(2)
                                    if question.disabledAt != nil { Text("已停用").font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(group.title)
        .alert("保存失败", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in Button("好") { errorMessage = nil } } message: { Text($0) }
    }

    private func restart() {
        guard let state = group.reviewState else { return }
        state.apply(ReviewScheduler.apply(.restart(day: DayKey.make(from: .now)), to: state.snapshot))
        save()
    }
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
}

private extension ReviewStatus {
    var label: String {
        switch self {
        case .new: "待首次练习"
        case .scheduled: "复习中"
        case .pendingCorrection: "等待订正"
        case .needsExplanation: "需要讲解"
        case .mastered: "已掌握"
        }
    }
}

private extension QuestionKind {
    var label: String {
        switch self {
        case .original: "原错题"
        case .near: "近似题"
        case .transfer: "迁移题"
        }
    }
}
