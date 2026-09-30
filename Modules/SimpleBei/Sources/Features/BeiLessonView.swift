import SwiftUI

struct BeiLessonView: View {
    let passage: Passage
    let store: BeiLibraryStore
    @Bindable var study: BeiStudySession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric private var scaledTextSize = 24.0
    @State private var heldSentence: UUID?
    @State private var follow = true
    @State private var practiceSentenceCenters: [UUID: CGFloat] = [:]
    @State private var preferences = BeiPreferences()
    private var audio: BeiLearningAudio { study.audio }
    private var recording: BeiRecordingSession { study.recording }
    private var textSize: Double { preferences.fontSize * scaledTextSize / 24 }
    private var rangeFirst: Int { study.mode == .practice ? 0 : min(max(0, study.first), max(0, passage.units.count - 1)) }
    private var rangeLast: Int { study.mode == .practice ? max(0, passage.units.count - 1) : min(max(rangeFirst, study.last), max(0, passage.units.count - 1)) }
    private var learning: Bool { audio.active }

    var body: some View {
        Group {
            if study.mode == .practice { practiceLayout }
            else if study.mode == .test { testLayout }
            else { scrollingLessonLayout }
        }
        .navigationBarTitleDisplayMode(study.mode == .practice ? .inline : .automatic)
        .task(id: "\(passage.id).\(passage.contentVersion)") {
            study.select(passage); preferences = store.library.preferences; follow = true
        }
        .onChange(of: study.mode) { _, _ in heldSentence = nil }
        .onChange(of: store.library.preferences) { _, value in preferences = value }
        .onChange(of: study.first) { _, value in if study.last < value { study.last = value } }
    }

    private var modePicker: some View {
        Picker("学习方式", selection: Binding(get: { study.mode }, set: { value in Task { await study.changeMode(value) } })) {
            ForEach(BeiStudySession.Mode.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).disabled(study.switching)
    }

    private var scrollingLessonLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    modePicker
                    rangePicker
                    listeningControls
                    messages
                    ForEach(Array(passage.units.enumerated()).filter { (rangeFirst...rangeLast).contains($0.offset) }, id: \.element.id) { index, unit in
                        sentenceRow(index, unit).id(index)
                    }
                }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 15).onChanged { _ in follow = false })
            .onChange(of: audio.current) { _, index in
                if follow, audio.active { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }

    private var practiceLayout: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                modePicker
                practiceControls
                messages
            }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
            Divider()
            practiceSentenceList.id(passage.id)
        }
    }

    private var practiceSentenceList: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                let focus = PracticeFocus(
                    passageID: passage.id, contentVersion: passage.contentVersion,
                    unitID: passage.units.indices.contains(audio.current) ? passage.units[audio.current].id : nil,
                    naturalCenter: passage.units.indices.contains(audio.current) ? practiceSentenceCenters[passage.units[audio.current].id] : nil,
                    active: audio.active, phase: String(describing: audio.state), hint: study.hintLevel.rawValue,
                    width: geometry.size.width, height: geometry.size.height, textSize: textSize)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(passage.units.enumerated()), id: \.element.id) { index, unit in
                            sentenceRow(index, unit)
                                .background {
                                    GeometryReader { card in
                                        Color.clear.preference(key: PracticeSentenceCenters.self,
                                            value: [unit.id: card.frame(in: .named("bei.practice.content")).midY])
                                    }
                                }
                                .id(unit.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    // Only the end needs extra room; opening sentences keep their natural positions.
                    .padding(.bottom, geometry.size.height / 2)
                    .frame(maxWidth: 900).frame(maxWidth: .infinity)
                    .coordinateSpace(name: "bei.practice.content")
                    .id("bei.practice.start")
                }
                .accessibilityIdentifier("bei.practice.sentences")
                .onPreferenceChange(PracticeSentenceCenters.self) { centers in
                    practiceSentenceCenters.merge(centers, uniquingKeysWith: { _, latest in latest })
                }
                .task(id: focus) {
                    guard focus.active, let unitID = focus.unitID else { return }
                    // Center after the cards have laid out; a newer sentence cancels this request.
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { return }
                    guard !Task.isCancelled, audio.active, study.mode == .practice,
                          passage.units.indices.contains(audio.current), passage.units[audio.current].id == unitID else { return }
                    let beforeMiddle = audio.current == 0 || practiceSentenceCenters[unitID].map { $0 <= geometry.size.height / 2 } == true
                    let target: AnyHashable = beforeMiddle ? AnyHashable("bei.practice.start") : AnyHashable(unitID)
                    let anchor: UnitPoint = beforeMiddle ? .top : .center
                    if reduceMotion { proxy.scrollTo(target, anchor: anchor) }
                    else { withAnimation(.easeInOut(duration: 0.28)) { proxy.scrollTo(target, anchor: anchor) } }
                }
            }
        }
    }

    private struct PracticeFocus: Hashable {
        let passageID: UUID
        let contentVersion: Int
        let unitID: UUID?
        let naturalCenter: CGFloat?
        let active: Bool
        let phase: String
        let hint: String
        let width: CGFloat
        let height: CGFloat
        let textSize: Double
    }

    private struct PracticeSentenceCenters: PreferenceKey {
        static let defaultValue: [UUID: CGFloat] = [:]
        static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
            value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
        }
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
            Picker("从第几句", selection: Binding(get: { rangeFirst }, set: { study.first = $0 })) { ForEach(passage.units.indices, id: \.self) { Text("从第 \($0 + 1) 句").tag($0) } }
            Picker("到第几句", selection: Binding(get: { rangeLast }, set: { study.last = $0 })) { ForEach(rangeFirst..<passage.units.count, id: \.self) { Text("到第 \($0 + 1) 句").tag($0) } }
            Button("全文") { study.first = 0; study.last = passage.units.count - 1 }
            }
            Label("声音设置", systemImage: "gearshape")
                .foregroundStyle(.primary)
        }.disabled(study.active)
    }
    private var speechRateControl: some View {
        HStack {
            Text("语速")
            Slider(value: $preferences.speechRate, in: 0.1...0.65, step: 0.01) { editing in
                if !editing { Task { _ = await store.savePreferences(preferences) } }
            }
            Text(preferences.speechRate < 0.4 ? "慢" : (preferences.speechRate > 0.5 ? "快" : "正常"))
        }.disabled(study.active)
    }
    private var listeningControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            speechRateControl
            HStack(spacing: 24) {
                Picker("总遍数", selection: Binding(get: { preferences.totalPasses ?? 0 }, set: { preferences.totalPasses = $0 == 0 ? nil : $0 })) {
                    Text("1 遍").tag(1); Text("3 遍").tag(3); Text("5 遍").tag(5); Text("无限循环").tag(0)
                    if let count = preferences.totalPasses, ![1, 3, 5].contains(count) { Text("\(count) 遍").tag(count) }
                }
                Picker("定时停止", selection: $study.timerMinutes) {
                    Text("不定时").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) 分钟后停止").tag($0) }
                }
            }.disabled(study.active)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading, spacing: 12) {
                if !learning {
                    Button("开始朗读", systemImage: "play.fill") {
                        study.select(passage); study.startListening(preferences)
                        Task { _ = await store.savePreferences(preferences) }
                    }.buttonStyle(.borderedProminent).disabled(study.active)
                } else {
                    Button(audio.state == .paused ? "继续朗读" : "暂停", systemImage: audio.state == .paused ? "play.fill" : "pause.fill") {
                        if audio.state == .paused { audio.resume() } else { audio.pause() }
                    }.buttonStyle(.borderedProminent)
                    Button("上一句", systemImage: "backward.end") { audio.move(-1) }
                    Button("下一句", systemImage: "forward.end") { audio.move(1) }
                    Button("停止", systemImage: "stop.fill") { Task { await study.end() } }
                }
            }.disabled(study.switching || audio.state == .stopping)
            if learning {
                Text("第 \(audio.current + 1) 句 · 已完整听完 \(audio.completedPasses) 遍\(preferences.totalPasses.map { " / 共 \($0) 遍" } ?? " · 无限循环")")
                if let deadline = audio.timerDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("定时剩余 \(max(0, Int(deadline.timeIntervalSince(context.date)))) 秒（暂停时也计时）").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("每句、每段和每遍的停顿可在声音设置中调整。听读支持锁屏继续播放。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var practiceControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("朗读顺序", selection: $study.appFirst) {
                Text("先系统读").tag(true)
                Text("先自己背").tag(false)
            }.pickerStyle(.segmented).disabled(study.active)
            Text(study.appFirst ? "系统读一句，你跟读同一句，再进入下一句。" : "先自己背一句，背完点“听系统读这一句”核对；系统读完后再背下一句。")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("提示程度", selection: $study.hintLevel) { ForEach(BeiHintLevel.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text("长按某一句可以临时看原文，松手后恢复提示。练习不录音、不打分。") .font(.caption).foregroundStyle(.secondary)
            Label("声音设置", systemImage: "gearshape").foregroundStyle(.primary)
            speechRateControl
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 12) {
                Button {
                    if learning { audio.completeChildTurn() }
                    else { study.select(passage); study.startPractice(preferences) }
                } label: {
                    Text(learning ? (study.appFirst ? "这句读好了，下一句" : "听系统读这一句") : "开始练习")
                        .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("bei.practice.primary")
                .disabled(study.switching || (learning ? audio.state != .waiting : study.active))

                Button(audio.state == .paused ? "继续练习" : "暂停") {
                    if audio.state == .paused { audio.resume() } else { audio.pause() }
                }.disabled(!learning || study.switching || audio.state == .stopping)
                Button("再听当前句") { audio.repeatPracticeSentence() }
                    .disabled(audio.state != .waiting || study.switching)
                Button("结束练习") { Task { await study.end() } }
                    .disabled(!learning || study.switching || audio.state == .stopping)
                if study.appFirst {
                    Button("再给我 5 秒") { audio.extendWait() }
                        .disabled(audio.state != .waiting || audio.secondsToWait <= 0 || study.switching)
                }
            }
            Text(learning ? "当前第 \(audio.current + 1) 句 · \(audio.state == .waiting ? "轮到你背" : (audio.state == .paused ? "已暂停" : "听系统朗读"))\(audio.secondsToWait > 0 && audio.state == .waiting ? " · \(audio.secondsToWait) 秒" : "")" : "尚未开始练习")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)

        }
    }
    private var testLayout: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                modePicker
                testControls
                messages
            }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
            if recording.showsOriginal {
                Divider()
                ScrollView {
                    Text(passage.body)
                        .font(.system(size: textSize))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("bei.test.original")
                }
            } else { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private var testControls: some View {
        switch recording.state {
        case .idle:
            Button("开始背诵检查", systemImage: "mic.fill") {
                study.select(passage)
                Task { await study.startTest() }
            }.buttonStyle(.borderedProminent).disabled(study.active)
                .accessibilityIdentifier("bei.test.start")
        case .preparing: ProgressView("正在准备录音")
        case .recording, .recordingPaused:
            Label(recording.state == .recording ? "正在录音" : "录音已暂停", systemImage: "waveform")
            HStack {
                if recording.state == .recordingPaused {
                    Button("继续录音") { recording.resume() }
                }
                Button("背完了", systemImage: "checkmark") { recording.finish() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("bei.test.finish")
            }
        case .finishing: ProgressView("正在结束录音")
        case .review:
            HStack(spacing: 20) {
                Button(recording.playing ? "停止回听" : "回听录音", systemImage: recording.playing ? "stop.fill" : "play.fill") {
                    if recording.playing { recording.stopReplay() } else { recording.replay() }
                }.accessibilityIdentifier("bei.test.replay")
                Button("再背一次", systemImage: "mic.fill") { Task { await study.startTest() } }
                    .buttonStyle(.borderedProminent).disabled(study.switching)
                    .accessibilityIdentifier("bei.test.retry")
                Button("结束本次") { Task { await study.end() } }
                    .accessibilityIdentifier("bei.test.end")
            }
        case .stopping: ProgressView("正在结束本次背诵")
        case .cleanupFailed:
            Button("重试清理") { Task { await study.end() } }
        }
    }
    private func sentenceRow(_ index: Int, _ unit: PassageUnit) -> some View {
        let original = unit.text(in: passage.body)
        let level = study.mode == .practice ? study.hintLevel : .full
        let shown = heldSentence == unit.id ? original : level.display(original, language: passage.language)
        return HStack(alignment: .top, spacing: 16) {
            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                Text(original).hidden().accessibilityHidden(true)
                Text(shown).accessibilityLabel(level == .hidden && heldSentence != unit.id ? "第 \(index + 1) 句，原文已隐藏" : shown)
            }.font(.system(size: textSize)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14).background(audio.active && index == audio.current ? Color.accentColor.opacity(0.16) : Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.05, pressing: { pressed in
            if study.mode == .practice { heldSentence = pressed ? unit.id : nil }
        }, perform: {})
    }
    @ViewBuilder private var messages: some View {
        if let text = study.notice { Text(text).foregroundStyle(.secondary) }
        if let text = audio.notice, study.mode != .test { Text(text).foregroundStyle(.secondary) }
        if let text = recording.notice, study.mode == .test { Text(text).foregroundStyle(.secondary) }
        if let text = study.error { Text(text).foregroundStyle(.red) }
        if let text = audio.error, study.mode != .test { Text(text).foregroundStyle(.red) }
        if let text = recording.error, study.mode == .test { Text(text).foregroundStyle(.red) }
        if study.switching { ProgressView("正在停止当前会话") }
    }
}
