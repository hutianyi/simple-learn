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
    @State private var displayedArticleID: UUID?
    @State private var libraryRefreshID = 0
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var presentation: ListenPresentation?
    @State private var articleToDelete: ListenArticle?
    @State private var error: String?
    @EnvironmentObject private var session: ModuleSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = LibraryStore()
        let settings = ListenSettings()
        let speech = SpeechService(settings: settings, library: store.library)
        _store = State(initialValue: store); _settings = State(initialValue: settings); _speech = State(initialValue: speech)
        _displayedArticleID = State(initialValue: speech.playback.selectedArticleID ?? store.library.articlesNewestFirst.first?.id)
    }

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
                    ForEach(store.library.articlesNewestFirst) { article in
                        Button {
                            openAndPlay(article.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(article.title).font(.headline).lineLimit(2)
                                    if let day = store.library.day(for: article.id) {
                                        Text("第 \(day.importSequence) 次导入 · 第 \(article.articleNumber) 篇").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if displayedArticleID == article.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }.foregroundStyle(.primary)
                        }
                        .disabled(speech.playback.state == .stopping)
                        .swipeActions { Button("删除", role: .destructive) { requestDelete(article) } }
                        .contextMenu { Button("删除这篇文章", role: .destructive) { requestDelete(article) } }
                    }
                }
                .id(libraryRefreshID)
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
                            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("文章库", systemImage: "chevron.left") { compactColumn = .sidebar } } }
                        } else { ContentUnavailableView("还没有文章", systemImage: "headphones", description: Text("点击上方“导入文章”，粘贴一份 Markdown 全文。")) }
                    }
                    .navigationTitle("简单听")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerView(speech: speech) { showCurrent() } }
        .sheet(item: $presentation) { modal in
            switch modal {
            case .settings: ListenSettingsView(speech: speech, store: store, settings: settings)
            case .pasteImport:
                ListenPasteImportView(store: store, speech: speech) { id in
                    displayedArticleID = id
                    // Rebuild the sidebar after a successful import so new rows appear at the top.
                    libraryRefreshID += 1
                    compactColumn = .detail
                }
            }
        }
        .confirmationDialog("删除这篇文章？同次导入的其他文章会保留。", isPresented: Binding(get: { articleToDelete != nil }, set: { if !$0 { articleToDelete = nil } }), titleVisibility: .visible) {
            if let article = articleToDelete { Button("删除 \(article.title)", role: .destructive) { delete(article) } }
            Button("取消", role: .cancel) { articleToDelete = nil }
        }
        .alert("简单听", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
        .onChange(of: speech.playback.hasSession, initial: true) { _, busy in session.setBusy(busy, reason: "ting.playback") }
        .onChange(of: speech.playback.selectedArticleID) { previous, current in
            if displayedArticleID == previous { displayedArticleID = current }
        }
        .onChange(of: store.library) { _, _ in
            if displayedArticleID.flatMap({ store.library.article($0) }) == nil {
                displayedArticleID = store.library.articlesNewestFirst.first?.id
            }
        }
        .onChange(of: scenePhase) { _, value in if value == .active { speech.returnedToForeground() } }
        .onDisappear { speech.stop(); session.setBusy(false, reason: "ting.playback"); session.setBusy(false, reason: "ting.import") }
    }
    private func openAndPlay(_ id: UUID) { displayedArticleID = id; speech.play(id); compactColumn = .detail }
    private func showCurrent() { displayedArticleID = speech.playback.selectedArticleID; compactColumn = .detail }
    private func requestDelete(_ article: ListenArticle) {
        guard !speech.playback.hasSession else { error = "请先停止本次播放和定时，再删除文章。"; return }
        articleToDelete = article
    }
    private func delete(_ article: ListenArticle) {
        guard !speech.playback.hasSession else { error = "请先停止本次播放和定时，再删除文章。"; articleToDelete = nil; return }
        session.setBusy(true, reason: "ting.import")
        defer { session.setBusy(false, reason: "ting.import"); articleToDelete = nil }
        do { try store.delete(article); speech.replaceLibrary(store.library) }
        catch { self.error = error.localizedDescription }
    }
}
