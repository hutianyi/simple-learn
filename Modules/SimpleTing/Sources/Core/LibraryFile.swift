import Foundation

struct LibraryFile {
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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let safety = folder.appendingPathComponent("SafetyBackups", isDirectory: true)
            try FileManager.default.createDirectory(at: safety, withIntermediateDirectories: true)
            try Data(contentsOf: url).write(to: safety.appendingPathComponent("BeforeChange-\(UUID().uuidString).json"), options: .atomic)
        }
        try writer(data, url)
    }
}
