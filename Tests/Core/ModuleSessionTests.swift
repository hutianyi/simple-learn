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
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!
        let keys: Set<String> = ["2026-10-01", "2026-10-02", "2026-10-03"]
        let offer = OneDayStreakRepair.offer(completedKeys: keys, now: now, calendar: calendar)
        XCTAssertEqual(offer?.yesterdayKey, "2026-10-04")
        XCTAssertEqual(offer?.previousStreak, 3)
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, handledKeys: ["2026-10-04"], now: now, calendar: calendar))
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys.union(["2026-10-04"]), now: now, calendar: calendar))
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: [], now: now, calendar: calendar))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertNil(OneDayStreakRepair.offer(completedKeys: keys, now: tomorrow, calendar: calendar))
    }

    func testRepairUsesCalendarDaysAcrossMonthBoundaryAndDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0))!
        let offer = OneDayStreakRepair.offer(completedKeys: ["2026-10-30", "2026-10-31"], now: now, calendar: calendar)
        XCTAssertEqual(offer?.yesterdayKey, "2026-11-01")
        XCTAssertEqual(offer?.previousStreak, 2)
        XCTAssertTrue(OneDayStreakRepair.isYesterday("2026-11-01", on: now, calendar: calendar))
    }

}
