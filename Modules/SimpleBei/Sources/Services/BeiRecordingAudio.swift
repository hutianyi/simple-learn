import AVFoundation
import Foundation
import StudyShell

@MainActor
final class BeiRecordingAudio: NSObject, BeiRecordingAudioDriver, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var notifications: [NSObjectProtocol] = []

    override init() {
        super.init()
        for name in [AVAudioSession.didBecomeInactiveNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, .simpleXueAudioOwnerChanged] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let interrupt: Bool
                if notification.name == AVAudioSession.didBecomeInactiveNotification {
                    let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                    interrupt = context?.source != .app
                } else if notification.name == AVAudioSession.routeChangeNotification {
                    interrupt = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                } else { interrupt = true }
                Task { @MainActor in
                    guard let self else { return }
                    if notification.name == .simpleXueAudioOwnerChanged, AudioPlaybackCoordinator.shared.owns("bei") { return }
                    if interrupt { self.onInterruption?() }
                }
            })
        }
    }
    deinit { for token in notifications { NotificationCenter.default.removeObserver(token) } }

    func record(to url: URL) async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        try Task.checkCancellation()
        guard granted else { throw BeiError.invalid("麦克风权限未开启，请在系统设置中为简单学开启。") }
        let activated = try await AudioPlaybackCoordinator.shared.activate(owner: "bei", configuration: .recording)
        try Task.checkCancellation()
        guard activated else { throw BeiError.invalid("无法开始录音，请重试。") }
        let sampleRate = AVAudioSession.sharedInstance().sampleRate
        guard sampleRate > 0 else { throw BeiError.invalid("麦克风暂不可用，请重试。") }
        let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        recorder.delegate = self; self.recorder = recorder
        guard recorder.prepareToRecord(), recorder.record() else { throw BeiError.invalid("录音未能启动，请重试。") }
    }
    func finishRecording() throws {
        guard let recorder else { throw BeiError.invalid("没有可回听的录音，请重新背一次。") }
        recorder.delegate = nil; recorder.stop(); self.recorder = nil
        guard try AVAudioFile(forReading: recorder.url).length > 0 else {
            throw BeiError.invalid("这次没有录到声音，请重新背一次。")
        }
    }
    func pauseRecording() { recorder?.pause() }
    func resumeRecording() throws {
        guard recorder?.record() == true else { throw BeiError.invalid("录音无法继续，请重新开始。") }
    }
    func play(from url: URL) async throws {
        let activated = try await AudioPlaybackCoordinator.shared.activate(owner: "bei")
        try Task.checkCancellation()
        guard activated else { throw BeiError.invalid("无法播放录音，请重试。") }
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self; self.player = player
        guard player.prepareToPlay(), player.play() else { throw BeiError.invalid("录音回放失败，请重试。") }
    }
    func stopPlayback() { player?.delegate = nil; player?.stop(); player = nil }
    func stopImmediately() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        stopPlayback()
    }
    func release() async { await AudioPlaybackCoordinator.shared.release(owner: "bei")?.value }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.onFailure?("录音出现错误，请重新背一次。")
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.onFailure?("录音提前停止，请重新背一次。")
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            if flag { self.onPlaybackFinished?() }
            else { self.onFailure?("录音回放失败，请重试。") }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.onFailure?("录音回放失败，请重试。")
        }
    }
}
