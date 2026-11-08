import Foundation

public struct StreakRewardProgress: Equatable {
    public static let daysPerReward = 7
    public static let rewardYuan = 3
    public let streak: Int
    private let previousStreak: Int

    public init(streak: Int, previousStreak: Int? = nil) {
        self.streak = max(0, streak)
        self.previousStreak = min(self.streak, max(0, previousStreak ?? (self.streak - 1)))
    }

    // Use actual completion dates before weekend expansion. Today's repair must
    // not look like an earlier celebration that already showed the reward.
    public init(completionKeys: Set<String>, newlyRepairedKeys: Set<String> = [],
                now: Date = Date(), calendar: Calendar = .current) {
        let keys = WeekendStreak.completionKeys(completionKeys, now: now, calendar: calendar)
        let streak = WeekendStreak.count(completedKeys: keys, now: now, calendar: calendar)
        var cursor = calendar.startOfDay(for: now)
        let todayKey = OneDayStreakRepair.dayKey(cursor, calendar: calendar)
        guard completionKeys.contains(todayKey) else { self.init(streak: streak); return }
        let previousKey = completionKeys.subtracting(newlyRepairedKeys).filter { $0 < todayKey }.max()
        var previousStreak = streak
        while previousStreak > 0 && OneDayStreakRepair.dayKey(cursor, calendar: calendar) != previousKey {
            previousStreak -= 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        self.init(streak: streak, previousStreak: previousStreak)
    }

    public var rewardMilestone: Int { streak / Self.daysPerReward * Self.daysPerReward }
    public var isRewardDay: Bool {
        streak > 0 && (streak % Self.daysPerReward == 0
            || streak / Self.daysPerReward > previousStreak / Self.daysPerReward)
    }
    public var daysRemaining: Int { streak > 0 && streak % Self.daysPerReward == 0 ? 0 : Self.daysPerReward - streak % Self.daysPerReward }
    public var cycleDays: Int { isRewardDay ? Self.daysPerReward : streak % Self.daysPerReward }

    public var countdown: String {
        let again = streak >= Self.daysPerReward ? "再次" : ""
        return "再坚持 \(daysRemaining) 天，就可以找爸爸\(again)兑换 \(Self.rewardYuan) 元零花钱！"
    }
}

#if os(iOS)
import SwiftUI

public struct WeekendCompletionNotice: View {
    private let date: Date
    private let calendar: Calendar

    public init(date: Date = Date(), calendar: Calendar = .current) {
        self.date = date
        self.calendar = calendar
    }

    public var body: some View {
        if [1, 7].contains(calendar.component(.weekday, from: date)) {
            VStack(spacing: 8) {
                Label("周末完成一天，两天都算打卡成功！", systemImage: "calendar.badge.checkmark")
                    .font(.title2.bold())
                Text("另一天可以放心休息啦。")
                    .font(.title3)
            }
            .foregroundStyle(.purple)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("weekendCompletionNotice")
        }
    }
}

public struct StreakRewardCard: View {
    private let moduleName: String
    private let progress: StreakRewardProgress
    private var accent: Color { progress.isRewardDay ? .orange : .purple }

    public init(moduleName: String, streak: Int) {
        self.init(moduleName: moduleName, progress: StreakRewardProgress(streak: streak))
    }

    public init(moduleName: String, progress: StreakRewardProgress) {
        self.moduleName = moduleName
        self.progress = progress
    }

    public var body: some View {
        if progress.streak > 0 {
            VStack(spacing: 12) {
                Label(progress.isRewardDay ? "挑战成功，领取零花钱！" : "连续学习，攒零花钱！",
                      systemImage: progress.isRewardDay ? "gift.fill" : "star.circle.fill")
                    .font(.title2.bold()).foregroundStyle(accent)
                Text("\(moduleName)已连续完成 \(progress.streak) 天")
                    .font(.system(.title, design: .rounded, weight: .bold))
                HStack(spacing: 10) {
                    ForEach(1...StreakRewardProgress.daysPerReward, id: \.self) { day in
                        Image(systemName: day <= progress.cycleDays ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(day <= progress.cycleDays ? accent : .secondary)
                    }
                }.accessibilityHidden(true)
                if progress.isRewardDay {
                    if progress.streak != progress.rewardMilestone {
                        Text("已达成连续 \(progress.rewardMilestone) 天挑战！")
                            .font(.title2.bold())
                    }
                    Text("你可以兑换 \(StreakRewardProgress.rewardYuan) 元零花钱啦！")
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    Text("把这个页面给爸爸看，领取你的奖励吧！")
                        .font(.title2.bold())
                    if progress.streak != progress.rewardMilestone {
                        Text(progress.countdown).font(.title3)
                    }
                } else {
                    Text(progress.countdown).font(.title2.weight(.semibold))
                }
                Text("每连续 7 天兑换一次 · 每次 3 元")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(accent.opacity(progress.isRewardDay ? 0.16 : 0.08),
                        in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(accent.opacity(progress.isRewardDay ? 0.8 : 0.3), lineWidth: progress.isRewardDay ? 3 : 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("streakRewardCard.\(moduleName)")
        }
    }
}

#Preview("每日提醒") {
    StreakRewardCard(moduleName: "简单记", streak: 3).padding()
}

#Preview("第七天兑换") {
    StreakRewardCard(moduleName: "简单算", streak: 7).padding()
}

#Preview("下一轮提醒") {
    StreakRewardCard(moduleName: "简单记", streak: 8).padding()
}

#Preview("补做跨过第七天") {
    StreakRewardCard(moduleName: "简单算", progress: StreakRewardProgress(streak: 9, previousStreak: 6)).padding()
}
#endif
