import XCTest
@testable import StudyShell

final class ModuleSessionTests: XCTestCase {
    func testRewardRepeatsEverySevenCompletedDaysAndResetsAfterABreak() {
        for streak in 1...28 {
            let progress = StreakRewardProgress(streak: streak)
            XCTAssertEqual(progress.isRewardDay, [7, 14, 21, 28].contains(streak))
            XCTAssertEqual(progress.cycleDays + (progress.isRewardDay ? 0 : progress.daysRemaining), 7)
        }
        XCTAssertEqual(StreakRewardProgress(streak: 3).daysRemaining, 4)
        XCTAssertEqual(StreakRewardProgress(streak: 8).daysRemaining, 6)
        XCTAssertEqual(StreakRewardProgress(streak: 1).daysRemaining, 6)
        XCTAssertFalse(StreakRewardProgress(streak: 0).isRewardDay)
        XCTAssertFalse(StreakRewardProgress(streak: -1).isRewardDay)
        XCTAssertEqual(StreakRewardProgress(streak: 7).daysRemaining, 0)
        XCTAssertEqual(StreakRewardProgress(streak: 14).daysRemaining, 0)
        XCTAssertEqual(StreakRewardProgress(streak: 3).countdown, "再坚持 4 天，就可以找爸爸兑换 3 元零花钱！")
        XCTAssertEqual(StreakRewardProgress(streak: 8).countdown, "再坚持 6 天，就可以找爸爸再次兑换 3 元零花钱！")
    }
    @MainActor func testFinishingOneTaskDoesNotReleaseAnotherActiveTask() {
        let session = ModuleSession()
        session.setBusy(true, reason: "study")
        session.setBusy(true, reason: "backup")
        session.setBusy(false, reason: "backup")
        XCTAssertFalse(session.canLeave)
        session.setBusy(false, reason: "study")
        XCTAssertTrue(session.canLeave)
    }
    func testRepairOnlyOffersYesterdayAfterAnExistingStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let keys: Set<String> = ["2026-10-05", "2026-10-06", "2026-10-07"]
        let offer = OneDayStreakRepair.offer(completedKeys: keys, now: now, calendar: calendar)
        XCTAssertEqual(offer?.yesterdayKey, "2026-10-08")
        XCTAssertEqual(offer?.previousStreak, 3)
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, handledKeys: ["2026-10-08"], now: now, calendar: calendar))
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys.union(["2026-10-08"]), now: now, calendar: calendar))
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: [], now: now, calendar: calendar))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, now: tomorrow, calendar: calendar))
    }

    func testRepairUsesCalendarDaysAcrossMonthBoundaryAndDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0))!
        let keys = WeekendStreak.completionKeys(["2026-10-30", "2026-10-31"], now: now, calendar: calendar)
        XCTAssertEqual(keys, ["2026-10-30", "2026-10-31", "2026-11-01"])
        XCTAssertEqual(WeekendStreak.count(completedKeys: keys, now: now, calendar: calendar), 3)
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, now: now, calendar: calendar))
        XCTAssertTrue(OneDayStreakRepair.isYesterday("2026-11-01", on: now, calendar: calendar))
    }

    func testWeekendCompletionDefersFutureSundayAndDoesNotCrossWeeks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
        }
        XCTAssertEqual(WeekendStreak.completionKeys(["2026-10-03"], now: date(3), calendar: calendar), ["2026-10-03"])
        XCTAssertEqual(WeekendStreak.completionKeys(["2026-10-03"], now: date(4), calendar: calendar), ["2026-10-03", "2026-10-04"])
        XCTAssertEqual(WeekendStreak.completionKeys(["2026-10-04"], now: date(4), calendar: calendar), ["2026-10-03", "2026-10-04"])
        XCTAssertEqual(WeekendStreak.completionKeys(["2026-10-02"], now: date(5), calendar: calendar), ["2026-10-02"])
        let keys = WeekendStreak.completionKeys(["2026-10-04", "2026-10-11"], now: date(12), calendar: calendar)
        XCTAssertEqual(keys, ["2026-10-03", "2026-10-04", "2026-10-10", "2026-10-11"])
        XCTAssertEqual(WeekendStreak.count(completedKeys: keys, now: date(12), calendar: calendar), 2)
        XCTAssertEqual(WeekendStreak.completionKeys(keys, now: date(12), calendar: calendar), keys)
    }

    func testSundayKeepsFridayStreakWhilePendingWithoutOfferingRepair() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
        }
        let keys: Set<String> = ["2026-10-01", "2026-10-02"]
        XCTAssertEqual(WeekendStreak.count(completedKeys: keys, now: date(4), calendar: calendar), 2)
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, now: date(4), calendar: calendar))
        XCTAssertEqual(WeekendStreak.count(completedKeys: keys, now: date(5), calendar: calendar), 0)
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, now: date(5), calendar: calendar))
        XCTAssertNotNil(OneDayStreakRepair.offer(completedKeys: ["2026-10-01"], now: date(3), calendar: calendar))
    }

    func testFridayRepairRemainsAvailableOnSundayUntilWeekendIsCompletedOrOpportunityHandled() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
        }
        let keys: Set<String> = ["2026-09-30", "2026-10-01"]
        for day in [3, 4] {
            let offer = OneDayStreakRepair.offer(completedKeys: keys, now: date(day), calendar: calendar)
            XCTAssertEqual(offer?.yesterdayKey, "2026-10-02")
            XCTAssertEqual(offer?.previousStreak, 2)
            XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, handledKeys: ["2026-10-02"],
                now: date(day), calendar: calendar))
        }
        for completedDay in ["2026-10-02", "2026-10-03", "2026-10-04"] {
            XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys.union([completedDay]), now: date(4), calendar: calendar))
        }
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: ["2026-09-30"], now: date(4), calendar: calendar))
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, now: date(5), calendar: calendar))
        let finished = WeekendStreak.completionKeys(keys.union(["2026-10-02", "2026-10-04"]), now: date(4), calendar: calendar)
        XCTAssertEqual(WeekendStreak.count(completedKeys: finished, now: date(4), calendar: calendar), 5)
    }

    func testSundayRepairValidationCrossesMonthAndDSTWithoutAllowingOtherOlderDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        let offer = OneDayStreakRepair.offer(completedKeys: ["2026-10-29"], now: sunday, calendar: calendar)
        XCTAssertEqual(offer?.yesterdayKey, "2026-10-30")
        XCTAssertTrue(OneDayStreakRepair.isRepairableDay("2026-10-30", on: sunday, calendar: calendar))
        XCTAssertTrue(OneDayStreakRepair.isRepairableDay("2026-10-31", on: sunday, calendar: calendar), "Older next-day repair records remain valid")
        XCTAssertFalse(OneDayStreakRepair.isRepairableDay("2026-10-29", on: sunday, calendar: calendar))
        XCTAssertFalse(OneDayStreakRepair.isRepairableDay("2026-11-01", on: sunday, calendar: calendar))
        let monday = calendar.date(byAdding: .day, value: 1, to: sunday)!
        XCTAssertFalse(OneDayStreakRepair.isRepairableDay("2026-10-30", on: monday, calendar: calendar))
        XCTAssertFalse(OneDayStreakRepair.isRepairableDay("2026-10-31", on: monday, calendar: calendar))
    }

}


final class FreeDayTests: XCTestCase {
    private func date(_ year: Int = 2026, _ month: Int = 11, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        FreeDayLedger.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    func testWeeklyAvailabilityExpiresAndNeverAccumulates() {
        let empty = FreeDayLedger()
        XCTAssertTrue(empty.canUse(on: date(2026, 11, 2))) // Monday
        XCTAssertTrue(empty.canUse(on: date(2026, 11, 6, 23, 59)))
        XCTAssertFalse(empty.canUse(on: date(2026, 11, 7, 0)))
        XCTAssertFalse(empty.canUse(on: date(2026, 11, 8)))
        let used = FreeDayLedger(usedAt: [date(2026, 11, 4)])
        XCTAssertFalse(used.canUse(on: date(2026, 11, 6)))
        XCTAssertTrue(used.canUse(on: date(2026, 11, 9, 0)))
        XCTAssertTrue(empty.canUse(on: date(2026, 11, 9))) // Skipping a week still grants one only.
        XCTAssertTrue(used.isUsed(on: date(2026, 11, 4, 23)))
    }
    func testBeijingBoundaryAndNewYearWeek() throws {
        let friday = date(2027, 1, 1, 23, 59)
        let ledger = FreeDayLedger(usedAt: [friday])
        XCTAssertNoThrow(try ledger.validated())
        XCTAssertEqual(FreeDayLedger.dayKey(friday), "2027-01-01")
        XCTAssertFalse(ledger.canUse(on: date(2026, 12, 28)))
        XCTAssertFalse(ledger.canUse(on: date(2027, 1, 2, 0)))
        XCTAssertTrue(ledger.canUse(on: date(2027, 1, 4, 0)))
        XCTAssertTrue(ledger.completionKeys(now: friday.addingTimeInterval(-1)).isEmpty)
    }
    func testStorageSurvivesReopeningAndRejectsDuplicateUse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FreeDayStore(fileURL: folder.appendingPathComponent("Ledger.json"))
        try store.use(now: date(2026, 11, 6))
        let reopened = FreeDayStore(fileURL: store.fileURL)
        XCTAssertEqual(try reopened.load().completionKeys(now: date(2026, 11, 7)), ["2026-11-06"])
        XCTAssertThrowsError(try reopened.use(now: date(2026, 11, 6, 20)))
        XCTAssertThrowsError(try reopened.use(now: date(2026, 11, 7)))
        try reopened.use(now: date(2026, 11, 9))
        XCTAssertEqual(try reopened.load().usedAt.count, 2)
    }
    func testCorruptOrDuplicateWeekBackupIsRejectedWithoutReplacingLedger() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FreeDayStore(fileURL: folder.appendingPathComponent("Ledger.json"))
        try store.use(now: date(2026, 11, 4))
        let before = try store.export()
        for ledger in [FreeDayLedger(usedAt: [date(2026, 11, 4), date(2026, 11, 6)]),
                       FreeDayLedger(usedAt: [date(2026, 11, 7)])] {
            XCTAssertThrowsError(try store.restore(JSONEncoder().encode(ledger)))
            XCTAssertEqual(try store.export(), before)
        }
        try Data("broken".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.use(now: date(2026, 11, 9)))
    }
}
