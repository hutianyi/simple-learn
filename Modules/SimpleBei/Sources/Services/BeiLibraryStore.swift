import Foundation
import Observation
import StudyShell

private actor BeiRepository {
    private let directoryOverride: URL?
    init(directory: URL?) { directoryOverride = directory }
    private func file() throws -> BeiLibraryFile {
        let directory = try directoryOverride ?? ModuleStorage.directory("SimpleBei")
        return BeiLibraryFile(url: directory.appendingPathComponent("Library.json"))
    }
    func load() throws -> BeiLibrary { try file().load() }
    func save(_ library: BeiLibrary, safetyCopy: BeiLibrary? = nil) throws {
        if let safetyCopy {
            let data = try BeiBackup(library: safetyCopy).encoded()
            if let directoryOverride {
                let folder = directoryOverride.appendingPathComponent("SafetyBackups")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("PreRestore-\(UUID().uuidString).json"), options: .atomic)
            } else { try ModuleStorage.saveSafetyBackup(data, module: "SimpleBei") }
        }
        try file().save(library)
    }
    func readBackup(_ url: URL) throws -> BeiBackup {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try BeiBackup.decode(Data(contentsOf: url))
    }
}

@MainActor @Observable
final class BeiLibraryStore {
    private(set) var library = BeiLibrary()
    private(set) var isReady = false
    private(set) var busy = false
    private(set) var loadError: String?
    var error: String?
    private let repository: BeiRepository
    init(directory: URL? = nil) { repository = BeiRepository(directory: directory) }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { library = try await repository.load(); isReady = true; loadError = nil }
        catch { isReady = false; loadError = "课文库读取失败，已保留原文件：\(error.localizedDescription)" }
    }

    private func write(_ candidate: BeiLibrary, safetyCopy: Bool = false) async -> Bool {
        guard isReady, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            _ = try candidate.validated()
            try await repository.save(candidate, safetyCopy: safetyCopy ? library : nil)
            library = candidate
            return true
        } catch { self.error = "保存失败，原课文库未改变：\(error.localizedDescription)"; return false }
    }
    func save(_ passage: Passage) async -> Bool {
        var candidate = library
        if let index = candidate.passages.firstIndex(where: { $0.id == passage.id }) { candidate.passages[index] = passage }
        else { candidate.passages.append(passage) }
        return await write(candidate)
    }
    func archive(_ passage: Passage) async {
        var updated = passage; updated.archived.toggle(); updated.editedAt = Date()
        _ = await save(updated)
    }
    func delete(_ passage: Passage) async {
        var candidate = library; candidate.passages.removeAll { $0.id == passage.id }
        _ = await write(candidate)
    }
    func savePreferences(_ preferences: BeiPreferences) async -> Bool {
        var candidate = library; candidate.preferences = preferences
        return await write(candidate)
    }
    func previewBackup(_ url: URL) async -> BeiImportPreview? {
        guard isReady, !busy else { return nil }
        busy = true
        defer { busy = false }
        do { return try BeiImportPreview(backup: await repository.readBackup(url), current: library) }
        catch { self.error = "备份无法导入，原课文库未改变：\(error.localizedDescription)"; return nil }
    }
    func apply(_ preview: BeiImportPreview, useSettings: Bool) async -> Bool {
        do { return await write(try preview.merged(current: library, useSettings: useSettings), safetyCopy: true) }
        catch { self.error = error.localizedDescription; return false }
    }
}

public actor SimpleBeiStartup {
    public static let shared = SimpleBeiStartup()
    private var cleaned = false
    public func prepare() throws {
        guard !cleaned else { return }
        try BeiSessionFiles.applicationFiles().cleanResiduals()
        cleaned = true
    }
}
