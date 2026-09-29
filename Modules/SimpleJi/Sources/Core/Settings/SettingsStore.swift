import Foundation
import Combine

enum SessionLimitOption: Int, CaseIterable, Identifiable {
    case twenty = 20
    case thirty = 30
    case fifty = 50
    case unlimited = 0

    var id: Int { rawValue }

    var title: String {
        rawValue == 0 ? "不限" : "\(rawValue)"
    }
}

enum DictationLimitOption: Int, CaseIterable, Identifiable {
    case ten = 10
    case twenty = 20
    case thirty = 30
    case forty = 40
    case fifty = 50
    case unlimited = 0

    var id: Int { rawValue }
    var title: String { rawValue == 0 ? "不限" : "\(rawValue)" }
}

enum ExtraPracticeScope: String, CaseIterable, Identifiable {
    case weakest20
    case weakest50
    case allWeak
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weakest20: return "最弱 20 张"
        case .weakest50: return "最弱 50 张"
        case .allWeak: return "全部薄弱卡"
        case .everything: return "全部卡片"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var sessionLimit: SessionLimitOption { didSet { persist() } }
    @Published var englishVoiceIdentifier: String? { didSet { persist() } }
    @Published var chineseVoiceIdentifier: String? { didSet { persist() } }
    @Published var englishSpeechRate: Double { didSet { persist() } }
    @Published var chineseSpeechRate: Double { didSet { persist() } }
    @Published var autoSpeakFront: Bool { didSet { persist() } }
    @Published var autoSpeakBack: Bool { didSet { persist() } }
    @Published var hapticsEnabled: Bool { didSet { persist() } }
    @Published var extraPracticeScope: ExtraPracticeScope { didSet { persist() } }
    @Published var dictationLimit: DictationLimitOption { didSet { persist() } }
    @Published var baselineCampaign: BaselineCampaignSnapshot? { didSet { persist() } }
    @Published var masteredDictationTerms: Set<String> { didSet { persist() } }

    private enum Key {
        static let sessionLimit = "sessionLimit"
        static let englishVoiceIdentifier = "englishVoiceIdentifier"
        static let chineseVoiceIdentifier = "chineseVoiceIdentifier"
        static let englishSpeechRate = "englishSpeechRate"
        static let chineseSpeechRate = "chineseSpeechRate"
        static let autoSpeakFront = "autoSpeakFront"
        static let autoSpeakBack = "autoSpeakBack"
        static let hapticsEnabled = "hapticsEnabled"
        static let extraPracticeScope = "extraPracticeScope"
        static let dictationLimit = "dictationLimit"
        static let baselineCampaign = "baselineCampaign"
        static let masteredDictationTerms = "masteredDictationTerms"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedLimit = defaults.object(forKey: Key.sessionLimit) as? Int ?? 30
        sessionLimit = SessionLimitOption(rawValue: storedLimit) ?? .thirty
        englishVoiceIdentifier = defaults.string(forKey: Key.englishVoiceIdentifier)
        chineseVoiceIdentifier = defaults.string(forKey: Key.chineseVoiceIdentifier)
        englishSpeechRate = defaults.object(forKey: Key.englishSpeechRate) as? Double ?? 0.46
        chineseSpeechRate = defaults.object(forKey: Key.chineseSpeechRate) as? Double ?? 0.46
        autoSpeakFront = defaults.object(forKey: Key.autoSpeakFront) as? Bool ?? true
        autoSpeakBack = defaults.object(forKey: Key.autoSpeakBack) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Key.hapticsEnabled) as? Bool ?? true

        let storedScope = defaults.string(forKey: Key.extraPracticeScope)
        extraPracticeScope = storedScope.flatMap(ExtraPracticeScope.init(rawValue:)) ?? .weakest20
        let storedDictationLimit = defaults.object(forKey: Key.dictationLimit) as? Int ?? 20
        dictationLimit = DictationLimitOption(rawValue: storedDictationLimit) ?? .twenty
        baselineCampaign = defaults.data(forKey: Key.baselineCampaign).flatMap {
            try? JSONDecoder().decode(BaselineCampaignSnapshot.self, from: $0)
        }
        masteredDictationTerms = Set(defaults.stringArray(forKey: Key.masteredDictationTerms) ?? [])
    }

    private func persist() {
        defaults.set(sessionLimit.rawValue, forKey: Key.sessionLimit)
        defaults.set(englishVoiceIdentifier, forKey: Key.englishVoiceIdentifier)
        defaults.set(chineseVoiceIdentifier, forKey: Key.chineseVoiceIdentifier)
        defaults.set(englishSpeechRate, forKey: Key.englishSpeechRate)
        defaults.set(chineseSpeechRate, forKey: Key.chineseSpeechRate)
        defaults.set(autoSpeakFront, forKey: Key.autoSpeakFront)
        defaults.set(autoSpeakBack, forKey: Key.autoSpeakBack)
        defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled)
        defaults.set(extraPracticeScope.rawValue, forKey: Key.extraPracticeScope)
        defaults.set(dictationLimit.rawValue, forKey: Key.dictationLimit)
        if let baselineCampaign, let encoded = try? JSONEncoder().encode(baselineCampaign) {
            defaults.set(encoded, forKey: Key.baselineCampaign)
        } else {
            defaults.removeObject(forKey: Key.baselineCampaign)
        }
        defaults.set(masteredDictationTerms.sorted(), forKey: Key.masteredDictationTerms)
    }
}
