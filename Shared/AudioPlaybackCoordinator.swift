import AVFoundation
import Foundation
import SwiftUI

extension Notification.Name {
    public static let simpleXueAudioOwnerChanged = Notification.Name("SimpleXue.AudioOwnerChanged")
}

@MainActor
private final class CelebrationSound: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var owner: String?
    private var generation = UUID()

    func play(owner: String) async {
        stop()
        let request = generation
        do {
            let sound = try AVAudioPlayer(data: Self.chimeData())
            self.owner = owner
            guard try await AudioPlaybackCoordinator.shared.activate(owner: owner, duckOthers: true),
                  generation == request else {
                if generation == request { stop() }
                return
            }
            player = sound
            sound.delegate = self
            guard sound.play() else {
                stop()
                print("[CelebrationSound] 无法播放庆祝音效")
                return
            }
        } catch {
            if generation == request { stop() }
            print("[CelebrationSound] 音效播放失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        generation = UUID()
        player?.stop()
        player = nil
        if let owner { AudioPlaybackCoordinator.shared.release(owner: owner) }
        owner = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            if !flag { print("[CelebrationSound] 音效播放中断") }
            self?.stop()
        }
    }

    // A short major-key bell arpeggio, generated locally without an audio asset or download.
    private static func chimeData() -> Data {
        let sampleRate = 44_100
        let frameCount = Int(Double(sampleRate) * 1.5)
        let notes = [523.25, 659.25, 783.99, 1046.50]
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + frameCount * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(frameCount * 2))
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            var sample = 0.0
            for (index, frequency) in notes.enumerated() {
                let elapsed = time - Double(index) * 0.18
                guard elapsed >= 0 else { continue }
                let envelope = min(1, elapsed / 0.008) * exp(-elapsed * 5)
                let phase = 2 * Double.pi * frequency * elapsed
                sample += (sin(phase) + 0.2 * sin(2 * phase)) * envelope * 0.18
            }
            let fade = min(1, (1.5 - time) / 0.08)
            append(Int16(max(-1, min(1, sample * fade)) * Double(Int16.max)))
        }
        return data
    }
}

private struct CelebrationSoundModifier: ViewModifier {
    let enabled: Bool
    let owner: String
    @StateObject private var sound = CelebrationSound()
    @State private var played = false
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: enabled) {
                guard enabled, !played, scenePhase == .active else { return }
                played = true
                await sound.play(owner: owner)
            }
            .onDisappear { sound.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { sound.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .simpleXueAudioOwnerChanged)) { _ in
                if !AudioPlaybackCoordinator.shared.owns(owner) { sound.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
                sound.stop()
            }
    }
}

extension View {
    public func celebrationSound(enabled: Bool, owner: String) -> some View {
        modifier(CelebrationSoundModifier(enabled: enabled, owner: owner))
    }
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
