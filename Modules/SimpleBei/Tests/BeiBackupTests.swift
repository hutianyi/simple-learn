import Foundation
import Testing
@testable import SimpleBei

struct BeiBackupTests {
    private func passage(_ title: String = "课文") throws -> Passage {
        try PassageText.make(title: title, body: "春天来了。小树发芽。", language: .chinese, layout: .prose)
    }
    @MainActor @Test func wholeRestoreReplacesInsteadOfAppendingAndPreservesSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = BeiLibrary(passages: [try passage("旧课文")])
        let file = BeiLibraryFile(url: folder.appendingPathComponent("Library.json"))
        try file.save(old)
        var incoming = BeiLibrary(passages: [try passage("备份课文")])
        incoming.preferences.chineseVoiceID = "test-voice"
        let data = try BeiBackup(library: incoming).encoded()
        try SimpleBeiBackupTransfer.restore(data, directory: folder)
        #expect(try file.load() == incoming)
        #expect(try BeiBackup.decode(SimpleBeiBackupTransfer.exportData(directory: folder)).library == incoming)
        try SimpleBeiBackupTransfer.restore(BeiBackup(library: BeiLibrary()).encoded(), directory: folder)
        #expect(try file.load().passages.isEmpty)
    }

    @Test func backupRoundTripAndPersistentFieldsOnly() throws {
        let library = BeiLibrary(passages: [try passage()])
        let data = try BeiBackup(library: library).encoded()
        #expect(try BeiBackup.decode(data).library == library)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["app", "module", "backupFormatVersion", "library"])
        let saved = try #require(object["library"] as? [String: Any])
        #expect(Set(saved.keys) == ["schemaVersion", "passages", "preferences"])
        let text = String(decoding: data, as: UTF8.self)
        for excluded in ["transcript", "recordingURL", "score", "sessionID", "hintEvents"] { #expect(!text.contains(excluded)) }
    }
    @Test func otherModuleAndFutureVersionsRejected() throws {
        let library = BeiLibrary(passages: [try passage()])
        var wrong = BeiBackup(library: library); wrong.module = "SimpleTing"
        #expect(throws: (any Error).self) { try BeiBackup.decode(wrong.encoded()) }
        wrong.module = "SimpleBei"; wrong.backupFormatVersion = 99
        #expect(throws: (any Error).self) { try BeiBackup.decode(wrong.encoded()) }
        var future = library; future.schemaVersion = 2
        #expect(throws: (any Error).self) { try future.validated() }
    }
    @Test func appendDuplicateAndConflictPreserveLocal() throws {
        let local = try passage(), new = try passage("新增")
        var changed = local; changed.title = "相同编号但不同内容"
        let current = BeiLibrary(passages: [local])
        let conflict = try BeiImportPreview(backup: BeiBackup(library: BeiLibrary(passages: [changed, new])), current: current)
        #expect(conflict.conflicts == 1)
        #expect(conflict.additions.count == 1)
        #expect(try conflict.merged(current: current, useSettings: false).passages == [local, new])
        let duplicate = try BeiImportPreview(backup: BeiBackup(library: current), current: current)
        #expect(duplicate.duplicates == 1)
        #expect(duplicate.additions.isEmpty)
    }
    @Test func sameTextWithDifferentIDsStillAppends() throws {
        let one = try passage(), two = try passage()
        let preview = try BeiImportPreview(backup: BeiBackup(library: BeiLibrary(passages: [two])), current: BeiLibrary(passages: [one]))
        #expect(preview.additions.count == 1)
    }
    @Test func metadataOnlyChangesAreDuplicates() throws {
        let current = BeiLibrary(passages: [try passage()])
        var incoming = current
        incoming.passages[0].editedAt = Date(timeIntervalSince1970: 0)
        incoming.passages[0].contentVersion += 1
        incoming.passages[0].units[0].id = UUID()
        let preview = try BeiImportPreview(backup: BeiBackup(library: incoming), current: current)
        #expect(preview.duplicates == 1)
        #expect(preview.conflicts == 0)
        #expect(try preview.merged(current: current, useSettings: false) == current)
    }
    @Test func settingsRequireExplicitSelectionAndMissingVoicePreserved() throws {
        let current = BeiLibrary()
        var incoming = BeiLibrary(); incoming.preferences.fontSize = 30; incoming.preferences.chineseVoiceID = "Unavailable.Voice"
        let preview = try BeiImportPreview(backup: BeiBackup(library: incoming), current: current)
        #expect(try preview.merged(current: current, useSettings: false).preferences == current.preferences)
        #expect(try preview.merged(current: current, useSettings: true).preferences == incoming.preferences)
    }
    @Test func changedLibraryInvalidatesPreview() throws {
        let current = BeiLibrary()
        let preview = try BeiImportPreview(backup: BeiBackup(library: BeiLibrary(passages: [try passage()])), current: current)
        var changed = current; changed.preferences.fontSize = 30
        #expect(throws: (any Error).self) { try preview.merged(current: changed, useSettings: false) }
    }
    @Test func duplicateIDsAndInvalidPreferencesRejected() throws {
        let p = try passage()
        #expect(throws: (any Error).self) { try BeiLibrary(passages: [p, p]).validated() }
        var library = BeiLibrary(); library.preferences.totalPasses = 0
        #expect(throws: (any Error).self) { try library.validated() }
        library.preferences.totalPasses = nil
        #expect(try library.validated().preferences.totalPasses == nil)
        library.preferences.sentencePause = .infinity
        #expect(throws: (any Error).self) { try library.validated() }
    }
    @Test func corruptFileRemainsIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library.json")
        let badData = Data("not JSON".utf8); try badData.write(to: url)
        #expect(throws: (any Error).self) { try BeiLibraryFile(url: url).load() }
        #expect(try Data(contentsOf: url) == badData)
    }
    @Test func saveReloadAndInvalidSavePreserveExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = BeiLibraryFile(url: root.appendingPathComponent("Library.json"))
        #expect(try file.load().passages.isEmpty)
        let valid = BeiLibrary(passages: [try passage()]); try file.save(valid)
        #expect(try file.load() == valid)
        let data = try Data(contentsOf: file.url)
        var invalid = valid; invalid.schemaVersion = 99
        #expect(throws: (any Error).self) { try file.save(invalid) }
        #expect(try Data(contentsOf: file.url) == data)
    }
    @Test func failedAtomicWriteKeepsOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = BeiLibraryFile(url: root.appendingPathComponent("Library.json"))
        try file.save(BeiLibrary(passages: [try passage()]))
        let previous = try Data(contentsOf: file.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(throws: (any Error).self) { try file.save(BeiLibrary()) }
        #expect(try Data(contentsOf: file.url) == previous)
    }
}
