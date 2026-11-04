import SwiftUI
import UIKit
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
    var theme: StudyTheme {
        switch self { case .ji: .ji; case .lian: .lian; case .mo: .mo; case .suan: .suan; case .ting: .ting; case .bei: .bei }
    }
    var color: Color { theme.accent }
}

private struct HomeOverviewStatus {
    let text: String
    let isComplete: Bool
    var badge: String {
        if isComplete { return "已完成" }
        if text.hasPrefix("读取失败") { return "读取失败" }
        if text.hasPrefix("暂无") || text.hasPrefix("还没有") { return "暂无任务" }
        return "待完成"
    }
}

struct LearningHomeView: View {
    @ScaledMetric(relativeTo: .body) private var homeActionWidth: CGFloat = 148
    @ScaledMetric(relativeTo: .body) private var homeActionIconWidth: CGFloat = 22
    @State private var freeDayLedger: FreeDayLedger?
    @State private var freeDayConfirmation = false
    @State private var freeDayBusy = false
    @State private var freeDayMessage: String?
    @State private var overviewDayKey = ""
    @State private var selected: LearningModule?
    @StateObject private var session = ModuleSession()
    @State private var backupReady = false
    @State private var recoveryError: String?
    @State private var recoveryNotice: String?
    @State private var leaveError: String?
    @State private var presentation: HomePresentation?
    @AppStorage("SimpleXue.home.moduleOrder") private var savedModuleOrder = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isReordering = false
    @State private var suppressCardTap = false
    @State private var cardFrames: [LearningModule: CGRect] = [:]
    @State private var draggedModule: LearningModule?
    @State private var dragOrigin: CGRect = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var dragStartLocation: CGPoint = .zero
    @State private var overview: [LearningModule: HomeOverviewStatus] = [:]
    @State private var overviewReadCount = 0
    @State private var homeWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var overviewRevision = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private var orderedModules: [LearningModule] {
        var modules: [LearningModule] = []
        for id in savedModuleOrder.split(separator: ",") {
            if let module = LearningModule(rawValue: String(id)), !modules.contains(module) {
                modules.append(module)
            }
        }
        return modules + LearningModule.allCases.filter { !modules.contains($0) }
    }

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
                            Button {
                                do {
                                    try session.prepareToLeave?()
                                    AudioPlaybackCoordinator.shared.selectOwner(nil)
                                    self.selected = nil
                                } catch { leaveError = error.localizedDescription }
                            } label: { Label("切换功能", systemImage: "square.grid.2x2") }
                                .disabled(!session.canLeave)
                                .accessibilityIdentifier("shell.switch")
                            Spacer()
                            if !session.canLeave { Text(session.reasons.contains("ting.playback") ? "请先停止播放" : "请先结束本轮").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.bar)
                    Divider()
                    moduleView(selected).environment(\.studyTheme, selected.theme).tint(selected.color).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .id(selected)
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(alignment: .center, spacing: 24) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("简单学").font(StudyAppearance.title)
                                    Text("选一个，开始今天的学习。")
                                        .font(.title3).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 20) {
                                    Button { presentation = .backup } label: {
                                        homeActionLabel("备份与恢复", symbol: "externaldrive")
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(width: homeActionWidth)
                                    .accessibilityIdentifier("home.backup")
                                    .disabled(overviewReadCount > 0 || freeDayBusy)
                                    freeDayButton.frame(width: homeActionWidth)
                                }
                                .font(.body)
                            }
                            learningOverview
                            VStack(alignment: .leading, spacing: 12) {
                                Text("全部功能").font(StudyAppearance.sectionTitle)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                                    ForEach(orderedModules) { module in
                                        Button { openModule(module) } label: { moduleCard(module) }
                                        .buttonStyle(.plain).accessibilityIdentifier("module.\(module.rawValue)")
                                        .accessibilityAction { openModule(module, accessibility: true) }
                                        .accessibilityHint("长按并拖动可调整顺序，也可使用向前或向后移动操作")
                                        .accessibilityValue("第 \((orderedModules.firstIndex(of: module) ?? 0) + 1) 项，共 6 项")
                                        .accessibilityAction(named: "向前移动") { moveModule(module, by: -1) }
                                        .accessibilityAction(named: "向后移动") { moveModule(module, by: 1) }
                                        .opacity(draggedModule == module ? 0 : 1)
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(key: ModuleCardFramesKey.self,
                                                    value: [module: geometry.frame(in: .named("moduleGrid"))])
                                            }
                                        }
                                    }
                                }
                                .coordinateSpace(name: "moduleGrid")
                                .onPreferenceChange(ModuleCardFramesKey.self) { cardFrames = $0 }
                                .overlay(alignment: .topLeading) {
                                    if let draggedModule {
                                        moduleCard(draggedModule)
                                            .frame(width: dragOrigin.width, height: dragOrigin.height)
                                            .background(StudyAppearance.surface, in: RoundedRectangle(cornerRadius: StudyAppearance.moduleCornerRadius))
                                            .scaleEffect(reduceMotion ? 1 : 1.04)
                                            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                                            .position(x: dragOrigin.midX + dragTranslation.width,
                                                      y: dragOrigin.midY + dragTranslation.height)
                                            .allowsHitTesting(false)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .gesture(ModuleReorderGesture(onTouchBegan: { suppressCardTap = false },
                                                              onChanged: updateReordering, onEnded: finishReordering))
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { homeWidth = $0 }
                        .padding(StudyAppearance.pagePadding).frame(maxWidth: 1000).frame(maxWidth: .infinity)
                    }
                    .scrollDisabled(isReordering)
                    .background(StudyAppearance.background)
                }
            }
        }
        .environmentObject(session)
        .onChange(of: selected) { _, _ in finishReordering(); overviewRevision = UUID() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { overviewRevision = UUID() } }
        .task(id: overviewRevision) {
            guard backupReady, selected == nil, presentation == nil else { return }
            await refreshOverview()
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            if selected == nil, FreeDayLedger.dayKey(now) != overviewDayKey, !freeDayBusy {
                overviewRevision = UUID()
            }
        }
        .alert("确认使用本周的免做卡？", isPresented: $freeDayConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认使用") { Task { await useFreeDay() } }
        }
        .alert("免做卡", isPresented: Binding(get: { freeDayMessage != nil }, set: { if !$0 { freeDayMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(freeDayMessage ?? "") }
        .task { await prepareBackupRecovery() }
        .sheet(item: $presentation, onDismiss: { overviewRevision = UUID() }) { _ in
            WholeBackupView { pending in
                backupReady = !pending
                if pending { recoveryError = "上次整体恢复的回退尚未完成，请先重试回退。" }
                else { recoveryError = nil }
            }
        }
        .alert("数据恢复", isPresented: Binding(get: { recoveryNotice != nil }, set: { if !$0 { recoveryNotice = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(recoveryNotice ?? "") }
        .alert("进度保存失败，暂未退出", isPresented: Binding(get: { leaveError != nil }, set: { if !$0 { leaveError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(leaveError ?? "") }
    }

    private var softOpacity: Double { colorScheme == .dark ? 0.16 : 0.08 }

    private func moduleCard(_ module: LearningModule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: module.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(module.color)
                    .frame(width: 40, height: 40)
                    .background(module.color.opacity(softOpacity), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Text(module.title).font(StudyAppearance.moduleTitle).foregroundStyle(.primary)
            }
            Text(module.detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .frame(minHeight: 124, alignment: .leading)
        .background(StudyAppearance.surface, in: RoundedRectangle(cornerRadius: StudyAppearance.moduleCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: StudyAppearance.moduleCornerRadius)
            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: StudyAppearance.moduleCornerRadius))
    }

    private var learningOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今天的学习").font(StudyAppearance.sectionTitle)
            if [LearningModule.ji, .suan, .lian].allSatisfy({ overview[$0]?.isComplete == true }) {
                HStack(spacing: 16) {
                    Image(systemName: "party.popper.fill")
                        .font(.system(size: 38)).foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今天的学习全部完成！").font(StudyAppearance.moduleTitle)
                        Text("简单记、简单算、简单练都完成啦，真棒！")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .frame(minHeight: 112)
                .background(LinearGradient(colors: [.yellow.opacity(0.2), .green.opacity(0.15)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 18))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.overview.completed")
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                    count: homeWidth >= 600 && !dynamicTypeSize.isAccessibilitySize ? 3 : 1), spacing: 12) {
                    ForEach([LearningModule.ji, .suan, .lian]) { module in
                        overviewCard(module)
                    }
                }
            }
        }
    }

    private func homeActionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: homeActionIconWidth)
                .accessibilityHidden(true)
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    private var freeDayButton: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let available = freeDayLedger?.canUse(on: timeline.date) == true
            let alreadyComplete = overview[.ji]?.isComplete == true && overview[.suan]?.isComplete == true
            let enabled = available && !alreadyComplete && !freeDayBusy && overviewReadCount == 0 && overview.count == 3
            Button { freeDayConfirmation = true } label: {
                homeActionLabel("免做卡", symbol: "ticket.fill")
                    .foregroundStyle(enabled ? Color(red: 0.78, green: 0.55, blue: 0.08) : Color.secondary)
            }
            .buttonStyle(.bordered)
            .disabled(!enabled)
            .accessibilityValue(freeDayLedger?.isUsed(on: timeline.date) == true ? "今天已使用" : enabled ? "可使用" : "暂不可用")
            .accessibilityIdentifier("home.freeDay.use")
        }
    }

    @MainActor private func useFreeDay() async {
        guard !freeDayBusy, session.canLeave else { return }
        freeDayBusy = true
        defer { freeDayBusy = false }
        do {
            let now = Date()
            // Recheck after confirmation; the day or saved tasks may have changed.
            guard try FreeDayStore.live().load().canUse(on: now) else {
                throw WholeBackupError.message("本周免做卡已使用，或今天不是周一至周五。")
            }
            try await SimpleJiBackupTransfer.checkFreeDayEligibility(now: now)
            let ji = try await SimpleJiBackupTransfer.learningOverviewStatus(now: now)
            let suan = try SimpleSuanBackupTransfer.learningOverviewStatus(now: now)
            _ = try SimpleLianBackupTransfer.learningOverviewStatus(now: now)
            guard !(ji.isComplete && suan.isComplete) else {
                throw WholeBackupError.message("今天简单记和简单算均已完成，无需消耗免做卡。")
            }
            guard FreeDayLedger.dayKey(now) == FreeDayLedger.dayKey(Date()) else {
                throw WholeBackupError.message("日期已变化，请重新使用今天的免做卡。")
            }
            try FreeDayStore.live().use(now: Date())
            await refreshOverview()
            freeDayMessage = "已使用本周免做卡，今天已打卡。"
        } catch { freeDayMessage = error.localizedDescription }
    }

    private func overviewCard(_ module: LearningModule) -> some View {
        let status = overview[module]
        let complete = status?.isComplete == true
        let badge = status?.badge ?? "读取中"
        return Button { suppressCardTap = false; openModule(module) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        overviewHeading(module, complete: complete)
                        Spacer(minLength: 0)
                        Text(badge).font(.footnote).foregroundStyle(.secondary).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        overviewHeading(module, complete: complete)
                        Text(badge).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text(status?.text ?? "正在读取…")
                    .font(.subheadline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .frame(minHeight: 112, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 18).fill(StudyAppearance.surface)
                RoundedRectangle(cornerRadius: 18)
                    .fill((complete ? Color.gray : module.color).opacity(softOpacity))
            }
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(module.title)，\(status?.text ?? "正在读取")，\(badge)")
        .accessibilityIdentifier("home.overview.\(module.rawValue)")
    }

    private func overviewHeading(_ module: LearningModule, complete: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: complete ? "checkmark.circle.fill" : module.symbol)
                .foregroundStyle(complete ? Color.secondary : module.color)
                .accessibilityHidden(true)
            Text(module.title).foregroundStyle(.primary)
        }
        .font(.headline).fixedSize(horizontal: true, vertical: false)
    }

    @MainActor private func refreshOverview() async {
        overviewReadCount += 1
        defer { overviewReadCount -= 1 }
        overview = [:]
        let now = Date()
        overviewDayKey = FreeDayLedger.dayKey(now)
        do { freeDayLedger = try FreeDayStore.live().load() }
        catch { freeDayLedger = nil; freeDayMessage = "无法读取免做卡记录：\(error.localizedDescription)" }
        var updated: [LearningModule: HomeOverviewStatus] = [:]
        do {
            let status = try await SimpleJiBackupTransfer.learningOverviewStatus(now: now)
            guard !Task.isCancelled else { return }
            updated[.ji] = .init(text: status.text, isComplete: status.isComplete)
        }
        catch { if !Task.isCancelled { updated[.ji] = .init(text: "读取失败，点此查看", isComplete: false) } }
        guard !Task.isCancelled else { return }
        do {
            let status = try SimpleLianBackupTransfer.learningOverviewStatus(now: now)
            updated[.lian] = .init(text: status.text, isComplete: status.isComplete)
        } catch { updated[.lian] = .init(text: "读取失败，点此查看", isComplete: false) }
        do {
            let status = try SimpleSuanBackupTransfer.learningOverviewStatus(now: now)
            updated[.suan] = .init(text: status.text, isComplete: status.isComplete)
        } catch { updated[.suan] = .init(text: "读取失败，点此查看", isComplete: false) }
        guard !Task.isCancelled else { return }
        overview = updated
    }

    private func openModule(_ module: LearningModule, accessibility: Bool = false) {
        guard !freeDayBusy, !isReordering, draggedModule == nil, accessibility || !suppressCardTap else { return }
        AudioPlaybackCoordinator.shared.selectOwner(module.rawValue)
        selected = module
    }

    private func updateReordering(at location: CGPoint, began: Bool) {
        if began {
            guard let module = orderedModules.first(where: { cardFrames[$0]?.contains(location) == true }),
                  let frame = cardFrames[module] else { return }
            draggedModule = module
            dragOrigin = frame
            dragStartLocation = location
            isReordering = true
            suppressCardTap = true
        }
        guard let source = draggedModule else { return }
        dragTranslation = CGSize(width: location.x - dragStartLocation.x, height: location.y - dragStartLocation.y)
        guard let target = orderedModules.first(where: {
            $0 != source && cardFrames[$0]?.insetBy(dx: 12, dy: 12).contains(location) == true
        }), let from = orderedModules.firstIndex(of: source),
            let to = orderedModules.firstIndex(of: target) else { return }
        var modules = orderedModules
        modules.remove(at: from)
        modules.insert(source, at: to)
        saveOrder(modules)
    }

    private func moveModule(_ module: LearningModule, by offset: Int) {
        var modules = orderedModules
        guard let index = modules.firstIndex(of: module), modules.indices.contains(index + offset) else { return }
        modules.swapAt(index, index + offset)
        saveOrder(modules)
    }

    private func saveOrder(_ modules: [LearningModule]) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            savedModuleOrder = modules.map(\.rawValue).joined(separator: ",")
        }
    }

    private func finishReordering() {
        isReordering = false
        draggedModule = nil
        dragTranslation = .zero
    }

    @MainActor private func prepareBackupRecovery() async {
        recoveryError = nil
        do {
            let recovered = try await WholeBackupService.coordinator().recoverIfNeeded()
            backupReady = true
            overviewRevision = UUID()
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

private struct ModuleCardFramesKey: PreferenceKey {
    static var defaultValue: [LearningModule: CGRect] { [:] }
    static func reduce(value: inout [LearningModule: CGRect], nextValue: () -> [LearningModule: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ModuleReorderGesture: UIGestureRecognizerRepresentable {
    var onTouchBegan: () -> Void
    var onChanged: (CGPoint, Bool) -> Void
    var onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(onTouchBegan: onTouchBegan)
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.45
        // Cancel the card's button touch once a long press succeeds; short taps remain normal.
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.onTouchBegan = onTouchBegan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(context.converter.location(in: .named("moduleGrid")), recognizer.state == .began)
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTouchBegan: () -> Void
        init(onTouchBegan: @escaping () -> Void) { self.onTouchBegan = onTouchBegan }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            onTouchBegan()
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
