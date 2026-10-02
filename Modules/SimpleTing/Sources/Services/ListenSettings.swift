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
    var snapshot: ListenPreferences {
        ListenPreferences(voiceIdentifier: voiceIdentifier, rate: rate, order: order,
                          loopEnabled: loopEnabled, lastPlayedID: lastPlayedID)
    }
    func apply(_ value: ListenPreferences) {
        voiceIdentifier = value.voiceIdentifier; rate = value.rate; order = value.order
        loopEnabled = value.loopEnabled; lastPlayedID = value.lastPlayedID
    }
    init(defaults: UserDefaults = UserDefaults(suiteName: "com.hutianyi.SimpleXue.SimpleTing")!) {
        self.defaults = defaults
        voiceIdentifier = defaults.string(forKey: "selectedVoiceIdentifier") ?? ""
        rate = SpeechRatePreset(rawValue: defaults.string(forKey: "speechRatePreset") ?? "") ?? .standard
        order = PlaybackOrder(rawValue: defaults.string(forKey: "playbackOrder") ?? "") ?? .forward
        loopEnabled = defaults.object(forKey: "loopEnabled") as? Bool ?? true
        lastPlayedID = defaults.string(forKey: "lastPlayedArticleID").flatMap(UUID.init(uuidString:))
    }
}
