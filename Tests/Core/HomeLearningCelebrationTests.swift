import XCTest
@testable import StudyShell

final class HomeLearningCelebrationTests: XCTestCase {
    private func status(_ complete: Bool, _ streak: Int, previous: Int? = nil) -> ModuleLearningOverview {
        ModuleLearningOverview(text: "", isComplete: complete,
            reward: StreakRewardProgress(streak: streak, previousStreak: previous))
    }

    func testEveryTaskCompletionCombinationKeepsRewardsIndependent() {
        for jiComplete in [false, true] {
            for suanComplete in [false, true] {
                for lianComplete in [false, true] {
                    let summary = HomeLearningCelebration(ji: status(jiComplete, 7), suan: status(suanComplete, 14),
                        lian: status(lianComplete, 0))
                    XCTAssertEqual(summary.allComplete, jiComplete && suanComplete && lianComplete)
                    XCTAssertEqual(summary.hasReward, jiComplete || suanComplete)
                    XCTAssertEqual(summary.rewardedEntries.count, [jiComplete, suanComplete].filter { $0 }.count)
                    XCTAssertEqual(summary.isVisible, jiComplete || suanComplete)
                }
            }
        }
    }

    func testAllCompleteShowsSeparateCountdownsAndNoReward() {
        let summary = HomeLearningCelebration(ji: status(true, 5), suan: status(true, 10), lian: status(true, 0))
        XCTAssertTrue(summary.isVisible)
        XCTAssertFalse(summary.hasReward)
        XCTAssertEqual(summary.title, "今天的学习全部完成！")
        XCTAssertEqual(summary.entries.map { $0.progress.daysRemaining }, [2, 4])
    }

    func testSingleRewardAndOtherCountdownWhenAllComplete() {
        let summary = HomeLearningCelebration(ji: status(true, 7), suan: status(true, 5), lian: status(true, 0))
        XCTAssertEqual(summary.entries.count, 2)
        XCTAssertEqual(summary.rewardedEntries.map(\.moduleName), ["简单记"])
        XCTAssertTrue(summary.title.contains("简单记七天打卡成功"))
    }

    func testPartialCompletionDoesNotShowUnfinishedModulesRetainedReward() {
        let summary = HomeLearningCelebration(ji: status(false, 7), suan: status(true, 5), lian: status(false, 0))
        XCTAssertFalse(summary.isVisible)
        XCTAssertTrue(summary.entries.isEmpty)
        let earned = HomeLearningCelebration(ji: status(true, 7), suan: status(false, 7), lian: nil)
        XCTAssertFalse(earned.allComplete)
        XCTAssertEqual(earned.entries.map(\.moduleName), ["简单记"])
    }

    func testCrossedMilestoneRepeatedVisitAndNextDay() {
        let crossed = status(true, 9, previous: 6)
        for _ in 0..<2 {
            let summary = HomeLearningCelebration(ji: crossed, suan: status(false, 0), lian: nil)
            XCTAssertTrue(summary.hasReward)
            XCTAssertEqual(summary.entries.first?.progress.rewardMilestone, 7)
            XCTAssertEqual(summary.entries.first?.progress.streak, 9)
        }
        let nextDay = HomeLearningCelebration(ji: status(true, 10, previous: 9), suan: status(true, 4), lian: status(true, 0))
        XCTAssertFalse(nextDay.hasReward)
        XCTAssertEqual(nextDay.entries.first?.progress.daysRemaining, 4)
    }

    func testMissingRecordsDoNotInventRewardsOrAllComplete() {
        let failed = ModuleLearningOverview(text: "读取失败", isComplete: false)
        let summary = HomeLearningCelebration(ji: failed, suan: status(true, 7), lian: nil)
        XCTAssertTrue(summary.hasReward)
        XCTAssertFalse(summary.allComplete)
        XCTAssertEqual(summary.entries.map(\.moduleName), ["简单算"])
        let empty = HomeLearningCelebration(ji: nil, suan: nil, lian: nil)
        XCTAssertFalse(empty.isVisible)
    }
}
