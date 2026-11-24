import Foundation
import Observation
import StudyShell

@MainActor @Observable
final class LibraryStore {
    private(set) var library = ListenLibrary()
    private(set) var loadError: String?
    @ObservationIgnored private var file: LibraryFile?
    init(file override: LibraryFile? = nil) {
        do {
            let file = try override ?? .forSimpleTing()
            self.file = file
            library = try file.load()
        } catch { loadError = "无法打开文章库：\(error.localizedDescription)\n原文件已保留，请先处理读取问题。" }
    }
    func exportData(preferences: ListenPreferences) throws -> Data {
        guard loadError == nil, file != nil else { throw ListenError.message("文章库尚未成功打开，不能导出空备份覆盖原数据。") }
        return try ListenBackup(library: library, preferences: preferences).encoded()
    }
    func restore(_ backup: ListenBackup, settings: ListenSettings? = nil) throws {
        try backup.validate()
        guard let file else { throw ListenError.message("文章库保存位置不可用。") }
        try file.save(backup.library)
        library = backup.library; loadError = nil
        if let preferences = backup.preferences { settings?.apply(preferences) }
    }
    func commit(_ drafts: [ImportDraft]) throws {
        guard let file, loadError == nil else { throw ListenError.message("文章库尚未成功打开。") }
        let candidate = try library.importing(drafts)
        try file.save(candidate)
        library = candidate
    }
    func delete(_ article: ListenArticle) throws {
        guard let file, loadError == nil else { throw ListenError.message("文章库尚未成功打开。") }
        var candidate = library
        guard let index = candidate.days.firstIndex(where: { $0.articles.contains { $0.id == article.id } }) else { return }
        candidate.days[index].articles.removeAll { $0.id == article.id }
        if candidate.days[index].articles.isEmpty { candidate.days.remove(at: index) }
        try file.save(candidate)
        library = candidate
    }
    func updateArticle(_ id: UUID, title: String, markdown: String) throws {
        guard let file, loadError == nil else { throw ListenError.message("文章库尚未成功打开。") }
        let candidate = try library.updatingArticle(id, title: title, markdown: markdown)
        guard candidate != library else { return }
        try file.save(candidate)
        library = candidate
    }
}

@MainActor
public enum SimpleTingBackupTransfer {
    public static func exportData() throws -> Data {
        try LibraryStore().exportData(preferences: ListenSettings().snapshot)
    }
    public static func validate(_ data: Data) throws -> String {
        let backup = try ListenBackup.decode(data)
        guard backup.preferences != nil else { throw WholeBackupError.message("整体备份缺少简单听播放设置。") }
        return "文章 \(backup.library.days.reduce(0) { $0 + $1.articles.count }) 篇及播放设置"
    }
    public static func restore(_ data: Data) throws {
        _ = try validate(data)
        try LibraryStore().restore(ListenBackup.decode(data), settings: ListenSettings())
    }
}

public enum SimpleTingArticleImportResult: Sendable { case added, alreadyPresent }

@MainActor
public enum SimpleTingArticleImport {
    public nonisolated static func existingReadingSourceIDs(_ sourceIDs: Set<String>) async throws -> Set<String> {
        try await Task.detached(priority: .userInitiated) {
            try existingReadingSourceIDs(sourceIDs, file: .forSimpleTing())
        }.value
    }

    nonisolated static func existingReadingSourceIDs(_ sourceIDs: Set<String>, file: LibraryFile) throws -> Set<String> {
        let keys = Set(try file.load().days.compactMap(\.sourceKey))
        return sourceIDs.filter { keys.contains(readingSourceKey($0)) }
    }

    public static func addFromReading(title: String, bodyMarkdown: String, sourceID: String) throws -> SimpleTingArticleImportResult {
        try addFromReading(title: title, bodyMarkdown: bodyMarkdown, sourceID: sourceID, file: nil)
    }

    static func addFromReading(title: String, bodyMarkdown: String, sourceID: String,
                               file: LibraryFile?) throws -> SimpleTingArticleImportResult {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !markdown.isEmpty, !sourceID.isEmpty, sourceID.utf8.count <= 512 else {
            throw ListenError.message("简单读文章的标题、正文或来源编号不完整。")
        }
        let store = LibraryStore(file: file)
        if let error = store.loadError { throw ListenError.message(error) }
        let key = readingSourceKey(sourceID)
        if store.library.days.contains(where: { $0.sourceKey == key }) { return .alreadyPresent }
        let speechText = try MarkdownCleaner.plainText(markdown)
        guard !speechText.isEmpty else { throw ListenError.message("文章没有可朗读的正文，未添加到简单听。") }
        let article = ListenArticle(articleNumber: 1, title: title, rawMarkdown: markdown, speechText: speechText)
        let draft = ImportDraft(sourceFileName: "简单读", sourceMarkdown: "# Article 1: \(title)\n\n\(markdown)",
            dayNumber: nil, sourceKey: key, title: title, articles: [article])
        try store.commit([draft])
        return .added
    }

    private nonisolated static func readingSourceKey(_ sourceID: String) -> String { "simpledu:\(sourceID)" }
}

private extension LibraryFile {
    static func forSimpleTing() throws -> Self {
        try Self(url: ModuleStorage.directory("SimpleTing").appendingPathComponent("library-v1.json"))
    }
}
