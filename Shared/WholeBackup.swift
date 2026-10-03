import Foundation

public enum WholeBackupError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct WholeBackupEnvelope: Codable {
    public var app = "SimpleXue"
    public var formatVersion = 1
    public let exportedAt: Date
    public let appVersion: String
    public let modules: [String: Data]

    public init(exportedAt: Date = Date(), appVersion: String, modules: [String: Data]) {
        self.exportedAt = exportedAt; self.appVersion = appVersion; self.modules = modules
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Self.self, from: data)
        guard backup.app == "SimpleXue", backup.formatVersion == 1 else {
            throw WholeBackupError.message("这不是受支持的简单学整体备份。请选择整体备份文件。")
        }
        return backup
    }
}

@MainActor
public struct WholeBackupEndpoint {
    public let id: String
    public let title: String
    public let export: () async throws -> Data
    public let validate: (Data) throws -> String
    public let restore: (Data) async throws -> Void
    public init(id: String, title: String, export: @escaping () async throws -> Data,
                validate: @escaping (Data) throws -> String, restore: @escaping (Data) async throws -> Void) {
        self.id = id; self.title = title; self.export = export; self.validate = validate; self.restore = restore
    }
}

// A durable pre-restore snapshot allows rollback even after the app is interrupted.
@MainActor
public final class WholeBackupCoordinator {
    private struct Journal: Codable {
        let safetyFilename: String
        let pending: Bool
    }
    private let endpoints: [WholeBackupEndpoint]
    private let directory: URL
    private var journalURL: URL { directory.appendingPathComponent("RestoreJournal.json") }
    public init(endpoints: [WholeBackupEndpoint], directory: URL) {
        self.endpoints = endpoints; self.directory = directory
    }
    public func preview(_ backup: WholeBackupEnvelope) throws -> [String] {
        guard backup.app == "SimpleXue", backup.formatVersion == 1 else {
            throw WholeBackupError.message("这不是受支持的简单学整体备份。")
        }
        guard Set(backup.modules.keys) == Set(endpoints.map(\.id)), endpoints.count == backup.modules.count else {
            throw WholeBackupError.message("整体备份必须完整包含六个模块，文件缺少模块或包含不支持的模块。")
        }
        return try endpoints.map { endpoint in
            do { return "\(endpoint.title)：\(try endpoint.validate(backup.modules[endpoint.id]!))" }
            catch { throw WholeBackupError.message("\(endpoint.title)备份校验失败：\(error.localizedDescription)") }
        }
    }
    public func snapshot(appVersion: String) async throws -> WholeBackupEnvelope {
        guard try !hasPendingRecovery() else { throw WholeBackupError.message("请先完成上次恢复的回退。") }
        var modules: [String: Data] = [:]
        for endpoint in endpoints {
            do {
                let data = try await endpoint.export()
                _ = try endpoint.validate(data)
                modules[endpoint.id] = data
            } catch { throw WholeBackupError.message("\(endpoint.title)导出失败：\(error.localizedDescription)") }
        }
        return WholeBackupEnvelope(appVersion: appVersion, modules: modules)
    }
    public func hasPendingRecovery() throws -> Bool {
        try readJournal()?.pending ?? false
    }
    public func recoverIfNeeded() async throws -> Bool {
        guard let journal = try readJournal(), journal.pending else { return false }
        let backup = try WholeBackupEnvelope.decode(Data(contentsOf: directory.appendingPathComponent(journal.safetyFilename)))
        _ = try preview(backup)
        try await rollback(backup)
        try writeJournal(Journal(safetyFilename: journal.safetyFilename, pending: false))
        return true
    }
    public func restore(_ backup: WholeBackupEnvelope, appVersion: String) async throws {
        _ = try preview(backup) // Validate every module before changing any data.
        let previous = try await snapshot(appVersion: appVersion)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "PreRestore-\(UUID().uuidString).json"
        try previous.encoded().write(to: directory.appendingPathComponent(filename), options: .atomic)
        try writeJournal(Journal(safetyFilename: filename, pending: true))
        do {
            for endpoint in endpoints {
                do { try await endpoint.restore(backup.modules[endpoint.id]!) }
                catch { throw WholeBackupError.message("\(endpoint.title)恢复失败：\(error.localizedDescription)") }
            }
            try writeJournal(Journal(safetyFilename: filename, pending: false))
        } catch {
            let failure = error.localizedDescription
            do {
                try await rollback(previous)
                try writeJournal(Journal(safetyFilename: filename, pending: false))
            } catch {
                throw WholeBackupError.message("恢复失败：\(failure)\n自动回退尚未完成：\(error.localizedDescription)\n已保留恢复前整体备份。请重试回退，完成前不能进入学习模块。")
            }
            throw WholeBackupError.message("恢复失败，已回退到恢复前的数据：\(failure)")
        }
    }
    private func rollback(_ backup: WholeBackupEnvelope) async throws {
        var failures: [String] = []
        // Attempt every module, even when one rollback fails. Pending journal stays for retry.
        for endpoint in endpoints {
            do { try await endpoint.restore(backup.modules[endpoint.id]!) }
            catch { failures.append("\(endpoint.title)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw WholeBackupError.message(failures.joined(separator: "\n")) }
    }
    private func readJournal() throws -> Journal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard journal.safetyFilename.hasPrefix("PreRestore-"), journal.safetyFilename.hasSuffix(".json"),
              !journal.safetyFilename.contains("/"), !journal.safetyFilename.contains("..") else {
            throw WholeBackupError.message("恢复记录无效，请保留 App 数据并检查恢复前安全备份。")
        }
        return journal
    }
    private func writeJournal(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }
}
