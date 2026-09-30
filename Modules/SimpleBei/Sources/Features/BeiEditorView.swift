import SwiftUI

struct BeiEditorView: View {
    let store: BeiLibraryStore
    let original: Passage?
    @State private var title: String
    @State private var bodyText: String
    @State private var language: PassageLanguage
    @State private var layout: PassageLayout
    @State private var draft: Passage?
    @State private var error: String?
    @State private var divideIndex: Int?
    @State private var divideCount = 1
    @Environment(\.dismiss) private var dismiss

    init(store: BeiLibraryStore, original: Passage?) {
        self.store = store; self.original = original
        _title = State(initialValue: original?.title ?? "")
        _bodyText = State(initialValue: original?.body ?? "")
        _language = State(initialValue: original?.language ?? .chinese)
        _layout = State(initialValue: original?.layout ?? .prose)
        _draft = State(initialValue: original)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("课文内容") {
                    TextField("标题（可留空自动生成）", text: $title)
                    Text("标题不参与背诵；需要背标题时，请将它放入正文。") .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $bodyText).frame(minHeight: 220).font(.title3).accessibilityLabel("课文正文")
                    Picker("语言", selection: $language) { ForEach(PassageLanguage.allCases) { Text($0.title).tag($0) } }
                    Button("根据正文建议语言") { language = PassageText.suggestedLanguage(bodyText) }
                    Picker("排版", selection: $layout) { ForEach(PassageLayout.allCases) { Text($0.title).tag($0) } }
                    Button("预览／重新分句") { preview() }.disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let draft {
                    Section("分句预览（\(draft.units.count) 句）") {
                        Text("原文保持不变。可合并相邻句，或选择一个完整字符后的分句位置。") .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(draft.units.enumerated()), id: \.element.id) { index, unit in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(index + 1). \(unit.text(in: draft.body))")
                                HStack {
                                    if unit.text(in: draft.body).count > 1 {
                                        Button("拆分") { divideIndex = index; divideCount = 1 }.buttonStyle(.bordered)
                                    }
                                    if index + 1 < draft.units.count {
                                        Button("与下一句合并") { mutate { try PassageText.merge(index, in: &$0) } }.buttonStyle(.bordered)
                                    }
                                }
                                if divideIndex == index {
                                    let text = unit.text(in: draft.body)
                                    Stepper("第 \(divideCount) 个字之后", value: $divideCount, in: 1...max(1, text.count - 1))
                                    Text("\(text.prefix(divideCount)) │ \(text.dropFirst(divideCount))").foregroundStyle(.secondary)
                                    Button("确认拆分") {
                                        mutate { try PassageText.divide(index, afterCharacters: divideCount, in: &$0) }
                                        divideIndex = nil
                                    }.buttonStyle(.borderedProminent)
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                }
                if let error = error ?? store.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(original == nil ? "添加课文" : "编辑课文")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("放弃编辑") { dismiss() }.disabled(store.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }.disabled(draft == nil || store.busy)
                        .accessibilityIdentifier("bei.save")
                }
            }
            .disabled(store.busy)
        }
        .interactiveDismissDisabled()
        .onChange(of: bodyText) { _, _ in draft = nil; divideIndex = nil }
        .onChange(of: language) { _, _ in draft = nil; divideIndex = nil }
        .onChange(of: layout) { _, _ in draft = nil; divideIndex = nil }
    }
    private func preview() {
        do {
            var passage = try PassageText.make(title: title, body: bodyText, language: language, layout: layout)
            if let original {
                passage.id = original.id; passage.archived = original.archived
                if original.body == bodyText {
                    for index in passage.units.indices {
                        let unit = passage.units[index]
                        if let previous = original.units.first(where: { $0.location == unit.location && $0.length == unit.length && $0.paragraph == unit.paragraph }) {
                            passage.units[index].id = previous.id
                        }
                    }
                }
            }
            draft = passage; error = nil; divideIndex = nil
        } catch { self.error = error.localizedDescription }
    }
    private func mutate(_ mutation: (inout Passage) throws -> Void) {
        guard var value = draft else { return }
        do { try mutation(&value); draft = value; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard var value = draft else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.title = cleanTitle.isEmpty ? String(value.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)) : cleanTitle
        value.editedAt = Date()
        if let original {
            let changed = value.body != original.body || value.language != original.language || value.layout != original.layout || value.units != original.units
            value.contentVersion = original.contentVersion + (changed ? 1 : 0)
        }
        if await store.save(value) { dismiss() }
    }
}
