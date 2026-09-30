import AVFoundation
import Foundation

extension Notification.Name {
    public static let simpleXueAudioOwnerChanged = Notification.Name("SimpleXue.AudioOwnerChanged")
}

@MainActor
public final class AudioPlaybackCoordinator {
    public enum Configuration { case playback, recording }
    public static let shared = AudioPlaybackCoordinator()
    private var ownership = AudioOwnership()
    private var serial: UInt64 = 0
    private var operation: Task<Void, Never>?
    public var owner: String? { ownership.owner }
    public func owns(_ value: String) -> Bool { ownership.owner == value }

    public func selectOwner(_ value: String?) {
        guard ownership.owner != value else { return }
        ownership.select(value)
        serial &+= 1
        NotificationCenter.default.post(name: .simpleXueAudioOwnerChanged, object: nil)
        if value == nil { queueRelease(expectedOwner: nil) }
    }

    public func activate(owner: String, duckOthers: Bool = false, configuration: Configuration = .playback) async throws -> Bool {
        guard owns(owner) else { return false }
        serial &+= 1
        let expectedSerial = serial
        let revision = ownership.revision
        let previous = operation
        let task = Task { @MainActor [weak self] () throws -> Bool in
            await previous?.value
            guard let self, self.serial == expectedSerial, self.ownership.permits(owner, revision: revision) else { return false }
            let audio = AVAudioSession.sharedInstance()
            switch configuration {
            case .playback:
                try audio.setCategory(.playback, mode: .spokenAudio, options: duckOthers ? [.duckOthers] : [])
            case .recording:
                try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            }
            let activated = try await audio.activate(options: [])
            return activated && self.serial == expectedSerial && self.ownership.permits(owner, revision: revision)
        }
        // The queue waits even when a caller cancels, so a stale activation cannot overtake its successor.
        operation = Task { _ = try? await task.value }
        return try await task.value
    }

    @discardableResult public func release(owner: String) -> Task<Void, Never>? {
        guard owns(owner) else { return nil }
        return queueRelease(expectedOwner: owner)
    }

    @discardableResult private func queueRelease(expectedOwner: String?) -> Task<Void, Never> {
        serial &+= 1
        let expectedSerial = serial
        let previous = operation
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.serial == expectedSerial, self.owner == expectedOwner else { return }
            do { _ = try await AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation]) }
            catch {
                #if DEBUG
                print("[SimpleXueAudio] 音频释放失败：\(error.localizedDescription)")
                #endif
            }
        }
        operation = task
        return task
    }
}
