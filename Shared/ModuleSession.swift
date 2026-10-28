import Combine
import Foundation

@MainActor
public final class ModuleSession: ObservableObject {
    @Published public private(set) var reasons: Set<String> = []
    public var canLeave: Bool { reasons.isEmpty }
    public var prepareToLeave: (() throws -> Void)?
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

public enum WeekendStreak {
    public static func completionKeys(_ keys: Set<String>, now: Date = Date(),
                                      calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        let todayKey = OneDayStreakRepair.dayKey(today, calendar: calendar)
        var result = keys.filter { $0 <= todayKey }
        for key in result {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
                  OneDayStreakRepair.dayKey(date, calendar: calendar) == key else { continue }
            let weekday = calendar.component(.weekday, from: date)
            guard weekday == 7 || weekday == 1,
                  let companion = calendar.date(byAdding: .day, value: weekday == 7 ? 1 : -1, to: date),
                  calendar.startOfDay(for: companion) <= today else { continue }
            result.insert(OneDayStreakRepair.dayKey(companion, calendar: calendar))
        }
        return result
    }

    public static func count(completedKeys: Set<String>, now: Date = Date(),
                             calendar: Calendar = .current) -> Int {
        var cursor = calendar.startOfDay(for: now)
        if !completedKeys.contains(OneDayStreakRepair.dayKey(cursor, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            // Sunday is still available to finish this weekend; retain Friday's streak meanwhile.
            if calendar.component(.weekday, from: cursor) == 1
                && !completedKeys.contains(OneDayStreakRepair.dayKey(yesterday, calendar: calendar)) {
                guard let friday = calendar.date(byAdding: .day, value: -1, to: yesterday) else { return 0 }
                cursor = friday
            } else { cursor = yesterday }
        }
        var count = 0
        while completedKeys.contains(OneDayStreakRepair.dayKey(cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
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
        // Saturday and Sunday share one learning opportunity, so Sunday can repair Friday.
        let offset = calendar.component(.weekday, from: today) == 1 ? -2 : -1
        let completedKeys = WeekendStreak.completionKeys(completedKeys, now: now, calendar: calendar)
        guard let yesterday = calendar.date(byAdding: .day, value: offset, to: today),
              var cursor = calendar.date(byAdding: .day, value: -1, to: yesterday) else { return nil }
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

    public static func isRepairableDay(_ key: String, on date: Date, calendar: Calendar = .current) -> Bool {
        // Keep recognizing saved next-day repairs, including older Sunday repairs of Saturday.
        if isYesterday(key, on: date, calendar: calendar) { return true }
        guard calendar.component(.weekday, from: date) == 1,
              let friday = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: date)) else { return false }
        return key == dayKey(friday, calendar: calendar)
    }
}
