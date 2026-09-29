import Foundation

enum ReviewDirection: String, Codable, CaseIterable, Identifiable {
    case englishToChinese
    case chineseToEnglish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .englishToChinese: return "英文 → 中文"
        case .chineseToEnglish: return "中文 → 英文"
        }
    }
}

enum ReviewResult: String, Codable {
    case known
    case unknown
}

enum PracticeMode: String, Codable {
    case scheduled
    case extraPractice
}
