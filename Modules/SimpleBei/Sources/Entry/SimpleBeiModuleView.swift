import SwiftUI
import StudyShell

public struct SimpleBeiModuleView: View {
    public init() {}
    public var body: some View { BeiLibraryView() }
}

private enum BeiPresentation: Identifiable {
    case editor(Passage?), settings, backup
    var id: String {
        switch self { case .editor(let passage): "editor.\(passage?.id.uuidString ?? "new")"; case .settings: "settings"; case .backup: "backup" }
    }
}

private struct BeiLibraryView: View {
    @State private var store = BeiLibraryStore()
    @State private var study = BeiStudySession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var voicePreview = BeiVoicePreview()
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var showArchived = false
    @State private var presentation: BeiPresentation?
    @State private var deleting: Passage?
    @EnvironmentObject private var session: ModuleSession

    private var selected: Passage? { store.library.passages.first { $0.id == selectedID } }
    private var visible: [Passage] {
        store.library.passages.filter { $0.archived == showArchived && (search.isEmpty || $0.title.localizedStandardContains(search) || $0.body.localizedStandardContains(search)) }
            .sorted { $0.editedAt > $1.editedAt }
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("课文状态", selection: $showArchived) { Text("我的课文").tag(false); Text("已归档").tag(true) }
                    .pickerStyle(.segmented).padding()
                List(selection: $selectedID) {
                    ForEach(visible) { passage in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(passage.title).font(.headline)
                            Text("\(passage.language.title) · \(passage.units.count) 句").font(.caption).foregroundStyle(.secondary)
                            if !study.hidesTestText {
                                Text(passage.preview).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6).tag(passage.id)
                            .contextMenu {
                                Button("编辑课文") { presentation = .editor(passage) }
                                Button(passage.archived ? "移回我的课文" : "归档") { Task { await store.archive(passage) } }
                                Button("删除课文", role: .destructive) { deleting = passage }
                            }
                    }
                }.disabled(study.active)
                    .overlay { if store.isReady && visible.isEmpty { ContentUnavailableView(search.isEmpty ? "还没有课文" : "没有匹配课文", systemImage: "text.book.closed") } }
            }
            .navigationTitle("我的课文")
            .searchable(text: $search, prompt: "搜索标题或正文")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("添加课文", systemImage: "plus") { presentation = .editor(nil) }
                        .disabled(!store.isReady || store.busy || study.active).accessibilityIdentifier("bei.add")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu("管理", systemImage: "ellipsis.circle") {
                        Button("播放与显示设置", systemImage: "gearshape") { presentation = .settings }
                        Button("课文备份", systemImage: "square.and.arrow.up") { presentation = .backup }
                    }.disabled(!store.isReady || store.busy || study.active)
                }
            }
        } detail: {
            NavigationStack {
                Group {
                    if let message = store.loadError {
                        ContentUnavailableView {
                            Label("课文库暂不可用", systemImage: "exclamationmark.triangle")
                        } description: { Text(message) } actions: {
                            Button("重新读取") { Task { await store.load() } }.disabled(store.busy)
                        }
                    } else if !store.isReady { ProgressView("正在读取课文库") }
                    else if let passage = selected {
                        BeiLessonView(passage: passage, store: store, study: study)
                            .toolbar {
                                Button("编辑课文") { presentation = .editor(passage) }.disabled(store.busy || study.active)
                                Menu("管理课文", systemImage: "ellipsis") {
                                    Button(passage.archived ? "取消归档" : "归档") { Task { await store.archive(passage) } }
                                    Button("删除 \(passage.title)", role: .destructive) { deleting = passage }
                                }.disabled(store.busy || study.active)
                            }
                    } else {
                        ContentUnavailableView("选择一篇课文", systemImage: "text.book.closed", description: Text("添加标题并粘贴正文，预览分句后保存。"))
                    }
                }
                .navigationTitle(selected?.title ?? "简单背")
            }
        }
        .disabled(store.busy && store.isReady)
        .sheet(item: $presentation) { destination in
            switch destination {
            case .editor(let passage): BeiEditorView(store: store, original: passage)
            case .settings: BeiSettingsView(store: store, probe: voicePreview)
            case .backup: BeiBackupView(store: store)
            }
        }
        .confirmationDialog("删除“\(deleting?.title ?? "")”？删除后可通过之前导出的备份恢复。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let passage = deleting { Button("删除这篇课文", role: .destructive) { Task { await store.delete(passage); deleting = nil } } }
            Button("取消", role: .cancel) { deleting = nil }
        }
        .alert("简单背", isPresented: Binding(get: { store.error != nil && presentation == nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task {
            await store.load()
            if store.isReady {
                let defaults = BeiVoiceResolver.fillingDefaults(store.library.preferences)
                if defaults != store.library.preferences { _ = await store.savePreferences(defaults) }
                if selectedID == nil { selectedID = visible.first?.id }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, value in study.sceneChanged(String(describing: value)) }
        .onChange(of: store.busy, initial: true) { _, value in session.setBusy(value, reason: "bei.storage") }
        .onChange(of: study.active, initial: true) { _, value in session.setBusy(value, reason: "bei.study") }
        .onChange(of: presentation?.id) { _, value in session.setBusy(value != nil, reason: "bei.management") }
        .onChange(of: store.library.passages) { _, passages in
            if !passages.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
        }
    }
}
