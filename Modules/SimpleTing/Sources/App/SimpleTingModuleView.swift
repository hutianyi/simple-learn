import SwiftUI
import StudyShell

public struct SimpleTingModuleView: View {
    public init() {}
    public var body: some View { ListenLibraryView() }
}

private enum ListenPresentation: Identifiable {
    case settings, pasteImport
    var id: String { switch self { case .settings: "settings"; case .pasteImport: "import" } }
}

private struct ListenLibraryView: View {
    @State private var store: LibraryStore
    @State private var settings: ListenSettings
    @State private var speech: SpeechService
    @State private var selectedDayID: UUID?
    @State private var displayedArticleID: UUID?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var presentation: ListenPresentation?
    @State private var dayToDelete: ListenDay?
    @State private var error: String?
    @EnvironmentObject private var session: ModuleSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = LibraryStore()
        let settings = ListenSettings()
        let speech = SpeechService(settings: settings, library: store.library)
        _store = State(initialValue: store); _settings = State(initialValue: settings); _speech = State(initialValue: speech)
        _selectedDayID = State(initialValue: speech.playback.day?.id ?? store.library.newestFirst.first?.id)
        _displayedArticleID = State(initialValue: speech.playback.selectedArticleID)
    }

    private var selectedDay: ListenDay? { store.library.days.first { $0.id == selectedDayID } }
    private var displayedArticle: ListenArticle? { displayedArticleID.flatMap { store.library.article($0) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("简单听").font(.title2.bold())
                Spacer()
                Button("导入文章", systemImage: "plus") { presentation = .pasteImport }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.loadError != nil || speech.playback.state == .stopping)
                    .accessibilityIdentifier("listen.import")
                Button("设置", systemImage: "gearshape") { presentation = .settings }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("listen.settings")
            }
            .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            Divider()
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                List {
                    if let loadError = store.loadError { Text(loadError).foregroundStyle(.red) }
                    if store.library.days.isEmpty { Text("还没有文章。点击上方“导入文章”，粘贴 Markdown 全文。").foregroundStyle(.secondary) }
                    ForEach(store.library.newestFirst) { day in
                        Button {
                            selectedDayID = day.id; displayedArticleID = nil; compactColumn = .detail
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) { Text(day.title).font(.headline).lineLimit(2); Text("第 \(day.importSequence) 次导入 · \(day.articles.count) 篇文章").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if selectedDayID == day.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }.foregroundStyle(.primary)
                        }
                        .swipeActions { Button("删除", role: .destructive) { requestDelete(day) } }
                        .contextMenu { Button("删除这份材料", role: .destructive) { requestDelete(day) } }
                    }
                }
                .navigationTitle("文章库")
            } detail: {
                NavigationStack {
                    Group {
                        if let article = displayedArticle {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 28) {
                                    Text(article.title).font(.largeTitle.bold())
                                    MarkdownBodyView(markdown: article.rawMarkdown)
                                }.padding(28).frame(maxWidth: 900).frame(maxWidth: .infinity)
                            }
                            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("文章列表", systemImage: "chevron.left") { displayedArticleID = nil } } }
                        } else if let day = selectedDay {
                            List(day.articles.sorted { $0.articleNumber < $1.articleNumber }) { article in
                                Button { openAndPlay(article.id) } label: {
                                    HStack(spacing: 16) {
                                        Text("\(article.articleNumber)").font(.title2).foregroundStyle(.secondary)
                                        Text(article.title).font(.title3).frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "play.circle").font(.title2)
                                    }.padding(.vertical, 12)
                                }.disabled(speech.playback.state == .stopping)
                            }
                        } else { ContentUnavailableView("还没有文章", systemImage: "headphones", description: Text("点击上方“导入文章”，粘贴一份 Markdown 全文。")) }
                    }
                    .navigationTitle(selectedDay?.title ?? "简单听")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerView(speech: speech) { showCurrent() } }
        .sheet(item: $presentation) { modal in
            switch modal {
            case .settings: ListenSettingsView(speech: speech, settings: settings)
            case .pasteImport:
                ListenPasteImportView(store: store, speech: speech) { id in
                    selectedDayID = id; displayedArticleID = nil; compactColumn = .detail
                }
            }
        }
        .confirmationDialog("删除这份材料及其中全部文章？", isPresented: Binding(get: { dayToDelete != nil }, set: { if !$0 { dayToDelete = nil } }), titleVisibility: .visible) {
            if let day = dayToDelete { Button("删除 \(day.title)", role: .destructive) { delete(day) } }
            Button("取消", role: .cancel) { dayToDelete = nil }
        }
        .alert("简单听", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
        .onChange(of: speech.playback.hasSession, initial: true) { _, busy in session.setBusy(busy, reason: "ting.playback") }
        .onChange(of: speech.playback.selectedArticleID) { previous, current in
            if displayedArticleID == previous { displayedArticleID = current; selectedDayID = speech.playback.day?.id }
        }
        .onChange(of: store.library) { _, _ in
            if !store.library.days.contains(where: { $0.id == selectedDayID }) {
                selectedDayID = store.library.newestFirst.first?.id; displayedArticleID = nil
            }
        }
        .onChange(of: scenePhase) { _, value in if value == .active { speech.returnedToForeground() } }
        .onDisappear { speech.stop(); session.setBusy(false, reason: "ting.playback"); session.setBusy(false, reason: "ting.import") }
    }
    private func openAndPlay(_ id: UUID) { displayedArticleID = id; speech.play(id); compactColumn = .detail }
    private func showCurrent() { displayedArticleID = speech.playback.selectedArticleID; selectedDayID = speech.playback.day?.id; compactColumn = .detail }
    private func requestDelete(_ day: ListenDay) {
        guard !speech.playback.hasSession else { error = "请先停止本次播放和定时，再删除材料。"; return }
        dayToDelete = day
    }
    private func delete(_ day: ListenDay) {
        session.setBusy(true, reason: "ting.import")
        defer { session.setBusy(false, reason: "ting.import"); dayToDelete = nil }
        do { try store.delete(day); speech.replaceLibrary(store.library) }
        catch { self.error = error.localizedDescription }
    }
}
