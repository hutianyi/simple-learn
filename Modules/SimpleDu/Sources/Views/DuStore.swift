import Foundation
import Observation
import StudyShell

@MainActor @Observable
final class DuStore {
    var snapshot: DuSnapshot?
    var busy = false
    var saving = false
    var loadError: String?
    var message: String?
    var libraryNotice: String?
    var previews: [DuImportItem] = []
    private var repository: DuRepository?
    var books: [DuBook] { snapshot?.books ?? [] }
    func book(_ id: String) -> DuBook? { books.first { $0.id == id } }

    func load() async {
        busy = true
        defer { busy = false }
        do {
            let repository = try DuRepository(directory: ModuleStorage.directory("SimpleDu"))
            snapshot = try await repository.load(); self.repository = repository; loadError = nil
        } catch { loadError = "文章列表读取失败，原文件已保留。\n\(error.localizedDescription)" }
    }
    func prepare(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        previews = await Task.detached(priority: .userInitiated) {
            urls.map { url in
                do {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    var failure: Error?, archive: Data?
                    var coordinationError: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { file in
                        do {
                            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                            try duRequire(values.isRegularFile == true && (values.fileSize ?? Int.max) <= DuArchive.maxArchiveBytes,
                                          "请选择不超过 64 MB 的阅读包文件。")
                            archive = try Data(contentsOf: file, options: .mappedIfSafe)
                        } catch { failure = error }
                    }
                    if let coordinationError { throw coordinationError }
                    if let failure { throw failure }
                    guard let archive else { throw DuError("文件尚未下载完成，请在‘文件’App 中下载后重试。") }
                    return DuImportItem(filename: url.lastPathComponent, package: try DuPackage.decode(archive), error: nil)
                } catch {
                    return DuImportItem(filename: url.lastPathComponent, package: nil,
                                        error: "\(error.localizedDescription)\n若文件在 iCloud，请确认已下载后重新选择。")
                }
            }
        }.value
    }
    func importAll() async {
        guard let repository else { return }
        busy = true
        defer { busy = false; previews = [] }
        var results: [String] = []
        for item in previews {
            guard let package = item.package else { results.append("\(item.filename)：未导入（文件无效）"); continue }
            do {
                let previousCount = snapshot?.books.count ?? 0
                let (value, kind) = try await repository.install(package)
                snapshot = value
                let detail: String
                if kind == .restore {
                    detail = "已重新加入 \(max(0, value.books.count - previousCount)) 篇，其他文章与记录保留"
                } else {
                    detail = kind.canImport ? "已导入 \(package.content.articles.count) 篇" : kind.rawValue + "，已跳过"
                }
                results.append("\(item.filename)：\(detail)")
            } catch { results.append("\(item.filename)：\(error.localizedDescription)") }
        }
        message = results.joined(separator: "\n")
    }
    @discardableResult
    func arrange(_ ids: Set<String>, action: DuLibraryAction) async -> Bool {
        guard !busy, !saving, let repository, !ids.isEmpty else { return false }
        saving = true
        defer { saving = false }
        do {
            snapshot = try await repository.arrangeArticles(ids, action: action)
            libraryNotice = "\(ids.count) " + action.resultText
            return true
        } catch {
            message = "整理未完成，原记录已保留：\(error.localizedDescription)"
            return false
        }
    }
    func addToListening(_ id: String, perform: @MainActor (SimpleDuListeningArticle) async throws -> String) async {
        guard !busy, !saving, let book = book(id) else { return }
        saving = true
        defer { saving = false }
        do { message = try await perform(book.listeningArticle()) }
        catch { message = "未能添加到简单听：\(error.localizedDescription)" }
    }
    func answerListeningOffer(_ id: String, add: Bool, perform: @MainActor (SimpleDuListeningArticle) async throws -> String) async {
        guard !busy, !saving, let repository else { return }
        saving = true
        do { snapshot = try await repository.acknowledgeListeningOffer(id) }
        catch {
            saving = false
            message = "未能保存本次选择，请重试：\(error.localizedDescription)"
            return
        }
        saving = false
        if add { await addToListening(id, perform: perform) }
    }
    func deleteArticle(_ id: String) async {
        guard !busy, !saving, let repository else { return }
        saving = true
        defer { saving = false }
        do { snapshot = try await repository.deleteArticle(id) }
        catch { message = "删除未完成，原记录已保留：\(error.localizedDescription)" }
    }
    func change(_ id: String, fontSize: Double? = nil, modify: (inout DuProgress) throws -> Void) async {
        guard !busy, !saving, let repository, let book = book(id) else { return }
        saving = true
        defer { saving = false }
        do {
            var progress = book.progress
            try modify(&progress); progress.updatedAt = Date()
            snapshot = try await repository.saveProgress(progress, bookID: id, fontSize: fontSize)
        } catch { message = "保存失败，操作未完成，请重试：\(error.localizedDescription)" }
    }
}
