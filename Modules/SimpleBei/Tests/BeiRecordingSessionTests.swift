import Foundation
import Testing
@testable import SimpleBei

@MainActor
private final class RecordingDriverFixture: BeiRecordingAudioDriver {
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    var recordings: [URL] = []
    var replays: [URL] = []
    var microphoneRunning = false
    var playbackRunning = false
    var recordFailure = false
    var replayFailure = false
    var waitForPermission = false
    var permission: CheckedContinuation<Void, Never>?
    var releaseCount = 0
    func record(to url: URL) async throws {
        if waitForPermission { await withCheckedContinuation { permission = $0 } }
        try Task.checkCancellation()
        if recordFailure { throw BeiError.invalid("fixture recording failure") }
        try Data("recording fixture".utf8).write(to: url)
        recordings.append(url); microphoneRunning = true
    }
    func finishRecording() throws { microphoneRunning = false }
    func pauseRecording() { microphoneRunning = false }
    func resumeRecording() throws { microphoneRunning = true }
    func play(from url: URL) async throws {
        if replayFailure { throw BeiError.invalid("fixture playback failure") }
        #expect(!microphoneRunning)
        #expect(FileManager.default.fileExists(atPath: url.path))
        replays.append(url); playbackRunning = true
    }
    func stopPlayback() { playbackRunning = false }
    func stopImmediately() { microphoneRunning = false; playbackRunning = false }
    func release() async { releaseCount += 1 }
}

@MainActor
struct BeiRecordingSessionTests {
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Recording workflow did not reach the expected state")
    }
    private func fixtures() -> (URL, BeiSessionFiles, RecordingDriverFixture, BeiRecordingSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = BeiSessionFiles(root: root)
        let driver = RecordingDriverFixture()
        return (root, files, driver, BeiRecordingSession(audio: driver, files: { files }))
    }

    @Test func finishAutomaticallyReplaysTheSameFileAndKeepsOriginalVisibleAfterPlayback() async throws {
        let (root, _, driver, session) = fixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!session.showsOriginal)
        session.start(); #expect(!session.showsOriginal)
        try await eventually { session.state == .recording }
        #expect(!session.showsOriginal && driver.microphoneRunning)
        session.finish()
        try await eventually { driver.replays.count == 1 }
        #expect(session.showsOriginal && driver.replays == driver.recordings)
        driver.onPlaybackFinished?()
        try await eventually { !session.playing }
        #expect(session.showsOriginal && session.state == .review)
        #expect(FileManager.default.fileExists(atPath: driver.recordings[0].path))
        await session.endAndWait()
        #expect(session.state == .idle && !session.showsOriginal)
        #expect(FileManager.default.fileExists(atPath: driver.recordings[0].path))
    }

    @Test func newAttemptStopsPlaybackHidesAnswerAndDeletesPreviousFileBeforeRecording() async throws {
        let (root, _, driver, session) = fixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        session.start(); try await eventually { session.state == .recording }
        session.finish(); try await eventually { driver.playbackRunning }
        let previous = driver.recordings[0]
        session.start()
        #expect(!session.showsOriginal && !driver.playbackRunning)
        try await eventually { driver.recordings.count == 2 }
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        await session.endAndWait()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func latestFileIsReplacedAcrossSeparatePassageSessions() async throws {
        let (root, files, firstDriver, first) = fixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        first.start(); try await eventually { first.state == .recording }
        first.finish(); try await eventually { firstDriver.playbackRunning }
        await first.endAndWait()
        let old = firstDriver.recordings[0]
        let nextDriver = RecordingDriverFixture()
        let next = BeiRecordingSession(audio: nextDriver, files: { files })
        next.start(); try await eventually { next.state == .recording }
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        await next.endAndWait()
    }

    @Test func cancellingWhilePermissionPendingNeverStartsTheMicrophone() async throws {
        let (root, _, driver, session) = fixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        driver.waitForPermission = true
        session.start(); try await eventually { driver.permission != nil }
        session.end()
        #expect(session.state == .stopping && !session.showsOriginal)
        driver.permission?.resume(); driver.permission = nil
        await session.endAndWait()
        #expect(session.state == .idle && !driver.microphoneRunning && driver.recordings.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func recordingFailureCleansAttemptAndAllowsRetry() async throws {
        let (root, _, driver, session) = fixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        driver.recordFailure = true
        session.start(); try await eventually { session.state == .idle }
        #expect(session.error != nil && !session.showsOriginal)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        driver.recordFailure = false
        session.start(); try await eventually { session.state == .recording }
        #expect(session.error == nil && driver.recordings.count == 1)
        await session.endAndWait()
    }

    @Test func playbackFailurePreservesRecordingForReplayRetry() async throws {
        let (root, _, driver, session) = fixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        session.start(); try await eventually { session.state == .recording }
        driver.replayFailure = true; session.finish()
        try await eventually { session.error != nil }
        #expect(session.showsOriginal && !session.playing)
        #expect(FileManager.default.fileExists(atPath: driver.recordings[0].path))
        driver.replayFailure = false; session.replay()
        try await eventually { driver.playbackRunning }
        await session.endAndWait()
    }

    @Test func inactivePausesWithoutRevealingOriginalAndBackgroundCancelsUnfinishedRecording() async throws {
        let (root, _, driver, session) = fixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        session.start(); try await eventually { session.state == .recording }
        session.sceneChanged("inactive")
        #expect(session.state == .recordingPaused && !driver.microphoneRunning && !session.showsOriginal)
        session.sceneChanged("active"); session.resume()
        #expect(session.state == .recording && driver.microphoneRunning)
        session.sceneChanged("background")
        #expect(!driver.microphoneRunning && !session.showsOriginal)
        await session.endAndWait()
        #expect(session.state == .idle && session.notice != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func failedReplacementCleanupBlocksNewRecordingUntilRetry() async throws {
        let (root, files, driver, _) = fixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        var cleanupBlocked = false
        let session = BeiRecordingSession(audio: driver, files: {
            if cleanupBlocked { throw BeiError.invalid("fixture cleanup failure") }
            return files
        })
        session.start(); try await eventually { session.state == .recording }
        session.finish(); try await eventually { driver.playbackRunning }
        cleanupBlocked = true; session.start()
        try await eventually { session.state == .cleanupFailed }
        #expect(driver.recordings.count == 1 && !session.showsOriginal)
        session.start(); #expect(session.state == .cleanupFailed)
        cleanupBlocked = false; await session.endAndWait()
        session.start(); try await eventually { driver.recordings.count == 2 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        await session.endAndWait()
    }
}
