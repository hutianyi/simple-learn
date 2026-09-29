import AVFoundation
import Combine
import SwiftUI
import UIKit
import StudyShell

@MainActor
final class DictationSession: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase: Equatable { case setup, dictating, finished }

    @Published private(set) var phase: Phase = .setup
    @Published private(set) var currentIndex = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var secondsRemaining = DictationTimingConfiguration.defaultAdvanceAfterSeconds
    @Published private(set) var timing = DictationTimingConfiguration.default

    private struct SpeechItem {
        let text: String
        let language: DictationLanguage
    }

    private var synthesizer = AVSpeechSynthesizer()
    private var audioActivationTask: Task<Void, Never>?
    private var words: [String] = []
    private var speechRate: Float = 0.42
    private var countdown: DictationCountdown?
    private var countdownTask: Task<Void, Never>?
    private var countdownGeneration = 0
    private var isSceneInactive = false
    private var didAnnounceBackground = false
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var lastSpeechItems: [SpeechItem] = []
    private var shouldReplayAfterAudioRecovery = false
    private var speechGeneration = 0
    private var hasStartedCurrentSpeech = false
    private var speechStartWatchdogTask: Task<Void, Never>?
    private var speechRecoveryAttempts = 0
    private var usesAccessibilityVoice = true

    override init() {
        super.init()
        synthesizer.delegate = self
        installAudioSessionObservers()
    }

    deinit {
        audioActivationTask?.cancel()
        audioSessionObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(currentIndex + 1) / Double(totalCount)
    }

    func start(words newWords: [String], shuffled: Bool, rate: Double, timing newTiming: DictationTimingConfiguration) {
        guard !newWords.isEmpty, newTiming.isValid else { return }
        words = shuffled ? newWords.shuffled() : newWords
        totalCount = words.count
        currentIndex = 0
        speechRate = Float(rate)
        timing = newTiming
        phase = .dictating
        isSceneInactive = false
        didAnnounceBackground = false
        speechRecoveryAttempts = 0
        usesAccessibilityVoice = true
        setScreenAwake(true)
        beginCurrentWord()
    }

    func repeatCurrent() {
        guard phase == .dictating, words.indices.contains(currentIndex) else { return }
        speakCurrent()
    }

    func next() {
        guard phase == .dictating else { return }
        if currentIndex + 1 < words.count {
            currentIndex += 1
            beginCurrentWord()
        } else {
            finish()
        }
    }

    func restart() {
        guard !words.isEmpty else { return }
        currentIndex = 0
        phase = .dictating
        isSceneInactive = false
        didAnnounceBackground = false
        speechRecoveryAttempts = 0
        usesAccessibilityVoice = true
        setScreenAwake(true)
        beginCurrentWord()
    }

    func returnToSetup() {
        speechGeneration += 1
        audioActivationTask?.cancel(); audioActivationTask = nil
        lastSpeechItems = []; shouldReplayAfterAudioRecovery = false
        cancelCountdown()
        cancelSpeechStartWatchdog()
        synthesizer.stopSpeaking(at: .immediate)
        phase = .setup
        isSceneInactive = false
        didAnnounceBackground = false
        setScreenAwake(false)
        deactivateAudioSession()
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard phase == .dictating else { return }
        switch scenePhase {
        case .active:
            isSceneInactive = false
            didAnnounceBackground = false
            updateCountdown()
        case .inactive:
            isSceneInactive = true
        case .background:
            isSceneInactive = true
            guard !didAnnounceBackground else { return }
            didAnnounceBackground = true
            speak("默写尚未结束，请返回继续。", language: .chinese, rate: speechRate)
        @unknown default: break
        }
    }

    private func beginCurrentWord() {
        startCountdown()
        speakCurrent()
    }

    private func speakCurrent() {
        guard words.indices.contains(currentIndex) else { return }
        let word = words[currentIndex]
        speak(DictationCore.repeatedSpeechText(for: word), language: DictationCore.language(for: word), rate: speechRate)
    }

    private func startCountdown() {
        cancelCountdown(resetDisplay: false)
        countdown = DictationCountdown(timing: timing)
        secondsRemaining = timing.advanceAfterSeconds
        let generation = countdownGeneration
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.phase == .dictating, self.countdownGeneration == generation else { return }
                self.updateCountdown()
                if self.phase != .dictating || self.countdownGeneration != generation { return }
            }
        }
    }

    private func updateCountdown() {
        guard !isSceneInactive else { return }
        guard var countdown else { return }
        let update = countdown.update()
        self.countdown = countdown
        secondsRemaining = update.secondsRemaining
        if update.shouldRepeatAndWarn { speakReminder() }
        if update.shouldAdvance { next() }
    }

    private func cancelCountdown(resetDisplay: Bool = true) {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        countdownGeneration += 1
        if resetDisplay { secondsRemaining = timing.advanceAfterSeconds }
    }

    private func speakReminder() {
        guard words.indices.contains(currentIndex) else { return }
        let word = words[currentIndex]
        speakSequence([
            SpeechItem(text: "即将自动进入下一个词语", language: .chinese),
            SpeechItem(text: DictationCore.repeatedSpeechText(for: word), language: DictationCore.language(for: word))
        ], rate: speechRate)
    }

    private func finish() {
        cancelCountdown()
        cancelSpeechStartWatchdog()
        phase = .finished
        speak("默写结束", language: .chinese, rate: speechRate)
        setScreenAwake(false)
    }

    private func speak(_ text: String, language: DictationLanguage, rate: Float) {
        speakSequence([SpeechItem(text: text, language: language)], rate: rate)
    }

    private func speakSequence(_ items: [SpeechItem], rate: Float) {
        guard !items.isEmpty, AudioPlaybackCoordinator.shared.owns("mo") else { return }
        lastSpeechItems = items
        speechGeneration += 1
        let generation = speechGeneration
        cancelSpeechStartWatchdog()
        hasStartedCurrentSpeech = false
        synthesizer.stopSpeaking(at: .immediate)
        audioActivationTask?.cancel()
        audioActivationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let activated = try await AudioPlaybackCoordinator.shared.activate(owner: "mo")
                guard !Task.isCancelled, activated, self.speechGeneration == generation,
                      AudioPlaybackCoordinator.shared.owns("mo") else { return }
                for (index, item) in items.enumerated() {
                    let utterance = AVSpeechUtterance(string: item.text)
                    if item.language == .english { utterance.voice = AVSpeechSynthesisVoice(language: item.language.rawValue) }
                    utterance.prefersAssistiveTechnologySettings = self.usesAccessibilityVoice
                    utterance.rate = rate
                    utterance.volume = 1
                    utterance.preUtteranceDelay = index == 0 ? 0.15 : 0.25
                    utterance.postUtteranceDelay = 0.08
                    self.synthesizer.speak(utterance)
                }
                self.scheduleSpeechStartWatchdog(for: generation)
            } catch {
                guard !Task.isCancelled, self.speechGeneration == generation else { return }
                print("[DictationAudio] 音频会话激活失败：\(error.localizedDescription)")
            }
        }
    }

    private func deactivateAudioSession() {
        AudioPlaybackCoordinator.shared.release(owner: "mo")
    }

    private func installAudioSessionObservers() {
        let center = NotificationCenter.default
        audioSessionObservers = [
            center.addObserver(forName: .simpleXueAudioOwnerChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if !AudioPlaybackCoordinator.shared.owns("mo") { self?.returnToSetup() }
                }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in self?.handleAudioSessionInterruption(notification) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in self?.handleAudioRouteChange(notification) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
            }
        ]
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard phase == .dictating else { return }
        guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else { return }

        switch type {
        case .began:
            shouldReplayAfterAudioRecovery = synthesizer.isSpeaking || synthesizer.isPaused
            print("[DictationAudio] 音频中断开始 shouldReplay=\(shouldReplayAfterAudioRecovery)")
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            print("[DictationAudio] 音频中断结束 systemSuggestsResume=\(options.contains(.shouldResume))")
            if shouldReplayAfterAudioRecovery { replayLastSpeechAfterRecovery() }
            shouldReplayAfterAudioRecovery = false
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard phase == .dictating else { return }
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
        print("[DictationAudio] 输出路由改变 reason=\(reason?.rawValue ?? 0) route=\(route)")
        if reason == .oldDeviceUnavailable, synthesizer.isSpeaking {
            shouldReplayAfterAudioRecovery = true
            replayLastSpeechAfterRecovery()
            shouldReplayAfterAudioRecovery = false
        }
    }

    private func handleMediaServicesReset() {
        guard phase == .dictating else { return }
        let shouldReplay = synthesizer.isSpeaking || synthesizer.isPaused
        print("[DictationAudio] 媒体服务已重置 shouldReplay=\(shouldReplay)")
        recreateSpeechSynthesizer()
        if shouldReplay { replayLastSpeechAfterRecovery() }
    }

    private func replayLastSpeechAfterRecovery() {
        guard phase == .dictating, !isSceneInactive, !lastSpeechItems.isEmpty else { return }
        let items = lastSpeechItems
        let rate = speechRate
        synthesizer.stopSpeaking(at: .immediate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.phase == .dictating, !self.isSceneInactive else { return }
            print("[DictationAudio] 恢复后重新朗读当前内容")
            self.speakSequence(items, rate: rate)
        }
    }

    private func scheduleSpeechStartWatchdog(for generation: Int) {
        speechStartWatchdogTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self,
                  self.phase == .dictating,
                  self.speechGeneration == generation,
                  !self.hasStartedCurrentSpeech else { return }
            self.recoverFromSpeechStartTimeout()
        }
    }

    private func cancelSpeechStartWatchdog() {
        speechStartWatchdogTask?.cancel()
        speechStartWatchdogTask = nil
    }

    private func recoverFromSpeechStartTimeout() {
        guard !lastSpeechItems.isEmpty else { return }
        speechRecoveryAttempts += 1
        if speechRecoveryAttempts >= 2, usesAccessibilityVoice {
            usesAccessibilityVoice = false
            speechRecoveryAttempts = 0
            print("[DictationAudio] 系统朗读声音未启动，临时回退到基础系统语音")
        } else {
            print("[DictationAudio] 朗读 2 秒未启动，重建系统语音引擎 attempt=\(speechRecoveryAttempts)")
        }
        recreateSpeechSynthesizer()
        replayLastSpeechAfterRecovery()
    }

    private func recreateSpeechSynthesizer() {
        cancelSpeechStartWatchdog()
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
    }

    private func handleSpeechDidStart() {
        hasStartedCurrentSpeech = true
        speechRecoveryAttempts = 0
        cancelSpeechStartWatchdog()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        print("[DictationAudio] 开始朗读 text=\(utterance.speechString)")
        Task { @MainActor [weak self] in self?.handleSpeechDidStart() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("[DictationAudio] 完成朗读 text=\(utterance.speechString)")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("[DictationAudio] 取消朗读 text=\(utterance.speechString)")
    }

    private func setScreenAwake(_ awake: Bool) {
        UIApplication.shared.isIdleTimerDisabled = awake
    }
}
