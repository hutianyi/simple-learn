import Foundation

public struct StreakRewardProgress: Equatable {
    public static let daysPerReward = 7
    public static let rewardYuan = 3
    public let streak: Int

    public init(streak: Int) { self.streak = max(0, streak) }

    public var isRewardDay: Bool { streak > 0 && streak % Self.daysPerReward == 0 }
    public var daysRemaining: Int { isRewardDay ? 0 : Self.daysPerReward - streak % Self.daysPerReward }
    public var cycleDays: Int { isRewardDay ? Self.daysPerReward : streak % Self.daysPerReward }

    public var countdown: String {
        let again = streak >= Self.daysPerReward ? "再次" : ""
        return "再坚持 \(daysRemaining) 天，就可以找爸爸\(again)兑换 \(Self.rewardYuan) 元零花钱！"
    }
}

#if os(iOS)
import SwiftUI

public struct StreakRewardCard: View {
    private let moduleName: String
    private let progress: StreakRewardProgress
    private var accent: Color { progress.isRewardDay ? .orange : .purple }

    public init(moduleName: String, streak: Int) {
        self.moduleName = moduleName
        self.progress = StreakRewardProgress(streak: streak)
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
                    Text("你可以兑换 \(StreakRewardProgress.rewardYuan) 元零花钱啦！")
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    Text("把这个页面给爸爸看，领取你的奖励吧！")
                        .font(.title2.bold())
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
#endif
