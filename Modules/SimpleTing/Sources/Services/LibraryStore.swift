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
            let file = try override ?? LibraryFile(url: ModuleStorage.directory("SimpleTing").appendingPathComponent("library-v1.json"))
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
}
