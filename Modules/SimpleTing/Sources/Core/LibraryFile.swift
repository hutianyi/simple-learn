import Foundation

struct ListenBackup: Codable {
    var formatVersion = 1
    var module = "SimpleTing"
    var exportedAt = Date()
    var library: ListenLibrary
    var preferences: ListenPreferences?

    func validate() throws {
        guard formatVersion == 1, module == "SimpleTing" else { throw ListenError.message("这份文件不是受支持的简单听备份。") }
        try library.validate()
        if let id = preferences?.lastPlayedID, library.article(id) == nil {
            throw ListenError.message("备份中的播放位置无效，不能恢复。")
        }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    static func decode(_ data: Data) throws -> ListenBackup {
        let decoder = JSONDecoder()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let backup: ListenBackup
        if object?["formatVersion"] != nil || object?["module"] != nil || object?["library"] != nil {
            backup = try decoder.decode(ListenBackup.self, from: data)
        } else {
            // Existing internal safety copies contain the article library alone.
            backup = ListenBackup(library: try decoder.decode(ListenLibrary.self, from: data))
        }
        try backup.validate()
        return backup
    }
}

struct LibraryFile {
    static let retainedBackupCount = 10
    let url: URL
    var writer: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }

    func load() throws -> ListenLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return ListenLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let library = try decoder.decode(ListenLibrary.self, from: Data(contentsOf: url))
        try library.validate()
        return library
    }

    func save(_ library: ListenLibrary) throws {
        try library.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try encoder.encode(library)
        let folder = url.deletingLastPathComponent()
        var latestBackup: URL?
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let safety = folder.appendingPathComponent("SafetyBackups", isDirectory: true)
            try FileManager.default.createDirectory(at: safety, withIntermediateDirectories: true)
            let copy = safety.appendingPathComponent("BeforeChange-\(UUID().uuidString).json")
            try Data(contentsOf: url).write(to: copy, options: .atomic)
            latestBackup = copy
        }
        try writer(data, url)
        do { try pruneSafetyBackups(keeping: latestBackup) }
        catch { NSLog("[SimpleTing] 文章库已保存，旧安全副本暂未清理：%@", error.localizedDescription) }
    }

    private func pruneSafetyBackups(keeping latest: URL?) throws {
        let safety = url.deletingLastPathComponent().appendingPathComponent("SafetyBackups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: safety.path) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: safety, includingPropertiesForKeys: Array(keys))
        let owned = try files.compactMap { file -> (URL, Date)? in
            let stem = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", stem.hasPrefix("BeforeChange-"),
                  UUID(uuidString: String(stem.dropFirst("BeforeChange-".count))) != nil else { return nil }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (file, values.contentModificationDate ?? .distantPast)
        }.sorted {
            if $0.0 == latest || $1.0 == latest { return $0.0 == latest && $1.0 != latest }
            return $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 > $1.1
        }
        for (file, _) in owned.dropFirst(Self.retainedBackupCount) { try FileManager.default.removeItem(at: file) }
    }
}
