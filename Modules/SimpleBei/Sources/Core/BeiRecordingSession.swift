import Foundation
import Observation

@MainActor
protocol BeiRecordingAudioDriver: AnyObject {
    var onPlaybackFinished: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onInterruption: (() -> Void)? { get set }
    func record(to url: URL) async throws
    func finishRecording() throws
    func pauseRecording()
    func resumeRecording() throws
    func play(from url: URL) async throws
    func stopPlayback()
    func stopImmediately()
    func release() async
}

@MainActor @Observable
final class BeiRecordingSession {
    enum State { case idle, preparing, recording, recordingPaused, finishing, review, stopping, cleanupFailed }
    private(set) var state: State = .idle
    private(set) var playing = false
    private(set) var error: String?
    private(set) var notice: String?
    var active: Bool { state != .idle }
    var showsOriginal: Bool { state == .review }
    private let audio: any BeiRecordingAudioDriver
    private let files: () throws -> BeiSessionFiles
    private var recordingURL: URL?
    private var completed = false
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var foreground = true

    init(audio: any BeiRecordingAudioDriver, files: @escaping () throws -> BeiSessionFiles = BeiSessionFiles.applicationFiles) {
        self.audio = audio; self.files = files
        audio.onPlaybackFinished = { [weak self] in self?.stopReplay() }
        audio.onFailure = { [weak self] message in
            guard let self, self.active else { return }
            self.error = message
            self.end()
        }
        audio.onInterruption = { [weak self] in
            guard let self, self.active else { return }
            self.notice = "录音或回听已中断，请重新开始。"
            self.end()
        }
    }

    func start() {
        guard foreground, state == .idle || state == .review else { return }
        // Hide the answer and stop playback before any permission or cleanup awaits.
        let previous = work; previous?.cancel()
        audio.stopImmediately(); playing = false
        state = .preparing; error = nil; notice = nil; completed = false
        let token = UUID(); generation = token
        work = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                // Replacement is global across passages: remove the old file before creating the next.
                let url = try files().prepareLatest(UUID())
                recordingURL = url
                try await audio.record(to: url)
                try Task.checkCancellation()
                guard generation == token else { return }
                if foreground { state = .recording }
                else { audio.pauseRecording(); state = .recordingPaused }
            } catch { await fail(error, token: token) }
        }
    }

    func finish() {
        guard state == .recording || state == .recordingPaused else { return }
        state = .finishing
        do {
            try audio.finishRecording()
            completed = true; state = .review
            replay()
        } catch {
            let token = generation
            work = Task { await fail(error, token: token) }
        }
    }

    func replay() {
        guard foreground, state == .review, !playing, let recordingURL else { return }
        let previous = work
        let token = generation; playing = true; error = nil
        work = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                try await audio.play(from: recordingURL)
                try Task.checkCancellation()
            } catch {
                guard generation == token else { return }
                audio.stopPlayback()
                await audio.release()
                guard generation == token else { return }
                playing = false
                if !(error is CancellationError) { self.error = "回听失败：\(error.localizedDescription)" }
            }
        }
    }

    func stopReplay() {
        guard playing else { return }
        audio.stopPlayback()
        let previous = work; previous?.cancel()
        let token = generation
        work = Task {
            await previous?.value
            await audio.release()
            if generation == token { playing = false }
        }
    }

    func resume() {
        guard foreground, state == .recordingPaused else { return }
        do { try audio.resumeRecording(); state = .recording }
        catch { self.error = error.localizedDescription; end() }
    }

    func sceneChanged(_ phase: String) {
        foreground = phase == "active"
        if phase == "inactive", state == .recording {
            audio.pauseRecording(); state = .recordingPaused
        } else if phase == "background", active {
            notice = "切到后台或锁屏后，本次背诵已结束。请重新开始。"
            end()
        }
    }

    func end() {
        guard state != .stopping else { return }
        generation = UUID(); state = .stopping
        let previous = work; previous?.cancel()
        audio.stopImmediately(); playing = false
        work = Task {
            await previous?.value
            await audio.release()
            await finishEnd()
        }
    }

    func endAndWait() async {
        if state != .idle && state != .stopping { end() }
        await work?.value
    }

    private func finishEnd() async {
        do {
            // Keep only a completed latest recording; abandoned attempts must not survive.
            if !completed { try files().cleanResiduals(); recordingURL = nil }
            state = .idle
        } catch {
            self.error = "录音清理失败，请重试：\(error.localizedDescription)"; state = .cleanupFailed
        }
    }

    private func fail(_ failure: Error, token: UUID) async {
        guard generation == token else { return }
        if !(failure is CancellationError) { error = failure.localizedDescription }
        state = .stopping; audio.stopImmediately(); playing = false; completed = false
        await audio.release()
        guard generation == token else { return }
        await finishEnd()
    }
}
