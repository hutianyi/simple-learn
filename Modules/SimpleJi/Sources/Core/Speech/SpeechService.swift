import AVFoundation
import Foundation
import StudyShell

@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var speakingText: String?
    @Published private(set) var englishVoices: [SpeechVoiceOption] = []
    @Published private(set) var chineseVoices: [SpeechVoiceOption] = []

    private struct Request {
        let id: UUID
        let text: String
        let language: SpeechLanguage
        let preferredIdentifier: String?
        let rate: Double
        let repetitions: Int
    }

    private var synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var pendingRequest: Request?
    private var remainingRepetitions = 0
    private var completion: (() -> Void)?
    private var didTryBasicFallback = false
    private var activationTask: Task<Void, Never>?
    private let activationOverride: (() async throws -> Bool)?
    private let playbackOverride: ((AVSpeechUtterance) -> Void)?
    private var watchdogTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    init(activation: (() async throws -> Bool)? = nil,
         playback: ((AVSpeechUtterance) -> Void)? = nil) {
        activationOverride = activation
        playbackOverride = playback
        super.init()
        synthesizer.delegate = self
        refreshVoices()
        observeAudioSystem()
    }

    deinit {
        activationTask?.cancel()
        watchdogTask?.cancel()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refreshVoices() {
        englishVoices = VoiceResolver.options(for: .english)
        chineseVoices = VoiceResolver.options(for: .chinese)
    }

    func speak(
        _ text: String,
        language: SpeechLanguage,
        preferredIdentifier: String?,
        rate: Double,
        repetitions: Int = 1,
        onCompletion: (() -> Void)? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop(clearPending: true)
        let request = Request(
            id: UUID(),
            text: trimmed,
            language: language,
            preferredIdentifier: preferredIdentifier,
            rate: min(max(rate, 0.30), 0.62),
            repetitions: max(1, repetitions)
        )
        pendingRequest = request
        remainingRepetitions = request.repetitions
        completion = onCompletion
        didTryBasicFallback = false
        perform(request, forceBasicFallback: false)
    }

    func stop() {
        stop(clearPending: true)
        if activationOverride == nil { AudioPlaybackCoordinator.shared.release(owner: "ji") }
    }

    private func stop(clearPending: Bool) {
        activationTask?.cancel()
        activationTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        activeUtterance = nil
        isSpeaking = false
        speakingText = nil
        if clearPending {
            pendingRequest = nil
            remainingRepetitions = 0
            let finished = completion
            completion = nil
            finished?()
        }
    }

    private func perform(_ request: Request, forceBasicFallback: Bool) {
        activationTask?.cancel()
        watchdogTask?.cancel()
        activationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let activated: Bool
                if let activationOverride = self.activationOverride {
                    activated = try await activationOverride()
                } else {
                    activated = try await self.configureAudioSession()
                }
                // Activation can finish after a stop or after another word replaces this one.
                guard !Task.isCancelled, self.pendingRequest?.id == request.id else { return }
                self.activationTask = nil
                guard activated else {
                    self.reportActivationFailure("Audio session was not activated")
                    self.stop(clearPending: true)
                    return
                }
                self.beginSpeaking(request, forceBasicFallback: forceBasicFallback)
            } catch {
                guard !Task.isCancelled, self.pendingRequest?.id == request.id else { return }
                self.reportActivationFailure(error.localizedDescription)
                self.stop(clearPending: true)
            }
        }
    }

    private func beginSpeaking(_ request: Request, forceBasicFallback: Bool) {
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = VoiceResolver.resolve(
            language: request.language,
            preferredIdentifier: request.preferredIdentifier,
            forceBasicFallback: forceBasicFallback
        )
        utterance.rate = Float(request.rate)
        utterance.pitchMultiplier = 1
        utterance.postUtteranceDelay = remainingRepetitions > 1 ? 0.5 : 0

        speakingText = request.text
        activeUtterance = utterance
        if let playbackOverride {
            playbackOverride(utterance)
        } else {
            synthesizer.speak(utterance)
            startWatchdog(for: request)
        }
    }

    private func startWatchdog(for request: Request) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.pendingRequest?.id == request.id, !self.isSpeaking else { return }

            if !self.didTryBasicFallback {
                self.didTryBasicFallback = true
                self.rebuildSynthesizer()
                self.perform(request, forceBasicFallback: true)
            } else {
                self.stop(clearPending: true)
            }
        }
    }

    private func rebuildSynthesizer() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.delegate = nil
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        activeUtterance = nil
        isSpeaking = false
    }

    private func configureAudioSession() async throws -> Bool {
        try await AudioPlaybackCoordinator.shared.activate(owner: "ji", duckOthers: true)
    }

    private func reportActivationFailure(_ message: String) {
        #if DEBUG
        print("[WordMemorySpeech] Audio session setup failed: \(message)")
        #endif
    }

    private func observeAudioSystem() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .simpleXueAudioOwnerChanged,
            AVAudioSession.mediaServicesWereResetNotification,
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
        ]

        notificationTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == .simpleXueAudioOwnerChanged {
                        if self.activationOverride == nil, !AudioPlaybackCoordinator.shared.owns("ji") { self.stop() }
                        return
                    }
                    guard self.activationOverride != nil || AudioPlaybackCoordinator.shared.owns("ji"),
                          let request = self.pendingRequest else { return }
                    self.rebuildSynthesizer()
                    self.perform(request, forceBasicFallback: self.didTryBasicFallback)
                }
            }
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            self.watchdogTask?.cancel()
            self.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            self.remainingRepetitions -= 1
            if self.remainingRepetitions > 0, let request = self.pendingRequest {
                self.isSpeaking = false
                self.beginSpeaking(request, forceBasicFallback: self.didTryBasicFallback)
                return
            }
            self.stop(clearPending: true)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            self.stop(clearPending: true)
        }
    }
}
