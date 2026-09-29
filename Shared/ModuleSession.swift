import Combine
import Foundation

@MainActor
public final class ModuleSession: ObservableObject {
    @Published public private(set) var reasons: Set<String> = []
    public var canLeave: Bool { reasons.isEmpty }
    public init() {}

    public func setBusy(_ busy: Bool, reason: String) {
        if busy { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}

public enum ModuleStorage {
    public static func directory(_ module: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let url = base.appendingPathComponent("SimpleXue", isDirectory: true)
            .appendingPathComponent(module, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func saveSafetyBackup(_ data: Data, module: String) throws {
        let folder = try directory(module).appendingPathComponent("SafetyBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("PreRestore-\(UUID().uuidString).json"), options: .atomic)
    }
}
