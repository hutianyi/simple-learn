import Foundation

final class PersistenceService {
    static let shared = PersistenceService()
    private let directoryURL: URL
    private var dataURL: URL { directoryURL.appendingPathComponent("data_v1.json") }
    private var backupURL: URL { directoryURL.appendingPathComponent("data_v1_backup.json") }

    init(directoryURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directoryURL = directoryURL ?? base.appendingPathComponent("SimpleXue/SimpleSuan", isDirectory: true)
    }

    func load() throws -> AppData {
        let manager = FileManager.default
        if !manager.fileExists(atPath: dataURL.path) && !manager.fileExists(atPath: backupURL.path) { return AppData() }
        do { return try SuanBackup.decode(Data(contentsOf: dataURL)) }
        catch {
            guard manager.fileExists(atPath: backupURL.path) else { throw error }
            return try SuanBackup.decode(Data(contentsOf: backupURL))
        }
    }

    func save(_ appData: AppData) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try SuanBackup.encode(appData)
        if FileManager.default.fileExists(atPath: dataURL.path) {
            let previous = try Data(contentsOf: dataURL)
            let validPrevious: Bool
            do { _ = try SuanBackup.decode(previous); validPrevious = true }
            catch { validPrevious = false }
            if validPrevious {
                try previous.write(to: backupURL, options: .atomic)
            } else {
                let preserved = directoryURL.appendingPathComponent("CorruptData", isDirectory: true)
                try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)
                try previous.write(to: preserved.appendingPathComponent("Preserved-\(UUID().uuidString).json"), options: .atomic)
            }
        }
        try data.write(to: dataURL, options: .atomic)
    }
}
