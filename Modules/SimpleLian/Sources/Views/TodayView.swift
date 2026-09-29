import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query private var groups: [ProblemGroup]
    @Query(sort: \PracticeSession.createdAt, order: .reverse) private var sessions: [PracticeSession]
    @State private var presentedSession: PracticeSession?
    @State private var errorMessage: String?

    private var active: PracticeSession? { sessions.first { $0.completedAt == nil } }
    private var due: [ProblemGroup] {
        let day = DayKey.make(from: .now)
        return groups.filter {
            guard !$0.isArchived, let state = $0.reviewState else { return false }
            return state.status == .new || (state.status == .scheduled && (state.nextReviewDay ?? day) <= day)
        }
    }
    private var needsExplanation: [ProblemGroup] { groups.filter { !$0.isArchived && $0.reviewState?.status == .needsExplanation } }
    private var pendingCorrection: [ProblemGroup] { groups.filter { !$0.isArchived && $0.reviewState?.status == .pendingCorrection } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(greeting).font(.largeTitle.bold())
                        Text(statusText).foregroundStyle(.secondary)
                    }

                    Button(action: beginOrResume) {
                        Label(active == nil ? "开始今天的练习" : "继续未完成练习", systemImage: active == nil ? "play.fill" : "arrow.forward.circle.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(active == nil && due.isEmpty)

                    if !needsExplanation.isEmpty {
                        StatusSection(title: "需要讲解", icon: "person.wave.2", groups: needsExplanation) { startCorrection($0) }
                    }
                    if !pendingCorrection.isEmpty && active == nil {
                        StatusSection(title: "等待订正", icon: "arrow.trianglehead.2.clockwise.rotate.90", groups: pendingCorrection) { startCorrection($0) }
                    }
                    if groups.isEmpty {
                        ContentUnavailableView("还没有题目", systemImage: "tray", description: Text("到“题库”页导入 ChatGPT 生成的题库。"))
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("简单练")
            .fullScreenCover(item: $presentedSession) { PracticeFlowView(session: $0) }
            .alert("无法开始", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
                Button("好") { errorMessage = nil }
            } message: { Text($0) }
        }
    }

    private var greeting: String { due.isEmpty && active == nil ? "今天已完成" : "今天练一点" }
    private var statusText: String {
        if active != nil { return "有一组练习还没有完成。" }
        if due.isEmpty { return "目前没有到期题目，不需要额外练习。" }
        return "系统已选好 \(due.count) 个题型，每个题型 1 道。"
    }

    private func beginOrResume() {
        do {
            if let active { presentedSession = active }
            else { presentedSession = try PracticeService.makeDailySession(context: context) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func startCorrection(_ group: ProblemGroup) {
        do { presentedSession = try PracticeService.makeCorrectionSession(for: group, context: context) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct StatusSection: View {
    let title: String
    let icon: String
    let groups: [ProblemGroup]
    let action: (ProblemGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            ForEach(groups) { group in
                HStack {
                    Text(group.title)
                    Spacer()
                    Button("继续") { action(group) }.buttonStyle(.bordered)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
