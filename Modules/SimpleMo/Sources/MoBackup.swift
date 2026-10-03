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
        var automaticTiming: Bool? = nil
    }

    static func snapshot(defaults: UserDefaults = Self.defaults) -> MoBackup {
        MoBackup(settings: Settings(inputText: defaults.string(forKey: "dictation.input") ?? "苹果\n认真\n美丽\numbrella\nwonderful",
            shuffleWords: defaults.bool(forKey: "dictation.shuffle"),
            speechRate: defaults.object(forKey: "dictation.rate") as? Double ?? 0.42,
            repeatAfterSeconds: defaults.object(forKey: "dictation.repeatAfter") as? Int ?? 15,
            advanceAfterSeconds: defaults.object(forKey: "dictation.advanceAfter") as? Int ?? 30,
            automaticTiming: defaults.object(forKey: "dictation.automaticTiming") as? Bool ?? true))
    }

    static func decode(_ data: Data) throws -> MoBackup {
        let value = try JSONDecoder().decode(MoBackup.self, from: data)
        guard value.app == "SimpleMo", value.formatVersion == 1,
              value.settings.speechRate.isFinite, (0.32...0.55).contains(value.settings.speechRate),
              value.settings.advanceAfterSeconds <= DictationTimingConfiguration.maximumAdvanceAfterSeconds,
              DictationTimingConfiguration(repeatAfterSeconds: value.settings.repeatAfterSeconds,
                advanceAfterSeconds: value.settings.advanceAfterSeconds).isValid else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func apply(defaults: UserDefaults = Self.defaults) {
        defaults.set(settings.automaticTiming ?? true, forKey: "dictation.automaticTiming")
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

@MainActor
public enum SimpleMoBackupTransfer {
    public static func exportData() throws -> Data { try MoBackup.encode(MoBackup.snapshot()) }
    public static func validate(_ data: Data) throws -> String {
        let backup = try MoBackup.decode(data)
        let count = backup.settings.inputText.split(whereSeparator: \.isNewline).count
        return "默写文本 \(count) 行及播放设置"
    }
    public static func restore(_ data: Data) throws { try MoBackup.decode(data).apply() }
}
