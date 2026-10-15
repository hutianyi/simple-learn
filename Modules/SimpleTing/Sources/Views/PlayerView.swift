import SwiftUI

struct PlayerView: View {
    let speech: SpeechService
    let showCurrent: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var unavailable: Bool { speech.playback.article == nil || speech.playback.state == .stopping }
    var body: some View {
        VStack(spacing: 12) {
            if let article = speech.playback.article, let day = speech.playback.day {
                Button(action: showCurrent) {
                    VStack(spacing: 4) {
                        Text("第 \(day.importSequence) 次导入 · Article \(article.articleNumber) · \(day.articles.count) 篇").font(.caption).foregroundStyle(.secondary)
                        Text(article.title).font(.headline).lineLimit(2)
                    }
                }.buttonStyle(.plain)
            }
            HStack(spacing: 30) {
                Button { speech.move(-1) } label: { Image(systemName: "backward.end.fill").font(.title2) }
                    .disabled(unavailable || !speech.playback.canGoPrevious)
                    .accessibilityLabel("上一篇").accessibilityIdentifier("listen.previous")
                Button { speech.togglePlayback() } label: {
                    if speech.playback.state == .preparing || speech.playback.state == .stopping { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: speech.playback.state == .playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 48)) }
                }
                .disabled(unavailable || speech.playback.state == .preparing)
                .accessibilityLabel(speech.playback.state == .playing ? "暂停" : "播放或继续").accessibilityIdentifier("listen.play")
                Button { speech.move(1) } label: { Image(systemName: "forward.end.fill").font(.title2) }
                    .disabled(unavailable).accessibilityLabel("下一篇").accessibilityIdentifier("listen.next")
                Button("停止", systemImage: "stop.fill") { speech.stop() }
                    .disabled(!speech.playback.hasSession || speech.playback.state == .stopping)
                    .accessibilityIdentifier("listen.stop")
            }
            sleepTimer
            HStack(spacing: 12) {
                Text(speech.playback.state.title)
                Text(speech.settings.order.title)
                Text(speech.settings.rate.title)
                if speech.settings.loopEnabled { Text("全库循环") }
            }.font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let notice = speech.voiceNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
            if let message = speech.message {
                HStack {
                    Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    Button { speech.message = nil } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("关闭提示")
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity).background(.bar)
    }

    private var sleepTimer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = speech.playback.secondsRemaining.map { seconds in
                let time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                let status = speech.playback.state == .playing ? "" : (speech.playback.state == .paused ? " · 已暂停" : " · 等待播放")
                return "剩余 \(time)\(status)"
            } ?? "关闭"
            Menu {
                Button("关闭定时", systemImage: "xmark.circle") { speech.setSleepTimer(nil) }
                Divider()
                ForEach([10, 15, 20, 30, 60], id: \.self) { minutes in
                    Button { speech.setSleepTimer(minutes) } label: {
                        if speech.timerMinutes == minutes { Label("\(minutes) 分钟", systemImage: "checkmark") }
                        else { Text("\(minutes) 分钟") }
                    }
                }
            } label: {
                Label("Sleep Timer · \(remaining)", systemImage: "moon.zzz")
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(speech.playback.state == .stopping)
            .accessibilityLabel("睡眠定时")
            .accessibilityValue(remaining)
            .accessibilityIdentifier("listen.sleepTimer")
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: speech.timerMinutes != nil)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: speech.playback.state)
        }
    }
}
