import XCTest
@testable import StudyShell

@MainActor
final class WholeBackupTests: XCTestCase {
    private final class Store {
        var values = ["a": Data("old-a".utf8), "b": Data("old-b".utf8)]
        var failImport = false
        var failRollback = false
        var writes: [String] = []
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WholeBackupTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func coordinator(_ store: Store, directory: URL) -> WholeBackupCoordinator {
        WholeBackupCoordinator(endpoints: ["a", "b"].map { id in
            WholeBackupEndpoint(id: id, title: id, export: { store.values[id]! }, validate: { data in
                guard String(data: data, encoding: .utf8) != "invalid" else { throw WholeBackupError.message("invalid") }
                return String(data: data, encoding: .utf8)!
            }, restore: { data in
                store.writes.append(id)
                if id == "b", store.failImport, data == Data("new-b".utf8) { throw WholeBackupError.message("write failed") }
                if id == "a", store.failRollback, data == Data("old-a".utf8) { throw WholeBackupError.message("rollback failed") }
                store.values[id] = data
            })
        }, directory: directory)
    }
    private var incoming: WholeBackupEnvelope {
        WholeBackupEnvelope(appVersion: "1", modules: ["a": Data("new-a".utf8), "b": Data("new-b".utf8)])
    }
    func testRoundTripIncludesEmptyModulesAndDate() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(); store.values["b"] = Data()
        let service = coordinator(store, directory: folder)
        let backup = try await service.snapshot(appVersion: "1")
        let decoded = try WholeBackupEnvelope.decode(backup.encoded())
        XCTAssertEqual(decoded.modules, store.values)
        XCTAssertEqual(decoded.appVersion, "1")
        XCTAssertEqual(try service.preview(decoded).count, 2)
    }
    func testIncompleteOrInvalidModuleDoesNotWrite() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(); let original = store.values
        let service = coordinator(store, directory: folder)
        for modules in [["a": Data()], ["a": Data(), "b": Data("invalid".utf8)], ["a": Data(), "b": Data(), "other": Data()]] {
            do {
                try await service.restore(WholeBackupEnvelope(appVersion: "1", modules: modules), appVersion: "1")
                XCTFail("Expected rejection")
            } catch {}
        }
        XCTAssertEqual(store.values, original)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertFalse(try service.hasPendingRecovery())
    }
    func testWrongAppOrFutureVersionRejected() throws {
        for (app, version) in [("Other", 1), ("SimpleXue", 99)] {
            var backup = incoming; backup.app = app; backup.formatVersion = version
            XCTAssertThrowsError(try WholeBackupEnvelope.decode(backup.encoded()))
        }
    }
    func testSuccessfulRestorePreservesSafetyCopy() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(); let original = store.values
        let service = coordinator(store, directory: folder)
        try await service.restore(incoming, appVersion: "1")
        XCTAssertEqual(store.values, incoming.modules)
        XCTAssertFalse(try service.hasPendingRecovery())
        let safety = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("PreRestore-") }!
        XCTAssertEqual(try WholeBackupEnvelope.decode(Data(contentsOf: safety)).modules, original)
    }
    func testPartialFailureRollsEveryModuleBack() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(); store.failImport = true; let original = store.values
        let service = coordinator(store, directory: folder)
        do { try await service.restore(incoming, appVersion: "1"); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(store.values, original)
        XCTAssertEqual(store.writes, ["a", "b", "a", "b"])
        XCTAssertFalse(try service.hasPendingRecovery())
    }
    func testFailedRollbackRemainsRecoverableAcrossRestart() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(); store.failImport = true; store.failRollback = true; let original = store.values
        let service = coordinator(store, directory: folder)
        do { try await service.restore(incoming, appVersion: "1"); XCTFail("Expected failure") } catch {}
        XCTAssertTrue(try service.hasPendingRecovery())
        // b is rolled back even when a failed; restart must retry both.
        XCTAssertEqual(store.values["b"], original["b"])
        store.failRollback = false
        let restarted = coordinator(store, directory: folder)
        let recovered = try await restarted.recoverIfNeeded()
        XCTAssertTrue(recovered)
        XCTAssertEqual(store.values, original)
        XCTAssertFalse(try restarted.hasPendingRecovery())
        let secondRecovery = try await restarted.recoverIfNeeded()
        XCTAssertFalse(secondRecovery)
    }
    func testInterruptedRestoreRecoversBeforeNewSnapshot() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(); let original = store.values
        let service = coordinator(store, directory: folder)
        let backup = try await service.snapshot(appVersion: "1")
        try backup.encoded().write(to: folder.appendingPathComponent("PreRestore-interrupted.json"))
        try Data("{\"safetyFilename\":\"PreRestore-interrupted.json\",\"pending\":true}".utf8)
            .write(to: folder.appendingPathComponent("RestoreJournal.json"))
        store.values["a"] = incoming.modules["a"]
        do { _ = try await service.snapshot(appVersion: "1"); XCTFail("Expected pending recovery rejection") } catch {}
        let recovered = try await service.recoverIfNeeded()
        XCTAssertTrue(recovered)
        XCTAssertEqual(store.values, original)
    }
    func testCorruptJournalBlocksRecovery() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{\"safetyFilename\":\"../private.json\",\"pending\":true}".utf8)
            .write(to: folder.appendingPathComponent("RestoreJournal.json"))
        let store = Store(); let service = coordinator(store, directory: folder)
        XCTAssertThrowsError(try service.hasPendingRecovery())
        do { _ = try await service.recoverIfNeeded(); XCTFail("Expected rejection") } catch {}
        XCTAssertTrue(store.writes.isEmpty)
    }
}
