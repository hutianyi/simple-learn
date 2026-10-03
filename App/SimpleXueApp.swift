import SwiftUI
import StudyShell
import WordMemoryCards
import SimpleLian
import DictationApp
import SimpleSuan
import SimpleTing
import SimpleBei

@main
struct SimpleXueApp: App {
    var body: some Scene {
        WindowGroup {
            LearningHomeView().task {
                // Startup cleanup touches only SimpleBei's dedicated cache, without requesting permissions.
                do { try await SimpleBeiStartup.shared.prepare() }
                catch { print("[SimpleBei] 启动临时会话清理失败，试录前将重试：\(error.localizedDescription)") }
            }
        }
    }
}

enum LearningModule: String, CaseIterable, Identifiable {
    case ji, suan, ting, lian, bei, mo
    var id: String { rawValue }
    var title: String {
        switch self { case .ji: "简单记"; case .lian: "简单练"; case .mo: "简单默"; case .suan: "简单算"; case .ting: "简单听"; case .bei: "简单背" }
    }
    var symbol: String {
        switch self { case .ji: "rectangle.on.rectangle"; case .lian: "pencil.and.list.clipboard";
            case .mo: "speaker.wave.2"; case .suan: "plus.forwardslash.minus"; case .ting: "headphones"; case .bei: "text.book.closed" }
    }
    var detail: String {
        switch self { case .ji: "单词卡片与手写默写"; case .lian: "错题练习与订正";
            case .mo: "听语音，在纸上默写"; case .suan: "心算练习与统计"; case .ting: "英文文章连续朗读"; case .bei: "听读、练习与背诵检查" }
    }
    var color: Color {
        switch self { case .ji: .blue; case .lian: .orange; case .mo: .purple; case .suan: .green; case .ting: .teal; case .bei: .indigo }
    }
}

struct LearningHomeView: View {
    @State private var selected: LearningModule?
    @StateObject private var session = ModuleSession()
    @State private var backupReady = false
    @State private var recoveryError: String?
    @State private var recoveryNotice: String?
    @State private var presentation: HomePresentation?

    private enum HomePresentation: String, Identifiable {
        case backup
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if !backupReady {
                VStack(spacing: 20) {
                    if let recoveryError {
                        Text("整体恢复尚未完成").font(.title2.bold())
                        Text(recoveryError).foregroundStyle(.secondary)
                        Button("重试回退到恢复前数据") { Task { await prepareBackupRecovery() } }
                            .buttonStyle(.borderedProminent)
                    } else { ProgressView("正在检查数据恢复状态…") }
                }.padding(32)
            } else if let selected {
                VStack(spacing: 0) {
                    ZStack {
                        Text(selected.title).font(.headline)
                        HStack {
                            Button { AudioPlaybackCoordinator.shared.selectOwner(nil); self.selected = nil } label: { Label("切换功能", systemImage: "square.grid.2x2") }
                                .disabled(!session.canLeave)
                                .accessibilityIdentifier("shell.switch")
                            Spacer()
                            if !session.canLeave { Text(session.reasons.contains("ting.playback") ? "请先停止播放" : "请先结束本轮").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.bar)
                    Divider()
                    moduleView(selected).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .id(selected)
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("简单学").font(.system(size: 48, weight: .bold, design: .rounded))
                                    Spacer()
                                    Button("备份与恢复", systemImage: "externaldrive") { presentation = .backup }
                                        .buttonStyle(.bordered).accessibilityIdentifier("home.backup")
                                }
                                Text("选一个，开始今天的学习。") .font(.title3).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 20)], spacing: 20) {
                                ForEach(LearningModule.allCases) { module in
                                    Button { AudioPlaybackCoordinator.shared.selectOwner(module.rawValue); selected = module } label: {
                                        VStack(alignment: .leading, spacing: 16) {
                                            Image(systemName: module.symbol).font(.system(size: 38)).foregroundStyle(module.color)
                                            Text(module.title).font(.title.bold()).foregroundStyle(.primary)
                                            Text(module.detail).font(.headline).foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading).padding(24)
                                        .background(module.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
                                    }
                                    .buttonStyle(.plain).accessibilityIdentifier("module.\(module.rawValue)")
                                }
                            }
                        }
                        .padding(32).frame(maxWidth: 1000).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .environmentObject(session)
        .task { await prepareBackupRecovery() }
        .sheet(item: $presentation) { _ in
            WholeBackupView { pending in
                backupReady = !pending
                if pending { recoveryError = "上次整体恢复的回退尚未完成，请先重试回退。" }
                else { recoveryError = nil }
            }
        }
        .alert("数据恢复", isPresented: Binding(get: { recoveryNotice != nil }, set: { if !$0 { recoveryNotice = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(recoveryNotice ?? "") }
    }

    @MainActor private func prepareBackupRecovery() async {
        recoveryError = nil
        do {
            let recovered = try await WholeBackupService.coordinator().recoverIfNeeded()
            backupReady = true
            if recovered { recoveryNotice = "上次整体恢复未完成，已自动回退到恢复前数据。" }
        } catch { backupReady = false; recoveryError = error.localizedDescription }
    }

    @ViewBuilder private func moduleView(_ module: LearningModule) -> some View {
        switch module {
        case .ji: SimpleJiModuleView()
        case .lian: SimpleLianModuleView()
        case .mo: SimpleMoModuleView()
        case .suan: SimpleSuanModuleView()
        case .ting: SimpleTingModuleView()
        case .bei: SimpleBeiModuleView()
        }
    }
}
