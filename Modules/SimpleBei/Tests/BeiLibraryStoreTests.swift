import Foundation
import Testing
@testable import SimpleBei

struct BeiLibraryStoreTests {
    @MainActor @Test func failedLoadBlocksSavingAndPreservesCorruptBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library.json"), bytes = Data("broken file".utf8)
        try bytes.write(to: url)
        let store = BeiLibraryStore(directory: root)
        await store.load()
        #expect(!store.isReady)
        #expect(store.loadError != nil)
        let passage = try PassageText.make(title: "新课文", body: "春天来了。", language: .chinese, layout: .prose)
        #expect(await store.save(passage) == false)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(store.library.passages.isEmpty)
        #expect(!store.busy)
    }
    @MainActor @Test func failedSaveDoesNotPublishUnsavedMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = BeiLibraryFile(url: root.appendingPathComponent("Library.json"))
        try file.save(BeiLibrary())
        let store = BeiLibraryStore(directory: root); await store.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let passage = try PassageText.make(title: "新课文", body: "春天来了。", language: .chinese, layout: .prose)
        #expect(await store.save(passage) == false)
        #expect(store.library.passages.isEmpty)
        #expect(try file.load().passages.isEmpty)
        #expect(store.error != nil)
        #expect(!store.busy)
    }
    @MainActor @Test func importSavesSafetyCopyAndCommitsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BeiLibraryStore(directory: root); await store.load()
        let original = store.library
        let passage = try PassageText.make(title: "备份课文", body: "春天来了。", language: .chinese, layout: .prose)
        let incoming = BeiBackup(library: BeiLibrary(passages: [passage]))
        let preview = try BeiImportPreview(backup: incoming, current: original)
        #expect(await store.apply(preview, useSettings: false))
        #expect(store.library.passages == [passage])
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("SafetyBackups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try BeiBackup.decode(Data(contentsOf: #require(backups.first))).library == original)
        let reopened = BeiLibraryStore(directory: root); await reopened.load()
        #expect(reopened.library == store.library)
    }
}
