import SwiftUI

struct PracticeFlowView: View {
    @ObservedObject var viewModel: PracticeViewModel
    @EnvironmentObject private var store: AppDataStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false
    @State private var saved = false
    @State private var saveError: String?
    var body: some View {
        Group {
            if let session = viewModel.completedSession {
                SessionResultView(session: session, saved: saved) { if saved { dismiss() } else { save(session) } }
                    .onAppear { if !saved { save(session) } }
            } else {
                PracticeView(viewModel: viewModel, confirmEnd: $confirmEnd)
            }
        }
        .alert("结束本次练习？", isPresented: $confirmEnd) {
            Button("继续练习", role: .cancel) {}
            Button("结束练习", role: .destructive) { viewModel.stop(); dismiss() }
        } message: { Text("未完成的练习不会计入历史统计。") }
        .alert("无法保存练习", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("重试保存") { if let session = viewModel.completedSession { save(session) } }
        } message: { Text(saveError ?? "请保留当前页面。") }
        .onDisappear { viewModel.stop() }
    }
    private func save(_ session: SessionRecord) {
        do { try store.add(session); saved = true; saveError = nil }
        catch { saveError = error.localizedDescription }
    }
}

struct PracticeView: View {
    @ObservedObject var viewModel: PracticeViewModel
    @Binding var confirmEnd: Bool
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 18) {
            Text("第 \(viewModel.questionNumber) / \(viewModel.questions.count) 题").font(.title2.weight(.semibold))
            Text(String(format: "%.1f 秒", viewModel.elapsed)).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Text(viewModel.currentQuestion.expression).font(.system(size: 70, weight: .medium, design: .rounded)).minimumScaleFactor(0.5)
            Text(viewModel.answer.isEmpty ? " " : viewModel.answer).font(.system(size: 54, weight: .bold, design: .rounded)).frame(minHeight: 70)
                .accessibilityLabel("已输入答案 \(viewModel.answer)")
            feedbackView.frame(minHeight: 62)
            Spacer()
            NumberPadView(answer: viewModel.answer, locked: viewModel.isInputLocked, append: viewModel.append, delete: viewModel.delete, submit: viewModel.submit)
                .frame(maxWidth: 560)
        }.padding(28)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("结束") { confirmEnd = true } } }
        .onChange(of: scenePhase, initial: true) { _, phase in viewModel.scenePhaseChanged(isActive: phase == .active) }
    }
    @ViewBuilder private var feedbackView: some View {
        if let feedback = viewModel.feedback {
            switch feedback {
            case .correct: Label("正确", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(.green)
            case .incorrect(let answer): VStack(spacing: 4) { Label("错误", systemImage: "xmark.circle.fill").font(.title2.bold()).foregroundStyle(.red); Text("正确答案：\(answer)").font(.title3) }
            }
        }
    }
}

struct NumberPadView: View {
    let answer: String; let locked: Bool; let append: (Int) -> Void; let delete: () -> Void; let submit: () -> Void
    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["⌫", "0", "✓"]]
    var body: some View {
        VStack(spacing: 10) { ForEach(rows, id: \.self) { row in HStack(spacing: 10) { ForEach(row, id: \.self) { key in button(for: key) } } } }
    }
    @ViewBuilder private func button(for key: String) -> some View {
        Button { if let number = Int(key) { append(number) } else if key == "⌫" { delete() } else { submit() } } label: { Text(key).font(.system(size: 32, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 68) }
            .buttonStyle(.borderedProminent).tint(key == "✓" ? .accentColor : .gray).disabled(locked || (key == "✓" && answer.isEmpty))
            .accessibilityLabel(key == "⌫" ? "删除" : key == "✓" ? "确认答案" : key)
    }
}
