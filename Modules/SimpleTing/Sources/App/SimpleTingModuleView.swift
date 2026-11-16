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
    @State private var editingArticle: ListenArticle?
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { requestDelete(article) }.tint(.red)
                            Button("编辑") { edit(article) }.tint(.blue)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button("编辑") { edit(article) }.tint(.blue)
                            Button("删除", role: .destructive) { requestDelete(article) }.tint(.red)
                        }
                        .contextMenu {
                            Button("编辑文章", systemImage: "pencil") { edit(article) }
                            Button("删除这篇文章", role: .destructive) { requestDelete(article) }
                        }
                        .disabled(speech.playback.state == .stopping || editingArticle != nil)
                    }
                }
                .id(libraryRefreshID)
                .navigationTitle("文章库")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("导入文章", systemImage: "plus") { presentation = .pasteImport }
                            .disabled(store.loadError != nil || speech.playback.state == .stopping || editingArticle != nil)
                            .accessibilityIdentifier("listen.import")
                        Button("设置", systemImage: "gearshape") { presentation = .settings }
                            .disabled(editingArticle != nil)
                            .accessibilityIdentifier("listen.settings")
                    }
                }
            } detail: {
                NavigationStack {
                    Group {
                        if let article = editingArticle {
                            ListenArticleEditor(article: article, canSave: !speech.playback.hasSession) { title, markdown in
                                guard !speech.playback.hasSession else { throw ListenError.message("正在停止播放，请稍后保存。") }
                                try store.updateArticle(article.id, title: title, markdown: markdown)
                                speech.replaceLibrary(store.library)
                                editingArticle = nil
                            } cancel: { editingArticle = nil }
                            .id(article.id)
                        } else if let article = displayedArticle {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 28) {
                                    Text(article.title).font(StudyAppearance.title)
                                    MarkdownBodyView(markdown: article.rawMarkdown)
                                }.padding(StudyAppearance.pagePadding).frame(maxWidth: 900).frame(maxWidth: .infinity)
                            }
                            .id(article.id)
                            .accessibilityIdentifier("listen.articleBody")
                            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("文章库", systemImage: "chevron.left") { compactColumn = .sidebar } } }
                        } else { ContentUnavailableView("还没有文章", systemImage: "headphones", description: Text("点击上方“导入文章”，粘贴一份 Markdown 全文。")) }
                    }
                    .navigationTitle(editingArticle == nil ? "" : "编辑文章")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            // Give both navigation columns a viewport that actually ends above the player.
            // An outer safe-area inset can leave the detail scroll view extending behind it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            if editingArticle == nil {
                Divider()
                PlayerView(speech: speech) { showCurrent() }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        .alert("删除这篇文章？", isPresented: Binding(get: { articleToDelete != nil }, set: { if !$0 { articleToDelete = nil } }), presenting: articleToDelete) { article in
            Button("删除", role: .destructive) { delete(article) }
            Button("取消", role: .cancel) { articleToDelete = nil }
        } message: { article in
            Text("将删除“\(article.title)”。同次导入的其他文章会保留。")
        }
        .alert("简单听", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
        .onChange(of: speech.playback.hasSession, initial: true) { _, busy in session.setBusy(busy, reason: "ting.playback") }
        .onChange(of: editingArticle != nil) { _, editing in session.setBusy(editing, reason: "ting.edit") }
        .onChange(of: speech.playback.selectedArticleID) { previous, current in
            if displayedArticleID == previous { displayedArticleID = current }
        }
        .onChange(of: store.library) { _, _ in
            if displayedArticleID.flatMap({ store.library.article($0) }) == nil {
                displayedArticleID = store.library.articlesNewestFirst.first?.id
            }
        }
        .onChange(of: scenePhase) { _, value in if value == .active { speech.returnedToForeground() } }
        .onDisappear { speech.stop(); session.setBusy(false, reason: "ting.playback"); session.setBusy(false, reason: "ting.import"); session.setBusy(false, reason: "ting.edit") }
    }
    private func edit(_ article: ListenArticle) {
        guard editingArticle == nil else { return }
        speech.stop()
        displayedArticleID = article.id
        editingArticle = article
        compactColumn = .detail
    }
    private func openAndPlay(_ id: UUID) { displayedArticleID = id; speech.play(id); compactColumn = .detail }
    private func showCurrent() { displayedArticleID = speech.playback.selectedArticleID; compactColumn = .detail }
    private func requestDelete(_ article: ListenArticle) {
        guard editingArticle == nil else { return }
        guard !speech.playback.hasSession else { error = "请先停止本次播放和定时，再删除文章。"; return }
        articleToDelete = article
    }
    private func delete(_ article: ListenArticle) {
        guard editingArticle == nil else { return }
        guard !speech.playback.hasSession else { error = "请先停止本次播放和定时，再删除文章。"; articleToDelete = nil; return }
        session.setBusy(true, reason: "ting.import")
        defer { session.setBusy(false, reason: "ting.import"); articleToDelete = nil }
        do { try store.delete(article); speech.replaceLibrary(store.library) }
        catch { self.error = error.localizedDescription }
    }
}

private struct ListenArticleEditor: View {
    let article: ListenArticle
    let canSave: Bool
    let save: (String, String) throws -> Void
    let cancel: () -> Void
    @State private var title: String
    @State private var markdown: String
    @State private var error: String?
    @State private var confirmDiscard = false

    init(article: ListenArticle, canSave: Bool, save: @escaping (String, String) throws -> Void, cancel: @escaping () -> Void) {
        self.article = article; self.canSave = canSave; self.save = save; self.cancel = cancel
        _title = State(initialValue: article.title)
        _markdown = State(initialValue: article.rawMarkdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("文章标题", text: $title, axis: .vertical)
                .font(.title2).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("listen.editTitle")
            Text("正文（支持 Markdown 格式）").font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: $markdown)
                .font(.title3).scrollContentBackground(.hidden)
                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("文章正文").accessibilityIdentifier("listen.editBody")
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(StudyAppearance.pagePadding)
        .navigationTitle("编辑文章")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    if title != article.title || markdown != article.rawMarkdown { confirmDiscard = true }
                    else { cancel() }
                }
                .accessibilityIdentifier("listen.cancelEdit")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do { try save(title, markdown) }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(!canSave || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("listen.saveEdit")
            }
        }
        .confirmationDialog("放弃这次修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive, action: cancel)
            Button("继续编辑", role: .cancel) {}
        }
    }
}
