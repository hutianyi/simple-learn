import SwiftUI
import UniformTypeIdentifiers

private struct BeiBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BeiError.invalid("无法读取备份。") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BeiBackupView: View {
    let store: BeiLibraryStore
    @State private var importing = false
    @State private var exporting = false
    @State private var document: BeiBackupDocument?
    @State private var preview: BeiImportPreview?
    @State private var useSettings = false
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("课文备份") {
                    Text("备份包含课文、分句和常用播放／显示设置。不含录音、识别文本或成绩。")
                    Text("当前共 \(store.library.passages.count) 篇课文（包含归档）。")
                    Button("导出课文备份", systemImage: "square.and.arrow.up") {
                        do { document = BeiBackupDocument(data: try BeiBackup(library: store.library).encoded()); exporting = true }
                        catch { store.error = error.localizedDescription }
                    }
                    Button("选择课文备份，预览追加导入", systemImage: "square.and.arrow.down") { importing = true }
                }
                if let preview {
                    Section("导入预览") {
                        Text("新增 \(preview.additions.count) 篇 · 重复 \(preview.duplicates) 篇 · 冲突 \(preview.conflicts) 篇")
                        Text("重复跳过；冲突保留当前课文。确认后一次性追加，原课文不会被替换。") .foregroundStyle(.secondary)
                        Toggle("同时使用备份中的播放与显示设置", isOn: $useSettings)
                        Button("确认追加导入") {
                            Task {
                                if await store.apply(preview, useSettings: useSettings) {
                                    notice = "已追加 \(preview.additions.count) 篇，重复与冲突均保留当前数据。"
                                    self.preview = nil
                                }
                            }
                        }.buttonStyle(.borderedProminent)
                        Button("放弃本次导入") { self.preview = nil }
                    }
                }
                if let notice { Section { Text(notice) } }
                if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            }.disabled(store.busy)
            .navigationTitle("课文备份")
            .toolbar { Button("完成") { dismiss() }.disabled(store.busy || importing || exporting) }
        }
        .interactiveDismissDisabled()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { preview = await store.previewBackup(url); useSettings = false }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "简单背课文备份") { result in
            switch result { case .success: notice = "课文备份已导出。"; case .failure(let error): store.error = error.localizedDescription }
        }
    }
}
