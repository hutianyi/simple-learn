import AVFoundation
import Foundation

enum BeiVoiceResolver {
    static func candidates(_ language: PassageLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            guard voice.identifier.hasPrefix("com.apple.") else { return false }
            let name = voice.name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            return language == .english ? voice.language.hasPrefix("en") && name.contains("zoe") :
                voice.language.hasPrefix("zh") && (name.contains("语舒") || name.contains("yushu"))
        }.sorted { $0.quality.rawValue > $1.quality.rawValue }
    }
    static func preferred(_ language: PassageLanguage) -> AVSpeechSynthesisVoice? {
        let quality: AVSpeechSynthesisVoiceQuality = language == .chinese ? .enhanced : .premium
        return candidates(language).first { $0.quality == quality }
    }
    static func resolve(_ language: PassageLanguage, preferences: BeiPreferences) throws -> AVSpeechSynthesisVoice {
        let candidates = candidates(language)
        if let identifier = preferences.voiceID(for: language) {
            guard let selected = candidates.first(where: { $0.identifier == identifier }) else {
                throw BeiError.invalid("保存的\(language.title)声音暂不可用，请从“管理 → 播放与显示设置”重新选择语舒或 Zoe。")
            }
            return selected
        }
        guard let voice = preferred(language) else {
            throw BeiError.invalid("没有找到\(language == .chinese ? "语舒（优化音质）" : "Zoe（高音质）")。请在 iPad 系统设置下载后，从“管理 → 播放与显示设置”选择并试听。")
        }
        return voice
    }
    static func fillingDefaults(_ preferences: BeiPreferences) -> BeiPreferences {
        var value = preferences
        if value.chineseVoiceID == nil { value.chineseVoiceID = preferred(.chinese)?.identifier }
        if value.englishVoiceID == nil { value.englishVoiceID = preferred(.english)?.identifier }
        return value
    }
}
