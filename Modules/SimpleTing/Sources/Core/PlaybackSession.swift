import Foundation
import Observation

enum ListenPlaybackState: Equatable {
    case stopped, preparing, playing, paused, stopping
    var title: String { switch self { case .stopped: "已停止"; case .preparing: "准备播放…"; case .playing: "正在播放"; case .paused: "已暂停"; case .stopping: "正在停止…" } }
}

struct SpeechRequest: Equatable, Sendable {
    let id: UUID
    let item: PlaybackItem
    let text: String
}

@MainActor @Observable
final class PlaybackSession {
    var library = ListenLibrary()
    private(set) var order: PlaybackOrder
    var loopEnabled: Bool
    private(set) var state: ListenPlaybackState = .stopped
    private(set) var selectedArticleID: UUID?
    private(set) var queue: [PlaybackItem] = []
    private(set) var index = 0
    private(set) var requestID: UUID?
    private(set) var timerEndDate: Date?
    @ObservationIgnored private let now: () -> Date

    init(order: PlaybackOrder = .forward, loopEnabled: Bool = true, now: @escaping () -> Date = Date.init) {
        self.order = order; self.loopEnabled = loopEnabled; self.now = now
    }

    var article: ListenArticle? { selectedArticleID.flatMap { library.article($0) } }
    var day: ListenDay? { selectedArticleID.flatMap { library.day(for: $0) } }
    var hasSession: Bool { state != .stopped || timerEndDate != nil }
    var expired: Bool { timerEndDate.map { $0 <= now() } ?? false }
    var secondsRemaining: Int? { timerEndDate.map { max(0, Int(ceil($0.timeIntervalSince(now())))) } }
    var canGoPrevious: Bool {
        if !queue.isEmpty { return index > 0 || loopEnabled }
        guard article != nil else { return false }
        if loopEnabled { return true }
        if order == .shuffle { return false }
        return PlaybackQueue.build(library, order: order).first?.articleID != selectedArticleID
    }

    func restoreSelection(_ id: UUID?) {
        selectedArticleID = id.flatMap { library.article($0) == nil ? nil : $0 }
            ?? PlaybackQueue.build(library, order: order).first?.articleID
    }

    func begin(_ id: UUID? = nil) -> SpeechRequest? {
        guard !expired else { stop(); return nil }
        let choice = id ?? selectedArticleID
        queue = PlaybackQueue.build(library, order: order, startingAt: choice)
        guard !queue.isEmpty else { stop(); return nil }
        index = choice.flatMap { value in queue.firstIndex { $0.articleID == value } } ?? 0
        return requestCurrent()
    }

    func changeOrder(_ value: PlaybackOrder) {
        order = value
        guard !queue.isEmpty else { return }
        queue = PlaybackQueue.build(library, order: order, startingAt: selectedArticleID)
        index = queue.firstIndex { $0.articleID == selectedArticleID } ?? 0
    }

    @discardableResult func started(_ id: UUID) -> Bool {
        guard requestID == id, state == .preparing, !expired else { return false }
        state = .playing
        return true
    }
    func paused() { if state == .playing { state = .paused } }
    func resumed() { if state == .paused && !expired { state = .playing } }
    func interrupt() {
        guard state == .playing || state == .preparing || state == .paused else { return }
        requestID = nil
        state = .paused
    }
    func restartCurrent() -> SpeechRequest? { guard !expired else { stop(); return nil }; return requestCurrent() }

    func finished(_ id: UUID) -> SpeechRequest? {
        guard id == requestID, state == .playing || state == .preparing else { return nil }
        return move(1)
    }

    func move(_ delta: Int) -> SpeechRequest? {
        guard !expired else { stop(); return nil }
        if queue.isEmpty {
            queue = PlaybackQueue.build(library, order: order, startingAt: selectedArticleID)
            index = queue.firstIndex { $0.articleID == selectedArticleID } ?? 0
        }
        guard !queue.isEmpty else { stop(); return nil }
        let candidate = index + delta
        if queue.indices.contains(candidate) { index = candidate }
        else if loopEnabled {
            if delta > 0 {
                if order == .shuffle { queue = PlaybackQueue.build(library, order: order, avoidingFirst: selectedArticleID) }
                index = 0
            } else { index = queue.count - 1 }
        } else if delta > 0 { stop(); return nil }
        else { return nil }
        return requestCurrent()
    }

    func setTimer(minutes: Int?) {
        timerEndDate = minutes.map { now().addingTimeInterval(Double($0) * 60) }
    }
    func beginStopping() {
        requestID = nil; timerEndDate = nil; state = .stopping
    }
    func stop() {
        requestID = nil; timerEndDate = nil; queue = []; index = 0; state = .stopped
    }

    private func requestCurrent() -> SpeechRequest? {
        guard queue.indices.contains(index), !expired,
              let value = library.article(queue[index].articleID) else { stop(); return nil }
        let title = ".!?;:".contains(value.title.last ?? ".") ? value.title : value.title + "."
        let request = SpeechRequest(id: UUID(), item: queue[index], text: title + "\n\n" + value.speechText)
        selectedArticleID = value.id; requestID = request.id; state = .preparing
        return request
    }
}
