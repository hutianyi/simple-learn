import SwiftUI

struct PlayerView: View {
    let speech: SpeechService
    let showCurrent: () -> Void
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
                Label("Sleep Timer · \(speech.timerMinutes.map { "\($0) 分钟" } ?? "关闭")", systemImage: "moon.zzz")
            }
            .buttonStyle(.bordered)
            .disabled(speech.playback.state == .stopping)
            .accessibilityLabel("睡眠定时")
            .accessibilityValue(speech.timerMinutes.map { "\($0) 分钟" } ?? "关闭")
            .accessibilityIdentifier("listen.sleepTimer")
            HStack(spacing: 12) {
                Text(speech.playback.state.title)
                Text(speech.settings.order.title)
                Text(speech.settings.rate.title)
                if speech.settings.loopEnabled { Text("全库循环") }
                if speech.playback.timerEndDate != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let seconds = speech.playback.secondsRemaining ?? 0
                        Text("定时 \(seconds / 60):\(String(format: "%02d", seconds % 60))").monospacedDigit()
                    }
                }
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
}
