import SwiftUI
import UniformTypeIdentifiers
import StudyShell

extension UTType {
    static let simpleDu = UTType(exportedAs: "com.hutianyi.simpledu", conformingTo: .zip)
}

public struct SimpleDuModuleView: View {
    @State private var store = DuStore()
    @State private var importing = false
    @State private var sheet: DuSheet?
    @State private var pendingDeletion: DuBook?
    @State private var location = DuShelfLocation.shelf
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.studyTheme) private var theme
    @EnvironmentObject private var session: ModuleSession
    private let addToListening: (@MainActor (SimpleDuListeningArticle) async throws -> String)?
    public init(addToListening: (@MainActor (SimpleDuListeningArticle) async throws -> String)? = nil) {
        self.addToListening = addToListening
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let error = store.loadError {
                    ContentUnavailableView {
                        Label("暂时无法打开文章列表", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("重新读取") { Task { await store.load() } }.buttonStyle(.borderedProminent)
                        Text("如需恢复数据，请返回首页使用“备份与恢复”。").font(.subheadline)
                    }
                } else if store.snapshot == nil {
                    ProgressView("正在加载文章…")
                } else if store.books.isEmpty {
                    ContentUnavailableView {
                        Label("还没有阅读文章", systemImage: "doc.text")
                    } description: {
                        Text("从‘文件’中选择阅读包，即可开始阅读。\n同一批中的每篇文章会单独显示。")
                    } actions: {
                        Button("导入阅读包", systemImage: "square.and.arrow.down") { importing = true }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("du.emptyImport")
                    }
                } else { bookshelf }
            }
            .studyBottomBar {
                if selecting { selectionActions }
            }
            .navigationTitle("KET 阅读")
            .background(StudyAppearance.background)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(selecting ? "完成" : "选择") {
                        selecting.toggle(); selectedIDs = []
                    }.disabled(store.books.isEmpty).accessibilityIdentifier("du.selectMode")
                    Button("导入", systemImage: "plus") { importing = true }
                        .disabled(store.loadError != nil || selecting).accessibilityIdentifier("du.import")
                }
            }
            .navigationDestination(for: String.self) { id in DuReaderView(store: store, bookID: id, addToListening: addToListening) }
            .disabled(store.busy)
            .allowsHitTesting(!store.saving)
            .overlay { if store.busy { ProgressView("正在处理…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
        }
        .task { await store.load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.simpleDu, .zip], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await store.prepare(urls); sheet = .preview }
            case .failure(let error): store.message = error.localizedDescription
            }
        }
        .sheet(item: $sheet, onDismiss: {
            store.previews = []
            if !store.busy { Task { await store.load() } }
        }) { route in
            switch route {
            case .preview: DuImportPreview(store: store)
            }
        }
        .confirmationDialog("删除这篇文章和记录？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            if let book = pendingDeletion {
                Button("删除文章和记录", role: .destructive) {
                    let id = book.id; pendingDeletion = nil
                    Task { await store.deleteArticle(id) }
                }.accessibilityIdentifier("du.confirmDelete")
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("将删除《\(pendingDeletion?.article.title ?? "")》及其各版本阅读进度和全部做题记录。同包其他文章保留。原始阅读包和以前导出的备份不变。")
        }
        .alert("简单读", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(store.message ?? "") }
        .onChange(of: location) { _, _ in
            selectedIDs = []; selecting = false; store.libraryNotice = nil
        }
        .onChange(of: store.busy || store.saving) { _, busy in session.setBusy(busy, reason: "du.storage") }
        .onDisappear { session.setBusy(false, reason: "du.storage") }
    }

    private var visibleBooks: [DuBook] {
        store.books.filter { $0.isArchived == (location == .cabinet) }
    }
    private var archivedCount: Int { store.books.filter(\.isArchived).count }

    private var bookshelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("阅读状态", selection: $location) {
                    Text("未读文章 · \(store.books.count - archivedCount)").tag(DuShelfLocation.shelf)
                    Text("已读文章 · \(archivedCount)").tag(DuShelfLocation.cabinet)
                }.pickerStyle(.segmented).accessibilityIdentifier("du.libraryLocation")
                if let notice = store.libraryNotice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                if location == .cabinet {
                    HStack(spacing: 12) {
                        Image(systemName: "books.vertical.fill").font(.title2).foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已读文章").font(.headline)
                            Text("标为未读后可从头阅读，历史成绩保留。").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                } else if !selecting, let book = store.snapshot?.continuingBook {
                    NavigationLink(value: book.id) {
                        HStack(spacing: 16) {
                            Image(systemName: "book.pages.fill").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("继续阅读").font(.subheadline)
                                Text(book.shelfLabel).font(.title3.bold()).multilineTextAlignment(.leading)
                            }
                            Spacer(); Image(systemName: "arrow.right")
                        }.padding(20).background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain).accessibilityIdentifier("du.continue")
                        .contextMenu { bookMenu(book) }
                        .accessibilityAction(named: "删除文章") { pendingDeletion = book }
                }
                HStack {
                    Text(selecting ? "已选 \(selectedIDs.count) / \(visibleBooks.count) 篇" : "共 \(visibleBooks.count) 篇")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if selecting {
                        Button(selectedIDs.count == visibleBooks.count && !visibleBooks.isEmpty ? "取消全选" : "全选") {
                            if selectedIDs.count == visibleBooks.count { selectedIDs = [] }
                            else { selectedIDs = Set(visibleBooks.map(\.id)) }
                        }.disabled(visibleBooks.isEmpty).accessibilityIdentifier("du.selectAll")
                    }
                }
                if visibleBooks.isEmpty {
                    ContentUnavailableView {
                        Label(location == .shelf ? "暂无未读文章" : "暂无已读文章", systemImage: "doc.text")
                    } description: {
                        Text(location == .shelf ? "可以查看已读文章，或导入新的阅读包。" : "完成阅读和答题，或标为已读后，文章会显示在这里。")
                    } actions: {
                        if location == .shelf { Button("查看已读文章") { location = .cabinet } }
                    }.padding(.vertical, 24)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 156), spacing: 18)], spacing: 20) {
                        ForEach(visibleBooks) { book in
                            bookItem(book)
                                .transition(.scale(scale: 0.86).combined(with: .opacity))
                        }
                    }
                    .padding(location == .cabinet ? 16 : 0)
                    .background(theme.accent.opacity(location == .cabinet ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 18))
                }
            }.padding(24).frame(maxWidth: 1200).frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.85), value: visibleBooks.map(\.id))
        }
    }

    @ViewBuilder private func bookItem(_ book: DuBook) -> some View {
        if selecting {
            Button {
                if !selectedIDs.insert(book.id).inserted { selectedIDs.remove(book.id) }
            } label: {
                DuBookCard(book: book)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selectedIDs.contains(book.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2).symbolRenderingMode(.palette)
                            .foregroundStyle(selectedIDs.contains(book.id) ? theme.accent : Color.gray, .white)
                            .background(.white, in: Circle()).padding(6)
                    }
            }.buttonStyle(.plain)
                .accessibilityLabel("\(book.shelfLabel)，\(book.article.title)")
                .accessibilityValue(selectedIDs.contains(book.id) ? "已选" : "未选")
                .accessibilityAddTraits(selectedIDs.contains(book.id) ? .isSelected : [])
                .accessibilityIdentifier("du.select.\(book.article.id)")
        } else {
            NavigationLink(value: book.id) { DuBookCard(book: book) }
                .buttonStyle(.plain).accessibilityIdentifier("du.book.\(book.article.id)")
                .contextMenu { bookMenu(book) }
                .accessibilityAction(named: "删除文章") { pendingDeletion = book }
        }
    }

    @ViewBuilder private func bookMenu(_ book: DuBook) -> some View {
        if let addToListening {
            Button("添加到简单听", systemImage: "headphones") {
                Task { await store.addToListening(book.id, perform: addToListening) }
            }.accessibilityIdentifier("du.addToListening")
            Divider()
        }
        Button("标为已读", systemImage: "checkmark.circle") { arrange([book.id], action: .markRead) }
        Button("标为未读", systemImage: "circle") { arrange([book.id], action: .markUnread) }
        Divider()
        Button("删除文章", systemImage: "trash", role: .destructive) { pendingDeletion = book }
    }

    private var selectionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                Text("已选 \(selectedIDs.count) 篇").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                batchStatusMenu
                batchArchiveButton
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("已选 \(selectedIDs.count) 篇").font(.subheadline).foregroundStyle(.secondary)
                batchStatusMenu
                batchArchiveButton
            }
        }.padding(.horizontal, 24).padding(.vertical, 14).background(.bar)
    }
    private var batchStatusMenu: some View {
        Menu {
            Button("标为已读") { arrange(selectedIDs, action: .markRead) }
            Button("标为未读") { arrange(selectedIDs, action: .markUnread) }
        } label: { Label("标记状态", systemImage: "checkmark.circle") }
            .fixedSize().disabled(selectedIDs.isEmpty).accessibilityIdentifier("du.batchStatus")
    }
    private var batchArchiveButton: some View {
        Button(location == .cabinet ? "标为未读" : "标为已读", systemImage: location == .cabinet ? "circle" : "checkmark.circle") {
            arrange(selectedIDs, action: location == .cabinet ? .markUnread : .markRead)
        }.buttonStyle(.borderedProminent).fixedSize().disabled(selectedIDs.isEmpty).accessibilityIdentifier("du.batchArchive")
    }

    private func arrange(_ ids: Set<String>, action: DuLibraryAction) {
        Task {
            if await store.arrange(ids, action: action) {
                selectedIDs = []; selecting = false
            }
        }
    }

}

private enum DuShelfLocation: Hashable { case shelf, cabinet }

private enum DuSheet: String, Identifiable { case preview; var id: String { rawValue } }

private struct DuImportPreview: View {
    let store: DuStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("导入后每篇文章单独显示。正文、插图和进度保存在 App 内，可以离线阅读。")
                }
                ForEach(store.previews) { item in
                    Section(item.filename) {
                        if let package = item.package, let snapshot = store.snapshot {
                            let kind = DuRepository.kind(package, in: snapshot)
                            Label(kind.rawValue, systemImage: kind.canImport ? "books.vertical" : "info.circle")
                            ForEach(package.content.articles) { article in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(article.title).font(.headline)
                                    Text("\(article.units.count) 个阅读单元 · \(article.questions.count) 道题").foregroundStyle(.secondary)
                                }
                            }
                            if kind == .update {
                                Text("新版本将从头阅读和答题；旧版本的内容与成绩仍保存在完整备份中。")
                                    .foregroundStyle(.secondary)
                            } else if kind == .restore {
                                Text("已删除的文章将重新加入未读文章，从头阅读和答题；原有其他文章及成绩保留。")
                                    .foregroundStyle(.secondary)
                            } else if kind == .conflict {
                                Text("同一批次和版本的内容不同，请制作者递增版本后重新导入。")
                            }
                        } else { Text(item.error ?? "无法读取").foregroundStyle(.red) }
                    }
                }
            }.navigationTitle("导入预览")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { Task { await store.importAll(); dismiss() } }
                        .disabled(store.busy || !hasImportable).accessibilityIdentifier("du.confirmImport")
                }
            }.disabled(store.busy)
        }.interactiveDismissDisabled(store.busy)
    }
    private var hasImportable: Bool {
        guard let snapshot = store.snapshot else { return false }
        return store.previews.contains { $0.package.map { DuRepository.kind($0, in: snapshot).canImport } ?? false }
    }
}
