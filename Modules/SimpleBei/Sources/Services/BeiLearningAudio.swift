import AVFoundation
import Foundation
import MediaPlayer
import Observation
import StudyShell

private final class BeiAudioNotifications {
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor @Observable
final class BeiLearningAudio: NSObject, AVSpeechSynthesizerDelegate {
    enum State { case idle, preparing, speaking, waiting, paused, stopping }
    enum Kind { case listening, practice }
    private(set) var state: State = .idle
    private(set) var kind = Kind.listening
    private(set) var current = 0
    private(set) var completedPasses = 0
    private(set) var secondsToWait = 0
    private(set) var timerDeadline: Date?
    private(set) var actualVoice = ""
    var error: String?
    var notice: String?
    var active: Bool { state != .idle }
    var isListening: Bool { if case .listening = kind { true } else { false } }
    private var passage: Passage?
    private var preferences = BeiPreferences()
    private var voice: AVSpeechSynthesisVoice?
    private var listeningPlan: BeiPlaybackPlan?
    private var practicePlan: BeiPracticePlan?
    private var synthesizer = AVSpeechSynthesizer()
    private var queued: [ObjectIdentifier: (AVSpeechUtterance, BeiPlaybackPlan)] = [:]
    private var tailPlan: BeiPlaybackPlan?
    private var practiceUtterance: AVSpeechUtterance?
    private var spokenAt: Date?
    private var speechPauseAt: Date?
    private var lastSpokenDuration: Double = 3
    private var waitingDeadline: Date?
    private var pausedFrom = State.idle
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var stopWork: Task<Void, Never>?
    private var clock: DispatchSourceTimer?
    private var remoteSessionID = UUID()
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private let notifications = BeiAudioNotifications()

    override init() {
        super.init(); synthesizer.delegate = self; synthesizer.usesApplicationAudioSession = true
        for name in [AVAudioSession.didBecomeInactiveNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, .simpleXueAudioOwnerChanged] {
            notifications.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let ownRelease = (note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext)?.source == .app
                let unplugged = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                Task { @MainActor in
                    guard let self, self.active else { return }
                    if name == .simpleXueAudioOwnerChanged {
                        if !AudioPlaybackCoordinator.shared.owns("bei") { await self.stop() }
                    } else if name == AVAudioSession.mediaServicesWereResetNotification {
                        await self.stop(); self.notice = "系统音频已重置，请重新开始。"
                        self.synthesizer.delegate = nil
                        self.synthesizer = AVSpeechSynthesizer(); self.synthesizer.delegate = self
                        self.synthesizer.usesApplicationAudioSession = true
                    } else if (name == AVAudioSession.didBecomeInactiveNotification && !ownRelease) || unplugged {
                        self.pause(restartSentence: true)
                        self.notice = "播放被中断或耳机断开，已暂停。点继续从当前句开始。"
                    }
                }
            })
        }
    }

    func listen(passage: Passage, first: Int, last: Int, preferences: BeiPreferences, timerMinutes: Int?) {
        guard !active else { return }
        do {
            voice = try BeiVoiceResolver.resolve(passage.language, preferences: preferences)
            self.passage = passage; self.preferences = preferences; kind = .listening
            listeningPlan = BeiPlaybackPlan(first: first, last: last, totalPasses: preferences.totalPasses)
            current = first; completedPasses = 0; error = nil; notice = nil
            timerDeadline = timerMinutes.map { Date().addingTimeInterval(Double($0) * 60) }
            startClock(); registerCommands(); activateAndSpeak()
        } catch { self.error = error.localizedDescription }
    }

    func practice(passage: Passage, preferences: BeiPreferences, appFirst: Bool) {
        guard !active, !passage.units.isEmpty else { return }
        do {
            voice = try BeiVoiceResolver.resolve(passage.language, preferences: preferences)
            self.passage = passage; self.preferences = preferences; kind = .practice
            practicePlan = BeiPracticePlan(first: 0, last: passage.units.count - 1, appFirst: appFirst)
            current = 0; error = nil; notice = nil; lastSpokenDuration = 3; secondsToWait = 0
            startClock(); performPracticeTurn()
        } catch { self.error = error.localizedDescription }
    }

    private func activateAndSpeak() {
        state = .preparing
        let token = generation
        let previous = work
        work = Task {
            await previous?.value
            do {
                let activated = try await AudioPlaybackCoordinator.shared.activate(owner: "bei")
                try Task.checkCancellation()
                guard generation == token, activated else { throw BeiError.invalid("音频未能启动，请停止后重试。") }
                actualVoice = voice?.name ?? ""
                if isListening {
                    guard let plan = listeningPlan else { return }
                    tailPlan = plan; enqueue(plan, delay: 0); enqueueNext()
                } else { speakPracticeSentence() }
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    guard self.generation == token, self.state == .preparing else { return }
                    self.error = "所选声音未能开始朗读，请检查系统声音下载后重试。"
                    await self.stop()
                }
            } catch {
                guard generation == token else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
                // Do not await the task currently stored in work from itself.
                work = nil; await stop()
            }
        }
    }

    private func enqueue(_ plan: BeiPlaybackPlan, delay: Double) {
        guard let passage, passage.units.indices.contains(plan.current), let voice else { return }
        let utterance = AVSpeechUtterance(string: passage.units[plan.current].text(in: passage.body))
        utterance.voice = voice; utterance.rate = preferences.speechRate; utterance.preUtteranceDelay = delay
        queued[ObjectIdentifier(utterance)] = (utterance, plan)
        synthesizer.speak(utterance)
    }
    private func enqueueNext() {
        guard var tail = tailPlan, let passage else { return }
        let previous = tail
        tail.advance()
        guard !tail.finished else { return }
        let repeatBoundary = previous.current == previous.last
        let paragraphBoundary = passage.units[previous.current].paragraph != passage.units[tail.current].paragraph
        let delay = repeatBoundary ? preferences.repeatPause : (paragraphBoundary ? preferences.paragraphPause : preferences.sentencePause)
        tailPlan = tail
        enqueue(tail, delay: delay)
    }
    private func speakPracticeSentence() {
        guard let passage, let plan = practicePlan, let voice else { return }
        let utterance = AVSpeechUtterance(string: passage.units[plan.current].text(in: passage.body))
        utterance.voice = voice; utterance.rate = preferences.speechRate
        practiceUtterance = utterance; synthesizer.speak(utterance)
    }
    private func performPracticeTurn() {
        guard let plan = practicePlan else { return }
        current = plan.current
        if plan.finished {
            notice = "全文练习完成。可以调整提示或朗读顺序，再练一次。"
            Task { await stop() }
        } else if plan.turn == .app { activateAndSpeak() }
        else {
            state = .waiting
            let duration = plan.childWaitDuration(afterSpokenDuration: lastSpokenDuration)
            waitingDeadline = duration.map { Date().addingTimeInterval($0) }
            secondsToWait = duration.map { Int(ceil($0)) } ?? 0
        }
    }
    func completeChildTurn() {
        guard state == .waiting, var plan = practicePlan else { return }
        waitingDeadline = nil; plan.advance(); practicePlan = plan; performPracticeTurn()
    }
    func extendWait() {
        guard state == .waiting, let deadline = waitingDeadline else { return }
        waitingDeadline = deadline.addingTimeInterval(5); secondsToWait += 5
    }
    func repeatPracticeSentence() {
        guard state == .waiting, let plan = practicePlan, let passage else { return }
        do { voice = try BeiVoiceResolver.resolve(passage.language, preferences: preferences) }
        catch { self.error = error.localizedDescription; return }
        waitingDeadline = nil
        // Replaying during the child turn returns to that same turn without advancing.
        activateAndSpeak()
        current = plan.current
    }

    func move(_ delta: Int) {
        guard isListening, active, state != .stopping, var plan = listeningPlan else { return }
        plan.move(delta); listeningPlan = plan; current = plan.current
        generation = UUID(); work?.cancel()
        queued.removeAll(); tailPlan = nil; synthesizer.stopSpeaking(at: .immediate)
        activateAndSpeak(); updateNowPlaying()
        notice = "已跳句，未完整播放的这一遍不计入完成遍数。"
    }
    func pause(restartSentence: Bool = false) {
        guard active, state != .paused, state != .stopping else { return }
        pausedFrom = state
        if state == .speaking { speechPauseAt = Date() }
        if state == .waiting {
            secondsToWait = waitingDeadline.map { max(0, Int(ceil($0.timeIntervalSinceNow))) } ?? 0
            waitingDeadline = nil
        }
        if state == .preparing || restartSentence || !synthesizer.pauseSpeaking(at: .immediate) {
            generation = UUID(); work?.cancel(); queued.removeAll(); tailPlan = nil
            practiceUtterance = nil; synthesizer.stopSpeaking(at: .immediate)
        }
        state = .paused; updateNowPlaying()
    }
    func resume() {
        guard state == .paused else { return }
        if let deadline = timerDeadline, deadline <= Date() { Task { await stop() }; return }
        if pausedFrom == .waiting {
            state = .waiting
            if secondsToWait > 0 { waitingDeadline = Date().addingTimeInterval(Double(secondsToWait)) }
        } else if synthesizer.isPaused && synthesizer.continueSpeaking() {
            if let speechPauseAt, let spokenAt { self.spokenAt = spokenAt.addingTimeInterval(Date().timeIntervalSince(speechPauseAt)) }
            speechPauseAt = nil; state = .speaking
        }
        else { activateAndSpeak() }
        updateNowPlaying()
    }
    func sceneChanged(_ phase: String) {
        if !isListening, phase != "active", active { pause() }
        if phase == "active", let deadline = timerDeadline, deadline <= Date() { Task { await stop() } }
    }

    func stop() async {
        if let stopWork { await stopWork.value; return }
        guard state != .stopping else { return }
        guard active || !queued.isEmpty else { return }
        state = .stopping; generation = UUID(); remoteSessionID = UUID()
        let previous = work; work = nil; previous?.cancel()
        clock?.cancel(); clock = nil; waitingDeadline = nil; timerDeadline = nil
        queued.removeAll(); tailPlan = nil; practiceUtterance = nil
        synthesizer.stopSpeaking(at: .immediate); removeCommands()
        let task = Task {
            await previous?.value
            await AudioPlaybackCoordinator.shared.release(owner: "bei")?.value
            state = .idle
        }
        stopWork = task; await task.value; stopWork = nil
    }
    private func startClock() {
        clock?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in Task { @MainActor in self?.tick() } }
        clock = timer; timer.resume()
    }
    private func tick() {
        guard active, state != .stopping else { return }
        if let timerDeadline, timerDeadline <= Date() {
            notice = "定时结束，已停止播放。"; Task { await stop() }; return
        }
        if state == .waiting, let waitingDeadline {
            secondsToWait = max(0, Int(ceil(waitingDeadline.timeIntervalSinceNow)))
            if secondsToWait <= 0 { completeChildTurn() }
        }
    }
    private func registerCommands() {
        removeCommands()
        remoteSessionID = UUID()
        let token = remoteSessionID
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, 0), (center.pauseCommand, 1), (center.stopCommand, 2), (center.togglePlayPauseCommand, 3)] {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.remoteSessionID == token, self.isListening, self.active, AudioPlaybackCoordinator.shared.owns("bei") else { return }
                    if action == 0 { self.resume() }
                    else if action == 1 { self.pause() }
                    else if action == 2 { await self.stop() }
                    else if self.state == .paused { self.resume() } else { self.pause() }
                }
                return .success
            }
            commandTargets.append((command, target))
        }
        updateNowPlaying()
    }
    private func removeCommands() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
            if AudioPlaybackCoordinator.shared.owns("bei") || AudioPlaybackCoordinator.shared.owner == nil { command.isEnabled = false }
        }
        commandTargets.removeAll()
        if AudioPlaybackCoordinator.shared.owns("bei") { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }
    private func updateNowPlaying() {
        guard isListening, active, let passage, AudioPlaybackCoordinator.shared.owns("bei") else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: passage.title,
            MPMediaItemPropertyArtist: "简单背 · 第 \(current + 1) 句", MPNowPlayingInfoPropertyPlaybackRate: state == .paused ? 0 : 1]
    }
    private func didStart(_ utterance: AVSpeechUtterance) {
        if let (_, plan) = queued[ObjectIdentifier(utterance)] {
            listeningPlan = plan; current = plan.current; completedPasses = plan.completedPasses
        } else if practiceUtterance !== utterance { return }
        if state != .paused { state = .speaking }
        spokenAt = Date(); speechPauseAt = state == .paused ? Date() : nil; updateNowPlaying()
    }
    private func didFinish(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        if let (_, snapshot) = queued.removeValue(forKey: ObjectIdentifier(utterance)) {
            guard !cancelled else { pause(restartSentence: true); return }
            var next = snapshot; next.advance(); listeningPlan = next; completedPasses = next.completedPasses
            if next.finished { notice = "已完成 \(completedPasses) 遍朗读。"; Task { await stop() } }
            else { current = next.current; enqueueNext() }
            updateNowPlaying()
        } else if practiceUtterance === utterance {
            practiceUtterance = nil
            guard !cancelled else { pause(restartSentence: true); return }
            lastSpokenDuration = max(2, spokenAt.map { (speechPauseAt ?? Date()).timeIntervalSince($0) } ?? 3)
            if var plan = practicePlan {
                if plan.turn == .app { plan.advance(); practicePlan = plan }
                if state == .paused, !plan.finished {
                    pausedFrom = .waiting; waitingDeadline = nil
                    secondsToWait = plan.childWaitDuration(afterSpokenDuration: lastSpokenDuration).map { Int(ceil($0)) } ?? 0
                } else { performPracticeTurn() }
            }
        }
    }
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
