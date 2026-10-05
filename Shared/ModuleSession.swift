import Combine
import Foundation

@MainActor
public final class ModuleSession: ObservableObject {
    @Published public private(set) var reasons: Set<String> = []
    public var canLeave: Bool { reasons.isEmpty }
    public init() {}

    public func setBusy(_ busy: Bool, reason: String) {
        if busy { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}

public enum ModuleStorage {
    public static func directory(_ module: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let url = base.appendingPathComponent("SimpleXue", isDirectory: true)
            .appendingPathComponent(module, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func saveSafetyBackup(_ data: Data, module: String) throws {
        let folder = try directory(module).appendingPathComponent("SafetyBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("PreRestore-\(UUID().uuidString).json"), options: .atomic)
    }
}

public enum OneDayStreakRepair {
    public struct Offer: Equatable {
        public let todayKey: String
        public let yesterdayKey: String
        public let previousStreak: Int
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func offer(completedKeys: Set<String>, handledKeys: Set<String> = [],
                             now: Date = Date(), calendar: Calendar = .current) -> Offer? {
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              var cursor = calendar.date(byAdding: .day, value: -2, to: today) else { return nil }
        let todayKey = dayKey(today, calendar: calendar)
        let yesterdayKey = dayKey(yesterday, calendar: calendar)
        guard !completedKeys.contains(todayKey), !completedKeys.contains(yesterdayKey),
              !handledKeys.contains(yesterdayKey),
              completedKeys.contains(dayKey(cursor, calendar: calendar)) else { return nil }
        var streak = 0
        while completedKeys.contains(dayKey(cursor, calendar: calendar)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return Offer(todayKey: todayKey, yesterdayKey: yesterdayKey, previousStreak: streak)
    }

    public static func isYesterday(_ key: String, on date: Date, calendar: Calendar = .current) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) else { return false }
        return key == dayKey(yesterday, calendar: calendar)
    }
}
