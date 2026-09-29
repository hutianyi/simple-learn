import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import StudyShell

struct DataView: View {
    @Environment(\.modelContext) private var context
    @State private var exportDocument: BackupDocument?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var pendingBackup: SimpleLianBackup?
    @State private var confirmsRestore = false
    @State private var message: Message?

    var body: some View {
        NavigationStack {
            Form {
                Section("完整备份") {
                    Button("导出备份", systemImage: "square.and.arrow.up", action: prepareExport)
                    Button("从备份恢复", systemImage: "square.and.arrow.down") { showsImporter = true }
                    Text("备份包含题库、复习状态、练习记录与未完成会话。恢复会替换简单练模块内的全部数据。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("数据位置", value: "仅保存在本机")
                    LabeledContent("复习规则", value: "做对 3 次后掌握")
                }
            }
            .navigationTitle("数据")
            .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .json, defaultFilename: "简单练备份-\(DayKey.make(from: .now))") { result in
                if case .failure(let error) = result { message = .init(title: "导出失败", detail: error.localizedDescription) }
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    pendingBackup = try BackupService.validate(Data(contentsOf: url))
                    confirmsRestore = true
                } catch { message = .init(title: "无法读取备份", detail: error.localizedDescription) }
            }
            .confirmationDialog("用备份替换简单练的数据？", isPresented: $confirmsRestore, titleVisibility: .visible) {
                Button("恢复并替换", role: .destructive, action: restore)
            } message: { Text("建议先导出一份当前备份。") }
            .alert(item: $message) { Alert(title: Text($0.title), message: Text($0.detail), dismissButton: .default(Text("好"))) }
        }
    }

    private func prepareExport() {
        do { exportDocument = BackupDocument(data: try BackupService.exportData(context: context)); showsExporter = true }
        catch { message = .init(title: "导出失败", detail: error.localizedDescription) }
    }
    private func restore() {
        guard let pendingBackup else { return }
        do {
            try ModuleStorage.saveSafetyBackup(BackupService.exportData(context: context), module: "SimpleLian")
            try BackupService.restore(pendingBackup, context: context); self.pendingBackup = nil; message = .init(title: "恢复完成", detail: "题库和学习进度已经恢复。") }
        catch { message = .init(title: "恢复失败", detail: error.localizedDescription) }
    }
}

private struct Message: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}
