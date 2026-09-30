import Foundation
import Observation

@MainActor @Observable
final class BeiStudySession {
    enum Mode: String, CaseIterable, Identifiable {
        case listen, practice, test
        var id: String { rawValue }
        var title: String { switch self { case .listen: "听课文"; case .practice: "练背诵"; case .test: "测一测" } }
    }
    let audio = BeiLearningAudio()
    let recording = BeiRecordingSession(audio: BeiRecordingAudio())
    var mode = Mode.listen
    var first = 0
    var last = 0
    var hintLevel = BeiHintLevel.full
    var appFirst = true
    var timerMinutes = 0
    private(set) var switching = false
    var notice: String?
    var error: String?
    var active: Bool { audio.active || recording.active || switching }
    var hidesTestText: Bool { mode == .test && !recording.showsOriginal }
    private var passage: Passage?
    private var endWork: Task<Void, Never>?
    private var foreground = true

    func select(_ value: Passage) {
        guard !active else { return }
        if passage?.id != value.id || passage?.contentVersion != value.contentVersion {
            first = 0; last = max(0, value.units.count - 1)
            notice = nil; error = nil
        }
        passage = value
    }
    func changeMode(_ value: Mode) async {
        guard !switching else { return }
        await end(); guard recording.state == .idle else { return }
        mode = value
    }
    func startListening(_ preferences: BeiPreferences) {
        guard !active, let passage else { return }
        error = nil; notice = nil
        audio.listen(passage: passage, first: first, last: last, preferences: preferences, timerMinutes: timerMinutes == 0 ? nil : timerMinutes)
    }
    func startPractice(_ preferences: BeiPreferences) {
        guard !active, let passage else { return }
        error = nil; notice = nil
        audio.practice(passage: passage, preferences: preferences, appFirst: appFirst)
    }
    func startTest() async {
        guard !audio.active, !switching, foreground, mode == .test, passage != nil,
              recording.state == .idle || recording.state == .review else { return }
        switching = true; error = nil; notice = nil
        defer { switching = false }
        do {
            try await SimpleBeiStartup.shared.prepare()
            guard foreground else { return }
            recording.start()
        } catch { self.error = "录音准备失败：\(error.localizedDescription)" }
    }
    func end() async {
        if let endWork { await endWork.value; return }
        switching = true
        let task = Task {
            await audio.stop()
            await recording.endAndWait()
            switching = false
        }
        endWork = task; await task.value; endWork = nil
    }
    func sceneChanged(_ phase: String) {
        foreground = phase == "active"
        audio.sceneChanged(phase)
        recording.sceneChanged(phase)
    }
}
