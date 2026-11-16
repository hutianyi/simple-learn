import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var showsFilePicker = false
    @State private var selectedURLs: [URL] = []
    @State private var selectionID = UUID()
    @State private var files: [FileImportPreview] = []
    @State private var isReading = false
    @State private var didImport = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("选择题库文件") {
                    Button("选择文件", systemImage: "folder") { showsFilePicker = true }
                        .disabled(isReading)
                        .accessibilityIdentifier("lian.import.files")
                    Text("在 iCloud 云盘的“简单练复习题”文件夹中选择 TXT 或 JSON 文件，可一次多选。每份文件单独添加，原文件会保留。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if isReading { ProgressView("正在读取并检查文件…") }
                }
                if !files.isEmpty {
                    Section(didImport ? "导入结果" : "导入预览") {
                        Text(summary).accessibilityIdentifier("lian.import.summary")
                        if !didImport {
                            Text("重复和错误文件会跳过，其他正常文件可继续导入。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(files) { file in
                        ImportFileRow(file: file)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    if didImport {
                        Button("完成") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("lian.import.done")
                    } else {
                        Button("确认导入（\(readyCount) 份）", action: commit)
                            .buttonStyle(.borderedProminent)
                            .disabled(isReading || readyCount == 0)
                            .accessibilityIdentifier("lian.import.confirm")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            }
            .navigationTitle("导入题库")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didImport ? "关闭" : "取消") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.plainText, .json], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    files = []
                    didImport = false
                    isReading = true
                    selectedURLs = urls
                    selectionID = UUID()
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .task(id: selectionID) {
                guard !selectedURLs.isEmpty else { return }
                isReading = true
                let previews = await ImportService.previewFiles(selectedURLs, context: context)
                guard !Task.isCancelled else { return }
                files = previews
                isReading = false
            }
            .alert("无法选择文件", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var readyCount: Int { files.filter { $0.status == .ready }.count }

    private var summary: String {
        let duplicates = files.filter { $0.status == .duplicate }.count
        let invalid = files.filter { $0.status == .invalid || $0.status == .failed }.count
        if didImport {
            let imported = files.filter { $0.status == .imported }.count
            return "已导入 \(imported) 份 · 重复跳过 \(duplicates) 份 · 错误 \(invalid) 份"
        }
        return "可导入 \(readyCount) 份 · 重复 \(duplicates) 份 · 错误 \(invalid) 份"
    }

    private func commit() {
        files = ImportService.commitFiles(files, context: context)
        didImport = true
    }
}

private struct ImportFileRow: View {
    let file: FileImportPreview

    var body: some View {
        Section {
            Label(statusLabel, systemImage: statusIcon).foregroundStyle(statusColor)
            if let preview = file.preview {
                LabeledContent("标题", value: preview.payload.batchTitle)
                LabeledContent("题型", value: "\(preview.groupCount)")
                LabeledContent("扩展题", value: "\(preview.variantCount)")
            }
            if let message = file.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let preview = file.preview {
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
        } header: {
            Text(file.fileName).textCase(nil)
        }
    }

    private var statusLabel: String {
        switch file.status {
        case .ready: "可以导入"
        case .duplicate: "重复文件，自动跳过"
        case .invalid: "文件有错误"
        case .imported: "导入成功"
        case .failed: "导入失败"
        }
    }

    private var statusIcon: String {
        switch file.status {
        case .ready, .imported: "checkmark.circle.fill"
        case .duplicate: "arrow.uturn.forward.circle"
        case .invalid, .failed: "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .ready, .imported: .green
        case .duplicate: .orange
        case .invalid, .failed: .red
        }
    }
}
