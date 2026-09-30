import Foundation
import Testing
#if os(macOS)
import Darwin
#endif
@testable import SimpleBei

struct BeiSessionFilesTests {
    @Test func sessionCleanupIsIdempotentAndIsolated() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let files = BeiSessionFiles(root: base.appendingPathComponent("SimpleBei/RecitationSessions"))
        let id = UUID(), other = UUID()
        let recording = try files.prepare(id), otherRecording = try files.prepare(other)
        try Data("temporary recording fixture".utf8).write(to: recording)
        try Data("other current session".utf8).write(to: otherRecording)
        try files.remove(id); try files.remove(id)
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        #expect(FileManager.default.fileExists(atPath: otherRecording.path))
    }
    @Test func residualCleanupDoesNotWalkOtherModulesOrUnknownChildren() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let files = BeiSessionFiles(root: base.appendingPathComponent("SimpleBei/RecitationSessions"))
        let recording = try files.prepare(UUID())
        let otherModule = base.appendingPathComponent("SimpleMo")
        try FileManager.default.createDirectory(at: otherModule, withIntermediateDirectories: true)
        let protected = otherModule.appendingPathComponent("words.json"); try Data("keep".utf8).write(to: protected)
        let unknown = files.root.appendingPathComponent("Unknown"); try Data("keep".utf8).write(to: unknown)
        let symlink = files.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: otherModule)
        try files.cleanResiduals(); try files.cleanResiduals()
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
    }
    @Test func sessionExcludedFromSystemBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try BeiSessionFiles(root: root).prepare(UUID())
        #if os(macOS)
        // In /private/tmp the getter reports false even after Foundation writes Time Machine's exclusion marker.
        let directory = url.deletingLastPathComponent().path
        #expect(getxattr(directory, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) > 0)
        #else
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #endif
    }
}
