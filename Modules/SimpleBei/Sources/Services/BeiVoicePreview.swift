import AVFoundation
import Foundation
import Observation
import StudyShell

private final class BeiNotificationBag {
    var tokens: [NSObjectProtocol] = []
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

@MainActor @Observable
final class BeiVoicePreview: NSObject, AVSpeechSynthesizerDelegate {
    enum State { case idle, preparing, speaking, stopping }
    private(set) var state: State = .idle
    private(set) var error: String?
    var active: Bool { state != .idle }
    var canStart: Bool { state == .idle }
    var voices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices() }
    static func isRequestedVoice(_ voice: AVSpeechSynthesisVoice, language: PassageLanguage) -> Bool {
        BeiVoiceResolver.candidates(language).contains { $0.identifier == voice.identifier }
    }
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private let notifications = BeiNotificationBag()

    override init() {
        super.init()
        synthesizer.delegate = self; synthesizer.usesApplicationAudioSession = true
        for name in [AVAudioSession.didBecomeInactiveNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification, .simpleXueAudioOwnerChanged] {
            notifications.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let stop: Bool
                if notification.name == AVAudioSession.didBecomeInactiveNotification {
                    let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                    stop = context?.source != .app
                } else if notification.name == AVAudioSession.routeChangeNotification {
                    stop = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                } else { stop = true }
                Task { @MainActor in
                    guard let self, self.active else { return }
                    if notification.name == .simpleXueAudioOwnerChanged, AudioPlaybackCoordinator.shared.owns("bei") { return }
                    if stop { self.end() }
                }
            })
        }
    }

    func audition(text: String, language: PassageLanguage, voiceID: String?, rate: Float) {
        guard canStart else { return }
        guard let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID), Self.isRequestedVoice(voice, language: language) else {
            error = "请先选择设备可调用的语舒或 Zoe 声音，声音缺失时不会自动换声。"; return
        }
        state = .preparing; error = nil
        let token = UUID(); generation = token
        work = Task {
            do {
                let activated = try await AudioPlaybackCoordinator.shared.activate(owner: "bei")
                try Task.checkCancellation()
                guard generation == token, activated else { throw BeiError.invalid("无法取得当前模块的音频使用权。") }
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = voice; utterance.rate = rate
                currentUtterance = utterance
                state = .speaking; synthesizer.speak(utterance)
            } catch { await fail(error, token: token) }
        }
    }

    func sceneChanged(_ phase: String) {
        if phase == "background", active { end() }
    }
    func end() {
        guard state != .stopping else { return }
        generation = UUID(); state = .stopping
        let previous = work; previous?.cancel()
        synthesizer.stopSpeaking(at: .immediate); currentUtterance = nil
        work = Task {
            await previous?.value
            await AudioPlaybackCoordinator.shared.release(owner: "bei")?.value
            state = .idle
        }
    }
    private func fail(_ failure: Error, token: UUID) async {
        guard generation == token else { return }
        if !(failure is CancellationError) { error = failure.localizedDescription }
        state = .stopping
        synthesizer.stopSpeaking(at: .immediate); currentUtterance = nil
        await AudioPlaybackCoordinator.shared.release(owner: "bei")?.value
        state = .idle
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .speaking, self.currentUtterance === utterance else { return }
            self.end()
        }
    }
}
