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
    public static func isWeekendComplete(completedKeys: Set<String>, now: Date = Date(),
                                         calendar: Calendar = .current) -> Bool {
        guard [1, 7].contains(calendar.component(.weekday, from: now)) else { return false }
        return completionKeys(completedKeys, now: now, calendar: calendar)
            .contains(OneDayStreakRepair.dayKey(now, calendar: calendar))
    }

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

public enum FreeDayError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// A separate ledger credits attendance without changing answers or review schedules.
public struct FreeDayLedger: Codable, Equatable, Sendable {
    public var usedAt: [Date] = []
    // Saved with the ledger so unopened Fridays can be credited after relaunch or restore.
    public var automaticFridaysFrom: Date?
    public init(usedAt: [Date] = [], automaticFridaysFrom: Date? = nil) {
        self.usedAt = usedAt
        self.automaticFridaysFrom = automaticFridaysFrom
    }
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    public static func dayKey(_ date: Date) -> String {
        OneDayStreakRepair.dayKey(date, calendar: calendar)
    }
    private static func weekStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)!.start
    }
    public func isUsed(on date: Date) -> Bool {
        isAutomaticallyUsed(on: date)
            || usedAt.contains { $0 <= date && Self.dayKey($0) == Self.dayKey(date) }
    }
    public func isAutomaticallyUsed(on date: Date) -> Bool {
        guard let start = automaticFridaysFrom, date >= start,
              Self.calendar.component(.weekday, from: date) == 6 else { return false }
        return !usedAt.contains { Self.weekStart($0) == Self.weekStart(date) }
    }
    public func canUse(on date: Date) -> Bool {
        let weekday = Self.calendar.component(.weekday, from: date)
        return (2...6).contains(weekday)
            && !usedAt.contains { Self.weekStart($0) == Self.weekStart(date) }
            && !isAutomaticallyUsed(on: date)
    }
    public func completionKeys(now: Date) -> Set<String> {
        var keys = Set(usedAt.filter { $0 <= now }.map(Self.dayKey))
        guard var friday = automaticFridaysFrom else { return keys }
        let manualWeeks = Set(usedAt.map(Self.weekStart))
        while friday <= now {
            if !manualWeeks.contains(Self.weekStart(friday)) { keys.insert(Self.dayKey(friday)) }
            guard let next = Self.calendar.date(byAdding: .weekOfYear, value: 1, to: friday) else { break }
            friday = next
        }
        return keys
    }
    public mutating func enableAutomaticFridays(now: Date) {
        guard automaticFridaysFrom == nil else { return }
        let today = Self.calendar.startOfDay(for: now)
        let weekday = Self.calendar.component(.weekday, from: today)
        automaticFridaysFrom = Self.calendar.date(byAdding: .day, value: (6 - weekday + 7) % 7, to: today)
    }
    public func validated() throws -> Self {
        guard usedAt.allSatisfy({ $0.timeIntervalSince1970.isFinite
            && (2000...9999).contains(Self.calendar.component(.year, from: $0)) }) else {
            throw FreeDayError.message("免做卡日期无效，请保留数据。")
        }
        let weeks = usedAt.map(Self.weekStart)
        guard weeks.count == Set(weeks).count,
              usedAt.allSatisfy({ (2...6).contains(Self.calendar.component(.weekday, from: $0)) }) else {
            throw FreeDayError.message("免做卡记录无效，请保留数据。")
        }
        if let start = automaticFridaysFrom {
            guard start.timeIntervalSince1970.isFinite,
                  (2000...9999).contains(Self.calendar.component(.year, from: start)),
                  Self.calendar.component(.weekday, from: start) == 6,
                  start == Self.calendar.startOfDay(for: start) else {
                throw FreeDayError.message("免做卡自动使用日期无效，请保留数据。")
            }
        }
        return self
    }
}

public struct FreeDayStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public static func live() throws -> Self {
        Self(fileURL: try ModuleStorage.directory("FreeDay").appendingPathComponent("Ledger.json"))
    }
    public func load() throws -> FreeDayLedger {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return FreeDayLedger() }
        return try Self.decode(Data(contentsOf: fileURL))
    }
    public static func decode(_ data: Data) throws -> FreeDayLedger {
        try JSONDecoder().decode(FreeDayLedger.self, from: data).validated()
    }
    public func export() throws -> Data { try JSONEncoder().encode(load()) }
    public func enableAutomaticFridays(now: Date = Date()) throws -> FreeDayLedger {
        var ledger = try load()
        if ledger.automaticFridaysFrom == nil {
            ledger.enableAutomaticFridays(now: now)
            try restore(JSONEncoder().encode(ledger))
        }
        return ledger
    }
    public func restore(_ data: Data) throws {
        let ledger = try Self.decode(data)
        try JSONEncoder().encode(ledger).write(to: fileURL, options: .atomic)
    }
    // Called from the home screen on the main actor, after all eligibility checks.
    public func use(now: Date) throws {
        var ledger = try load()
        guard ledger.canUse(on: now) else {
            throw FreeDayError.message("本周免做卡已使用，或今天不是周一至周五。")
        }
        ledger.usedAt.append(now)
        try restore(JSONEncoder().encode(ledger))
    }
    public static func creditedKeys(now: Date = Date()) -> Set<String> {
        do { return try live().load().completionKeys(now: now) }
        catch {
            // Never grant attendance or another card when storage cannot be read.
            NSLog("[FreeDay] 免做卡记录读取失败：%@", error.localizedDescription)
            return []
        }
    }
    public static func isUsedToday(now: Date = Date()) -> Bool {
        creditedKeys(now: now).contains(FreeDayLedger.dayKey(now))
    }
}
