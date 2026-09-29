import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var rawText = ""
    @State private var preview: ImportPreview?
    @State private var errorMessage: String?
    @State private var allowDuplicate = false
    @State private var inspectedText: String?
    @FocusState private var isEditingText: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("粘贴题库") {
                    TextEditor(text: $rawText)
                        .frame(height: 160)
                        .focused($isEditingText)
                        .accessibilityIdentifier("lian.import.text")
                        .font(.system(.body, design: .monospaced))
                    HStack {
                        PasteButton(payloadType: String.self) { values in rawText = values.first ?? ""; inspect() }
                        Text(rawText.isEmpty ? "粘贴完整 JSON 后检查即可，无需滚到文本末尾。" : "已粘贴 \(rawText.count) 个字符")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let preview {
                    Section("导入预览") {
                        LabeledContent("标题", value: preview.payload.batchTitle)
                        LabeledContent("题型", value: "\(preview.groupCount)")
                        LabeledContent("扩展题", value: "\(preview.variantCount)")
                        if preview.isDuplicate {
                            Toggle("仍然作为副本导入", isOn: $allowDuplicate)
                            Text("已存在内容相同的题库。默认会阻止重复导入。")
                                .foregroundStyle(.orange)
                        }
                    }
                    if !preview.report.issues.isEmpty {
                        Section("检查结果") {
                            ForEach(preview.report.issues) { issue in
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(issue.message)
                                        Text(issue.location).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 16) {
                    Button("检查内容", action: inspect)
                        .buttonStyle(.bordered)
                        .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("lian.import.inspect")
                    Spacer()
                    Button("确认导入") {
                        if let preview { commit(preview) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canImport)
                    .accessibilityIdentifier("lian.import.confirm")
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            }
            .onChange(of: rawText) { _, text in
                if text != inspectedText {
                    preview = nil
                    allowDuplicate = false
                    errorMessage = nil
                }
            }
            .navigationTitle("导入题库")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .alert("导入失败", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
                Button("好") { errorMessage = nil }
            } message: { Text($0) }
        }
    }

    private var canImport: Bool {
        guard let preview, rawText == inspectedText else { return false }
        return preview.report.canImport && (!preview.isDuplicate || allowDuplicate)
    }

    private func inspect() {
        isEditingText = false
        allowDuplicate = false
        inspectedText = rawText
        do { preview = try ImportService.preview(text: rawText, context: context); errorMessage = nil }
        catch { preview = nil; errorMessage = error.localizedDescription }
    }

    private func commit(_ preview: ImportPreview) {
        do { try ImportService.commit(preview, context: context, allowDuplicate: allowDuplicate); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}
