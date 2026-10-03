import SwiftUI
import UniformTypeIdentifiers
import StudyShell
import WordMemoryCards
import SimpleLian
import DictationApp
import SimpleSuan
import SimpleTing
import SimpleBei

@MainActor
enum WholeBackupService {
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static func coordinator() throws -> WholeBackupCoordinator {
        WholeBackupCoordinator(endpoints: [
            WholeBackupEndpoint(id: "SimpleJi", title: "简单记", export: { try await SimpleJiBackupTransfer.exportData() },
                validate: SimpleJiBackupTransfer.validate, restore: { try await SimpleJiBackupTransfer.restore($0) }),
            WholeBackupEndpoint(id: "SimpleSuan", title: "简单算", export: { try SimpleSuanBackupTransfer.exportData() },
                validate: SimpleSuanBackupTransfer.validate, restore: { try SimpleSuanBackupTransfer.restore($0) }),
            WholeBackupEndpoint(id: "SimpleTing", title: "简单听", export: { try SimpleTingBackupTransfer.exportData() },
                validate: SimpleTingBackupTransfer.validate, restore: { try SimpleTingBackupTransfer.restore($0) }),
            WholeBackupEndpoint(id: "SimpleLian", title: "简单练", export: { try SimpleLianBackupTransfer.exportData() },
                validate: SimpleLianBackupTransfer.validate, restore: { try SimpleLianBackupTransfer.restore($0) }),
            WholeBackupEndpoint(id: "SimpleBei", title: "简单背", export: { try SimpleBeiBackupTransfer.exportData() },
                validate: SimpleBeiBackupTransfer.validate, restore: { try SimpleBeiBackupTransfer.restore($0) }),
            WholeBackupEndpoint(id: "SimpleMo", title: "简单默", export: { try SimpleMoBackupTransfer.exportData() },
                validate: SimpleMoBackupTransfer.validate, restore: { try SimpleMoBackupTransfer.restore($0) })
        ], directory: try ModuleStorage.directory("WholeBackup"))
    }
}

private struct WholeBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct WholeBackupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wholeBackup.lastExport") private var lastExport = 0.0
    @State private var document: WholeBackupDocument?
    @State private var filename = "简单学-整体备份"
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    @State private var pending: WholeBackupEnvelope?
    @State private var confirmation = false
    @State private var summary: [String] = []
    @State private var previewLines: [String] = []
    @State private var message: String?
    @State private var needsRecovery = false
    let recoveryStateChanged: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("整体备份") {
                    Button("一键备份全部数据") { Task { await exportAll() } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("backup.exportAll")
                        .disabled(needsRecovery)
                    Text("包含六个模块已保存的数据、学习记录、进度和设置。不含简单背录音、临时缓存及系统语音资源。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if lastExport > 0 {
                        Text("上次成功导出：\(Date(timeIntervalSince1970: lastExport).formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !summary.isEmpty {
                    Section("当前数据") { ForEach(summary, id: \.self) { Text($0) } }
                }
                Section("整体恢复") {
                    Button("从整体备份恢复", systemImage: "square.and.arrow.down") { importing = true }
                        .disabled(needsRecovery).accessibilityIdentifier("backup.restoreAll")
                    Text("恢复将替换全部六个模块的数据和设置，包括简单背课文库。恢复前自动保存整体安全副本；失败时回退到原数据。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if needsRecovery {
                        Button("重试回退到恢复前数据") { Task { await recover() } }
                    }
                }
                if busy { ProgressView("正在处理，请稍候…") }
            }
            .disabled(busy || exporting || importing)
            .navigationTitle("备份与恢复")
            .toolbar { Button("完成") { dismiss() }.disabled(busy || exporting || importing || needsRecovery) }
        }
        .interactiveDismissDisabled(busy || exporting || importing || needsRecovery)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: filename) { result in
            switch result {
            case .success:
                lastExport = Date().timeIntervalSince1970
                message = "整体备份已导出。请妥善保存文件；App 本地安全副本不能替代外部备份。"
            case .failure(let error): if !isCancellation(error) { message = "导出失败：\(error.localizedDescription)" }
            }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task { await readBackup(result) }
        }
        .alert("恢复并替换全部数据？", isPresented: $confirmation) {
            Button("取消", role: .cancel) { pending = nil }
            Button("恢复并替换", role: .destructive) { Task { await restoreAll() } }
        } message: {
            Text("\(pending?.exportedAt.formatted(date: .abbreviated, time: .shortened) ?? "")\n\(previewLines.joined(separator: "\n"))\n当前六个模块的数据和设置将被替换。")
        }
        .alert("备份与恢复", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
        .task { await refreshSummary() }
    }
    @MainActor private func refreshSummary() async {
        busy = true
        defer { busy = false }
        do {
            let coordinator = try WholeBackupService.coordinator()
            needsRecovery = try coordinator.hasPendingRecovery()
            recoveryStateChanged(needsRecovery)
            if !needsRecovery {
                let backup = try await coordinator.snapshot(appVersion: WholeBackupService.appVersion)
                summary = try coordinator.preview(backup)
            }
        } catch { message = "读取备份范围失败：\(error.localizedDescription)" }
    }
    @MainActor private func exportAll() async {
        busy = true
        defer { busy = false }
        do {
            let coordinator = try WholeBackupService.coordinator()
            let backup = try await coordinator.snapshot(appVersion: WholeBackupService.appVersion)
            summary = try coordinator.preview(backup)
            document = WholeBackupDocument(data: try backup.encoded())
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            filename = "简单学-整体备份-\(formatter.string(from: backup.exportedAt))"
            exporting = true
        } catch { message = "备份失败：\(error.localizedDescription)" }
    }
    @MainActor private func readBackup(_ result: Result<URL, Error>) async {
        busy = true; pending = nil
        defer { busy = false }
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let backup = try WholeBackupEnvelope.decode(Data(contentsOf: url))
            previewLines = try WholeBackupService.coordinator().preview(backup)
            pending = backup; confirmation = true
        } catch { if !isCancellation(error) { message = "备份校验失败，原数据未改变：\(error.localizedDescription)" } }
    }
    @MainActor private func restoreAll() async {
        guard let backup = pending else { return }
        busy = true
        defer { busy = false; pending = nil }
        do {
            try await WholeBackupService.coordinator().restore(backup, appVersion: WholeBackupService.appVersion)
            summary = previewLines
            message = "整体恢复完成。六个模块的数据和设置已替换，恢复前安全副本已保留。"
        } catch {
            message = error.localizedDescription
            do { needsRecovery = try WholeBackupService.coordinator().hasPendingRecovery() }
            catch { needsRecovery = true; message = "\(message ?? "")\n恢复记录读取失败：\(error.localizedDescription)" }
            recoveryStateChanged(needsRecovery)
        }
    }
    @MainActor private func recover() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await WholeBackupService.coordinator().recoverIfNeeded()
            needsRecovery = false; recoveryStateChanged(false)
            message = "已回退到恢复前数据。"
            await refreshSummary()
        } catch { message = error.localizedDescription }
    }
    private func isCancellation(_ error: Error) -> Bool { (error as NSError).code == NSUserCancelledError }
}
