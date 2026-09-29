import Foundation
import StudyShell

struct MoBackup: Codable {
    static let defaults = UserDefaults(suiteName: "com.hutianyi.SimpleXue.SimpleMo")!
    var app = "SimpleMo"
    var formatVersion = 1
    let settings: Settings

    struct Settings: Codable, Equatable {
        let inputText: String
        let shuffleWords: Bool
        let speechRate: Double
        let repeatAfterSeconds: Int
        let advanceAfterSeconds: Int
    }

    static func snapshot(defaults: UserDefaults = Self.defaults) -> MoBackup {
        MoBackup(settings: Settings(inputText: defaults.string(forKey: "dictation.input") ?? "苹果\n认真\n美丽\numbrella\nwonderful",
            shuffleWords: defaults.bool(forKey: "dictation.shuffle"),
            speechRate: defaults.object(forKey: "dictation.rate") as? Double ?? 0.42,
            repeatAfterSeconds: defaults.object(forKey: "dictation.repeatAfter") as? Int ?? 15,
            advanceAfterSeconds: defaults.object(forKey: "dictation.advanceAfter") as? Int ?? 30))
    }

    static func decode(_ data: Data) throws -> MoBackup {
        let value = try JSONDecoder().decode(MoBackup.self, from: data)
        guard value.app == "SimpleMo", value.formatVersion == 1,
              value.settings.speechRate.isFinite, (0.32...0.55).contains(value.settings.speechRate),
              DictationTimingConfiguration(repeatAfterSeconds: value.settings.repeatAfterSeconds,
                advanceAfterSeconds: value.settings.advanceAfterSeconds).isValid else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func apply(defaults: UserDefaults = Self.defaults) {
        defaults.set(settings.inputText, forKey: "dictation.input")
        defaults.set(settings.shuffleWords, forKey: "dictation.shuffle")
        defaults.set(settings.speechRate, forKey: "dictation.rate")
        defaults.set(settings.repeatAfterSeconds, forKey: "dictation.repeatAfter")
        defaults.set(settings.advanceAfterSeconds, forKey: "dictation.advanceAfter")
    }

    static func encode(_ value: MoBackup) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
