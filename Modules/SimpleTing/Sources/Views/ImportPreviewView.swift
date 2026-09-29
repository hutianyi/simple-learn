import SwiftUI
import StudyShell

struct ListenPasteImportView: View {
    let store: LibraryStore
    let speech: SpeechService
    let didImport: (UUID) -> Void
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var editing: Bool
    @EnvironmentObject private var session: ModuleSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("每次粘贴一份完整 Markdown。自动提取文章标题和正文，跳过题目、答案和来源；先导入的更早，后导入的更新。")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Text("文章原文").font(.headline)
                    Spacer()
                    PasteButton(payloadType: String.self) { values in
                        text = values.joined(separator: "\n")
                        error = nil
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("listen.paste")
                }
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .focused($editing)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("在这里粘贴 Markdown 全文……")
                                .foregroundStyle(.secondary).padding(16).allowsHitTesting(false)
                        }
                    }
                    .disabled(saving)
                    .accessibilityLabel("粘贴 Markdown 原文")
                    .accessibilityIdentifier("listen.importText")
                if let error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("listen.importError") }
                if speech.playback.hasSession {
                    HStack {
                        Text("保存前请先停止播放。") .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("停止播放") { speech.stop() }.disabled(speech.playback.state == .stopping || saving)
                    }
                }
                Button(action: importText) {
                    HStack {
                        if saving { ProgressView().tint(.white) }
                        Text(saving ? "正在导入……" : "解析并导入").font(.headline)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || speech.playback.hasSession)
                .accessibilityIdentifier("listen.confirmImport")
            }
            .padding(20)
            .navigationTitle("导入文章")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
        }
    }

    private func importText() {
        guard !saving, !speech.playback.hasSession else { return }
        let source = text
        saving = true; error = nil; editing = false
        session.setBusy(true, reason: "ting.import")
        Task { @MainActor in
            defer { saving = false; session.setBusy(false, reason: "ting.import") }
            do {
                let draft = try await MarkdownImportService.parsePastedText(source)
                // Playback may have changed while parsing; never mutate a live queue.
                guard !speech.playback.hasSession else { throw ListenError.message("请先停止播放，再导入文章。") }
                try store.commit([draft])
                speech.replaceLibrary(store.library)
                if let material = store.library.days.first(where: { $0.sourceKey == draft.sourceKey }) {
                    didImport(material.id)
                }
                speech.message = "已导入 \(draft.articles.count) 篇文章。"
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
