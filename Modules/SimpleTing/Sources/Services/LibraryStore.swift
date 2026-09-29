import Foundation
import Observation
import StudyShell

@MainActor @Observable
final class LibraryStore {
    private(set) var library = ListenLibrary()
    private(set) var loadError: String?
    @ObservationIgnored private var file: LibraryFile?
    init() {
        do {
            let url = try ModuleStorage.directory("SimpleTing").appendingPathComponent("library-v1.json")
            let file = LibraryFile(url: url)
            library = try file.load()
            self.file = file
        } catch { loadError = "无法打开文章库：\(error.localizedDescription)\n原文件已保留，请先处理读取问题。" }
    }
    func commit(_ drafts: [ImportDraft]) throws {
        guard let file, loadError == nil else { throw ListenError.message("文章库尚未成功打开。") }
        let candidate = try library.importing(drafts)
        try file.save(candidate)
        library = candidate
    }
    func delete(_ day: ListenDay) throws {
        guard let file, loadError == nil else { throw ListenError.message("文章库尚未成功打开。") }
        var candidate = library
        candidate.days.removeAll { $0.id == day.id }
        try file.save(candidate)
        library = candidate
    }
}
