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
    public let rawStorage: WholeBackupRawStorage?
    public init(id: String, title: String, export: @escaping () async throws -> Data,
                validate: @escaping (Data) throws -> String, restore: @escaping (Data) async throws -> Void,
                rawStorage: WholeBackupRawStorage? = nil) {
        self.id = id; self.title = title; self.export = export; self.validate = validate; self.restore = restore
        self.rawStorage = rawStorage
    }
}

// Used only when a module cannot produce a validated logical backup. Originals are
// copied before replacement; displaced files are retained instead of being deleted.
public struct WholeBackupRawStorage {
    private let directory: URL
    private let defaultsDomains: [String]
    private let standardKeys: [String]
    public init(directory: URL, defaultsDomains: [String] = [], standardKeys: [String] = []) {
        self.directory = directory; self.defaultsDomains = defaultsDomains; self.standardKeys = standardKeys
    }
    public func preserve(to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let exists: Bool
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw WholeBackupError.message("模块数据位置不是普通文件夹，未继续恢复。")
            }
            exists = true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { exists = false }
        if exists { try manager.copyItem(at: directory, to: destination.appendingPathComponent("Files", isDirectory: true)) }
        var domains: [String: [String: Any]] = [:]
        for name in defaultsDomains {
            guard let defaults = UserDefaults(suiteName: name) else { throw WholeBackupError.message("无法读取模块设置。") }
            if let values = defaults.persistentDomain(forName: name) { domains[name] = values }
        }
        var standard: [String: Any] = [:]
        for key in standardKeys { if let value = UserDefaults.standard.object(forKey: key) { standard[key] = value } }
        let data = try PropertyListSerialization.data(fromPropertyList: ["hasDirectory": exists, "domains": domains, "standard": standard], format: .binary, options: 0)
        try data.write(to: destination.appendingPathComponent("Settings.plist"), options: .atomic)
    }
    public func validate(at source: URL) throws {
        let metadata = try metadata(at: source)
        if metadata.hasDirectory {
            let files = source.appendingPathComponent("Files", isDirectory: true)
            let values = try files.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw WholeBackupError.message("原始数据安全副本不完整。") }
        }
    }
    public func prepareForRestore(using source: URL) throws {
        try validate(at: source)
        try displaceCurrent(into: source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func restore(from source: URL) throws {
        try validate(at: source)
        let values = try metadata(at: source)
        let manager = FileManager.default
        let staged = directory.deletingLastPathComponent().appendingPathComponent("RawRestore-\(UUID().uuidString)", isDirectory: true)
        if values.hasDirectory { try manager.copyItem(at: source.appendingPathComponent("Files"), to: staged) }
        try displaceCurrent(into: source)
        if values.hasDirectory { try manager.moveItem(at: staged, to: directory) }
        for name in defaultsDomains {
            guard let defaults = UserDefaults(suiteName: name) else { throw WholeBackupError.message("无法恢复模块设置。") }
            if let domain = values.domains[name] { defaults.setPersistentDomain(domain, forName: name) }
            else { defaults.removePersistentDomain(forName: name) }
        }
        for key in standardKeys {
            if let value = values.standard[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    private func displaceCurrent(into source: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            try manager.moveItem(at: directory, to: source.appendingPathComponent("Displaced-\(UUID().uuidString)", isDirectory: true))
        }
    }
    private func metadata(at source: URL) throws -> (hasDirectory: Bool, domains: [String: [String: Any]], standard: [String: Any]) {
        let data = try Data(contentsOf: source.appendingPathComponent("Settings.plist"))
        guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let exists = values["hasDirectory"] as? Bool,
              let domains = values["domains"] as? [String: [String: Any]],
              let standard = values["standard"] as? [String: Any],
              Set(domains.keys).isSubset(of: Set(defaultsDomains)), Set(standard.keys).isSubset(of: Set(standardKeys)) else {
            throw WholeBackupError.message("原始数据安全副本的设置无效。")
        }
        return (exists, domains, standard)
    }
}

// A durable pre-restore snapshot allows rollback even after the app is interrupted.
@MainActor
public final class WholeBackupCoordinator {
    private struct Journal: Codable {
        let safetyFilename: String
        let pending: Bool
        var rawModules: [String]? = nil
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
        try validateSafety(backup, journal: journal)
        try await rollback(backup, journal: journal)
        try writeJournal(Journal(safetyFilename: journal.safetyFilename, pending: false, rawModules: journal.rawModules))
        return true
    }
    public func restore(_ backup: WholeBackupEnvelope, appVersion: String) async throws {
        _ = try preview(backup) // Validate every module before changing any data.
        guard try !hasPendingRecovery() else { throw WholeBackupError.message("请先完成上次恢复的回退。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "PreRestore-\(UUID().uuidString).json"
        var modules: [String: Data] = [:]
        var rawModules: [String] = []
        for endpoint in endpoints {
            do {
                let data = try await endpoint.export()
                _ = try endpoint.validate(data)
                modules[endpoint.id] = data
            } catch {
                guard let rawStorage = endpoint.rawStorage else {
                    throw WholeBackupError.message("\(endpoint.title)恢复前备份失败，未改变数据：\(error.localizedDescription)")
                }
                do { try rawStorage.preserve(to: rawDirectory(filename: filename, module: endpoint.id)) }
                catch { throw WholeBackupError.message("\(endpoint.title)原始数据无法完整保留，未继续恢复：\(error.localizedDescription)") }
                rawModules.append(endpoint.id)
            }
        }
        let previous = WholeBackupEnvelope(appVersion: appVersion, modules: modules)
        let journal = Journal(safetyFilename: filename, pending: true, rawModules: rawModules)
        try validateSafety(previous, journal: journal)
        try previous.encoded().write(to: directory.appendingPathComponent(filename), options: .atomic)
        try writeJournal(journal)
        do {
            for endpoint in endpoints {
                do {
                    if rawModules.contains(endpoint.id) {
                        try endpoint.rawStorage!.prepareForRestore(using: rawDirectory(filename: filename, module: endpoint.id))
                    }
                    try await endpoint.restore(backup.modules[endpoint.id]!)
                }
                catch { throw WholeBackupError.message("\(endpoint.title)恢复失败：\(error.localizedDescription)") }
            }
            try writeJournal(Journal(safetyFilename: filename, pending: false, rawModules: rawModules))
        } catch {
            let failure = error.localizedDescription
            do {
                try await rollback(previous, journal: journal)
                try writeJournal(Journal(safetyFilename: filename, pending: false, rawModules: rawModules))
            } catch {
                throw WholeBackupError.message("恢复失败：\(failure)\n自动回退尚未完成：\(error.localizedDescription)\n已保留恢复前整体备份。请重试回退，完成前不能进入学习模块。")
            }
            throw WholeBackupError.message("恢复失败，已回退到恢复前的数据：\(failure)")
        }
    }
    private func rollback(_ backup: WholeBackupEnvelope, journal: Journal) async throws {
        var failures: [String] = []
        // Attempt every module, even when one rollback fails. Pending journal stays for retry.
        for endpoint in endpoints {
            do {
                if (journal.rawModules ?? []).contains(endpoint.id) {
                    try endpoint.rawStorage!.restore(from: rawDirectory(filename: journal.safetyFilename, module: endpoint.id))
                } else { try await endpoint.restore(backup.modules[endpoint.id]!) }
            }
            catch { failures.append("\(endpoint.title)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw WholeBackupError.message(failures.joined(separator: "\n")) }
    }
    private func rawDirectory(filename: String, module: String) -> URL {
        directory.appendingPathComponent(filename + ".raw", isDirectory: true).appendingPathComponent(module, isDirectory: true)
    }
    private func validateSafety(_ backup: WholeBackupEnvelope, journal: Journal) throws {
        let raw = journal.rawModules ?? []
        guard raw.count == Set(raw).count, Set(raw).isDisjoint(with: Set(backup.modules.keys)),
              Set(raw).union(backup.modules.keys) == Set(endpoints.map(\.id)) else {
            throw WholeBackupError.message("恢复前安全副本的模块范围不完整。")
        }
        for endpoint in endpoints {
            if raw.contains(endpoint.id) {
                guard let storage = endpoint.rawStorage else { throw WholeBackupError.message("缺少原始数据回退能力。") }
                try storage.validate(at: rawDirectory(filename: journal.safetyFilename, module: endpoint.id))
            } else { _ = try endpoint.validate(backup.modules[endpoint.id]!) }
        }
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
