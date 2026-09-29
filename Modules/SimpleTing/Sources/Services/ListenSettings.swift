import Foundation
import Observation

@MainActor @Observable
final class ListenSettings {
    @ObservationIgnored private let defaults: UserDefaults
    var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: "selectedVoiceIdentifier") } }
    var rate: SpeechRatePreset { didSet { defaults.set(rate.rawValue, forKey: "speechRatePreset") } }
    var order: PlaybackOrder { didSet { defaults.set(order.rawValue, forKey: "playbackOrder") } }
    var loopEnabled: Bool { didSet { defaults.set(loopEnabled, forKey: "loopEnabled") } }
    var lastPlayedID: UUID? { didSet { defaults.set(lastPlayedID?.uuidString, forKey: "lastPlayedArticleID") } }
    init() {
        let defaults = UserDefaults(suiteName: "com.hutianyi.SimpleXue.SimpleTing")!
        self.defaults = defaults
        voiceIdentifier = defaults.string(forKey: "selectedVoiceIdentifier") ?? ""
        rate = SpeechRatePreset(rawValue: defaults.string(forKey: "speechRatePreset") ?? "") ?? .standard
        order = PlaybackOrder(rawValue: defaults.string(forKey: "playbackOrder") ?? "") ?? .forward
        loopEnabled = defaults.object(forKey: "loopEnabled") as? Bool ?? true
        lastPlayedID = defaults.string(forKey: "lastPlayedArticleID").flatMap(UUID.init(uuidString:))
    }
}
