import AVFoundation
import Foundation

enum SpeechLanguage: String {
    case english
    case chinese

    var localeIdentifier: String {
        switch self {
        case .english: return "en-US"
        case .chinese: return "zh-CN"
        }
    }

    var preferredName: String {
        switch self {
        case .english: return "Zoe"
        case .chinese: return "语舒"
        }
    }
}

struct SpeechVoiceOption: Identifiable, Hashable {
    let identifier: String
    let name: String
    let language: String
    let qualityRawValue: Int

    var id: String { identifier }

    var displayName: String {
        let quality: String
        switch qualityRawValue {
        case 2...: quality = "高级"
        case 1: quality = "优化"
        default: quality = "标准"
        }
        return "\(name)（\(quality)）"
    }
}

enum VoiceResolver {
    static func options(for language: SpeechLanguage) -> [SpeechVoiceOption] {
        matchingVoices(for: language)
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map {
                SpeechVoiceOption(
                    identifier: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    qualityRawValue: $0.quality.rawValue
                )
            }
    }

    static func resolve(
        language: SpeechLanguage,
        preferredIdentifier: String?,
        forceBasicFallback: Bool = false
    ) -> AVSpeechSynthesisVoice? {
        if !forceBasicFallback,
           let preferredIdentifier,
           let selected = matchingVoices(for: language).first(where: {
               $0.identifier == preferredIdentifier
           }) {
            return selected
        }

        let matching = matchingVoices(for: language)
        if !forceBasicFallback,
           let preferredByName = matching
            .filter({ $0.name.localizedCaseInsensitiveContains(language.preferredName) })
            .max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            return preferredByName
        }

        if forceBasicFallback,
           let basic = matching.first(where: { $0.quality == .default }) {
            return basic
        }

        return matching.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: language.localeIdentifier)
    }

    private static func matchingVoices(
        for language: SpeechLanguage
    ) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            switch language {
            case .english:
                return voice.language.hasPrefix("en-US")
            case .chinese:
                return voice.language.hasPrefix("zh-CN") || voice.language == "zh-Hans-CN"
            }
        }
    }
}
