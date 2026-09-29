import AVFoundation
import Foundation
import Observation
import StudyShell

struct ListenVoiceOption: Identifiable {
    let id: String
    let name: String
    let language: String
    let quality: String
}

@MainActor @Observable
final class SpeechService: NSObject {
    let playback: PlaybackSession
    let settings: ListenSettings
    private(set) var voices: [ListenVoiceOption] = []
    private(set) var actualVoiceName = ""
    private(set) var voiceNotice: String?
    private(set) var timerMinutes: Int?
    var message: String?
    @ObservationIgnored private var synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    @ObservationIgnored private var utteranceRequestID: UUID?
    @ObservationIgnored private var activationTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var stopWatchdog: Task<Void, Never>?
    @ObservationIgnored private var deadlineMonitor: DispatchSourceTimer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var stopID: UUID?

    init(settings: ListenSettings, library: ListenLibrary) {
        self.settings = settings
        playback = PlaybackSession(order: settings.order, loopEnabled: settings.loopEnabled)
        super.init()
        playback.library = library
        playback.restoreSelection(settings.lastPlayedID)
        settings.lastPlayedID = playback.selectedArticleID
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        refreshVoices()
        observeAudio()
    }

    deinit {
        activationTask?.cancel(); watchdog?.cancel(); stopWatchdog?.cancel()
        deadlineMonitor?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func replaceLibrary(_ library: ListenLibrary) {
        guard !playback.hasSession else { return }
        playback.library = library
        playback.restoreSelection(settings.lastPlayedID)
        settings.lastPlayedID = playback.selectedArticleID
    }

    func refreshVoices() {
        let available = englishVoices()
        voices = available.map { ListenVoiceOption(id: $0.identifier, name: $0.name, language: $0.language,
            quality: $0.quality.rawValue >= 3 ? "Premium" : ($0.quality.rawValue >= 2 ? "Enhanced" : "标准")) }
        if settings.voiceIdentifier.isEmpty {
            settings.voiceIdentifier = (available.first { $0.name.localizedCaseInsensitiveContains("Zoe") } ?? available.first)?.identifier ?? ""
        }
    }

    private func englishVoices() -> [AVSpeechSynthesisVoice] {
        // Restrict to Apple voices; installed third-party speech providers may use their own services.
        AVSpeechSynthesisVoice.speechVoices().filter {
            $0.identifier.hasPrefix("com.apple.") && ($0.language.lowercased().hasPrefix("en-") || $0.language.lowercased() == "en")
        }
            .sorted { $0.quality.rawValue == $1.quality.rawValue ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.quality.rawValue > $1.quality.rawValue }
    }

    func play(_ id: UUID? = nil) {
        guard playback.state != .stopping else { return }
        guard !expireIfNeeded() else { return }
        if let request = playback.begin(id) { perform(request) }
    }

    func togglePlayback() {
        guard !expireIfNeeded() else { return }
        switch playback.state {
        case .playing:
            if synthesizer.pauseSpeaking(at: .immediate) { playback.paused() }
            else { interrupt("朗读已暂停。继续时将从本篇开头播放。") }
        case .paused:
            if utterance != nil, synthesizer.isPaused, synthesizer.continueSpeaking() { playback.resumed() }
            else if let request = playback.restartCurrent() { perform(request) }
        case .stopped: play()
        case .preparing, .stopping: break
        }
    }

    func move(_ delta: Int) {
        guard playback.state != .stopping, !expireIfNeeded() else { return }
        if let request = playback.move(delta) { perform(request) }
        else if playback.state == .stopped { stop() }
    }

    func changeOrder(_ value: PlaybackOrder) { settings.order = value; playback.changeOrder(value) }
    func changeLoop(_ value: Bool) { settings.loopEnabled = value; playback.loopEnabled = value }

    func setSleepTimer(_ minutes: Int?) {
        guard playback.state != .stopping else { return }
        timerMinutes = minutes
        playback.setTimer(minutes: minutes)
        deadlineMonitor?.cancel(); deadlineMonitor = nil
        guard minutes != nil else { return }
        // This monitor belongs to the playback service and continues independently of SwiftUI refreshes.
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(500), leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in Task { @MainActor [weak self] in _ = self?.expireIfNeeded() } }
        deadlineMonitor = source
        source.resume()
    }

    @discardableResult func expireIfNeeded() -> Bool {
        guard playback.expired else { return false }
        message = "定时结束，已停止本次播放。"
        stop(atWordBoundary: true)
        return true
    }

    func stop(atWordBoundary: Bool = false) {
        activationTask?.cancel(); activationTask = nil
        watchdog?.cancel(); watchdog = nil
        stopWatchdog?.cancel()
        deadlineMonitor?.cancel(); deadlineMonitor = nil
        timerMinutes = nil
        playback.beginStopping()
        let id = UUID(); stopID = id
        let boundary: AVSpeechBoundary = atWordBoundary && !synthesizer.isPaused ? .word : .immediate
        let requested = synthesizer.stopSpeaking(at: boundary)
        if !requested || utterance == nil { finishStop(id) }
        else {
            stopWatchdog = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                guard let self, self.stopID == id else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
                self.finishStop(id)
            }
        }
    }

    func returnedToForeground() { refreshVoices(); _ = expireIfNeeded() }

    private func finishStop(_ id: UUID) {
        guard stopID == id else { return }
        stopWatchdog?.cancel(); stopWatchdog = nil
        utterance = nil; utteranceRequestID = nil
        let release = AudioPlaybackCoordinator.shared.release(owner: "ting")
        Task { @MainActor [weak self] in
            await release?.value
            guard let self, self.stopID == id else { return }
            self.stopID = nil
            self.playback.stop()
        }
    }

    private func perform(_ request: SpeechRequest, basicFallback: Bool = false) {
        activationTask?.cancel(); watchdog?.cancel()
        utterance = nil; utteranceRequestID = nil
        synthesizer.stopSpeaking(at: .immediate)
        settings.lastPlayedID = request.item.articleID
        activationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let activated = try await AudioPlaybackCoordinator.shared.activate(owner: "ting")
                guard !Task.isCancelled, self.playback.requestID == request.id else { return }
                guard !self.expireIfNeeded() else { return }
                guard activated else { throw ListenError.message("音频尚未就绪，请停止后重试。") }
                let available = self.englishVoices()
                let preferred = available.first { $0.identifier == self.settings.voiceIdentifier }
                let voice = basicFallback ? available.first { $0.quality.rawValue == 1 } : (preferred ?? available.first)
                guard let voice else { throw ListenError.message("没有可用的英语语音，请在 iPad 系统设置中准备英语声音。") }
                self.actualVoiceName = voice.name
                self.voiceNotice = voice.identifier == self.settings.voiceIdentifier ? nil : "所选声音不可用，本次使用 \(voice.name)（\(voice.language)）。"
                let value = AVSpeechUtterance(string: request.text)
                value.voice = voice
                value.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, self.settings.rate.rate))
                self.utterance = value; self.utteranceRequestID = request.id
                self.synthesizer.speak(value)
                self.watchdog = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    guard let self, self.playback.requestID == request.id, self.playback.state == .preparing else { return }
                    if !basicFallback, available.contains(where: { $0.quality.rawValue == 1 && $0.identifier != voice.identifier }) {
                        self.rebuildSynthesizer()
                        self.perform(request, basicFallback: true)
                    } else { self.message = "系统语音未能开始朗读，请检查英语声音后重试。"; self.stop() }
                }
            } catch {
                guard !Task.isCancelled, self.playback.requestID == request.id else { return }
                self.message = error.localizedDescription
                self.stop()
            }
        }
    }

    private func interrupt(_ text: String) {
        guard playback.state != .stopped, playback.state != .stopping else { return }
        activationTask?.cancel(); watchdog?.cancel()
        playback.interrupt()
        utterance = nil; utteranceRequestID = nil
        synthesizer.stopSpeaking(at: .immediate)
        AudioPlaybackCoordinator.shared.release(owner: "ting")
        message = text
    }

    private func rebuildSynthesizer() {
        utterance = nil; utteranceRequestID = nil
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    private func observeAudio() {
        let center = NotificationCenter.default
        for name in [AVAudioSession.didBecomeInactiveNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                     .simpleXueAudioOwnerChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == .simpleXueAudioOwnerChanged {
                        if !AudioPlaybackCoordinator.shared.owns("ting") { self.stop() }
                    } else if name == AVSpeechSynthesizer.availableVoicesDidChangeNotification { self.refreshVoices() }
                    else if AudioPlaybackCoordinator.shared.owns("ting") {
                        if name == AVAudioSession.didBecomeInactiveNotification,
                           (note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext)?.source != .app {
                            self.interrupt("播放被系统中断。点击继续将从本篇开头播放。")
                        } else if name == AVAudioSession.routeChangeNotification,
                                  (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                            self.interrupt("耳机已断开。点击继续将从本篇开头播放。")
                        } else if name == AVAudioSession.mediaServicesWereResetNotification {
                            self.interrupt("音频服务已重置。点击继续将从本篇开头播放。")
                            self.rebuildSynthesizer()
                        }
                    }
                }
            })
        }
    }

    fileprivate func didStart(_ value: AVSpeechUtterance) {
        guard utterance === value, let id = utteranceRequestID else { return }
        guard !expireIfNeeded() else { return }
        if playback.started(id) { watchdog?.cancel(); watchdog = nil }
    }
    fileprivate func didFinish(_ value: AVSpeechUtterance, cancelled: Bool) {
        guard utterance === value else { return }
        if let stopID { finishStop(stopID); return }
        guard let id = utteranceRequestID else { return }
        utterance = nil; utteranceRequestID = nil
        if cancelled { interrupt("朗读已中断。点击继续将从本篇开头播放。"); return }
        guard !expireIfNeeded() else { return }
        if let next = playback.finished(id) { perform(next) }
        else if playback.state == .stopped { stop() }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.didStart(utterance) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.didFinish(utterance, cancelled: false) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.didFinish(utterance, cancelled: true) }
    }
}
