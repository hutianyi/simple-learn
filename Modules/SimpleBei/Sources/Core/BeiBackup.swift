import Foundation

struct BeiBackup: Codable {
    var app = "SimpleXue"
    var module = "SimpleBei"
    var backupFormatVersion = 1
    var library: BeiLibrary

    static func decode(_ data: Data) throws -> BeiBackup {
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.app == "SimpleXue", backup.module == "SimpleBei", backup.backupFormatVersion == 1 else {
            throw BeiError.invalid("这不是支持的简单背课文备份，原数据未改变。")
        }
        _ = try backup.library.validated()
        return backup
    }
    func encoded() throws -> Data {
        _ = try library.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

struct BeiImportPreview: Identifiable {
    let id = UUID()
    let backup: BeiBackup
    let baseline: BeiLibrary
    let additions: [Passage]
    let duplicates: Int
    let conflicts: Int

    init(backup: BeiBackup, current: BeiLibrary) throws {
        _ = try backup.library.validated()
        _ = try current.validated()
        self.backup = backup; baseline = current
        let existing = Dictionary(uniqueKeysWithValues: current.passages.map { ($0.id, $0) })
        var additions: [Passage] = [], duplicates = 0, conflicts = 0
        for passage in backup.library.passages {
            if let local = existing[passage.id] {
                if local.hasSameContent(as: passage) { duplicates += 1 } else { conflicts += 1 }
            } else { additions.append(passage) }
        }
        self.additions = additions; self.duplicates = duplicates; self.conflicts = conflicts
    }

    func merged(current: BeiLibrary, useSettings: Bool) throws -> BeiLibrary {
        guard current == baseline else { throw BeiError.invalid("课文库已改变，请重新选择备份并预览。") }
        var merged = current
        merged.passages += additions
        if useSettings { merged.preferences = backup.library.preferences }
        return try merged.validated()
    }
}

struct BeiLibraryFile {
    let url: URL
    func load() throws -> BeiLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return BeiLibrary() }
        return try JSONDecoder().decode(BeiLibrary.self, from: Data(contentsOf: url)).validated()
    }
    func save(_ library: BeiLibrary) throws {
        _ = try library.validated()
        let data = try JSONEncoder().encode(library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
