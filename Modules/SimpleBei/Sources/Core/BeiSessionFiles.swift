import Foundation

struct BeiSessionFiles {
    let root: URL
    static func applicationFiles() throws -> BeiSessionFiles {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return BeiSessionFiles(root: caches.appendingPathComponent("SimpleXue/SimpleBei/RecitationSessions", isDirectory: true))
    }
    func prepare(_ id: UUID) throws -> URL {
        var directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        return directory.appendingPathComponent("Recording.caf")
    }
    func prepareLatest(_ id: UUID) throws -> URL {
        try cleanResiduals()
        return try prepare(id)
    }
    func remove(_ id: UUID) throws {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func cleanResiduals() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        // Never walk Caches or other modules; only remove UUID session children of this dedicated root.
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: child.lastPathComponent) != nil else { continue }
            try FileManager.default.removeItem(at: child)
        }
    }
}
