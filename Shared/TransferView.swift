import SwiftUI
import UniformTypeIdentifiers

private struct TransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

public struct TransferView: View {
    private let title: String
    private let exportData: @MainActor () async throws -> Data
    private let preview: @MainActor (Data) throws -> String
    private let restore: @MainActor (Data) async throws -> Void
    @EnvironmentObject private var session: ModuleSession
    @State private var document: TransferDocument?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var pending: Data?
    @State private var summary = ""
    @State private var confirmsRestore = false
    @State private var message: String?
    @State private var busy = false

    public init(title: String, exportData: @escaping @MainActor () async throws -> Data,
                preview: @escaping @MainActor (Data) throws -> String,
                restore: @escaping @MainActor (Data) async throws -> Void) {
        self.title = title; self.exportData = exportData; self.preview = preview; self.restore = restore
    }

    public var body: some View {
        Form {
            Section("完整备份") {
                Button("导出完整备份") { Task { await performExport() } }
                Button("从备份恢复") { showsImporter = true }
                Text("恢复只替换\(title)的数据，其它功能区不受影响。恢复前会自动保存本模块的安全备份。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView("正在处理…") }
        }
        .disabled(busy)
        .navigationTitle("\(title)数据")
        .fileExporter(isPresented: $showsExporter, document: document, contentType: .json,
                      defaultFilename: "\(title)-备份") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                summary = try preview(data); pending = data; confirmsRestore = true
            } catch { message = error.localizedDescription }
        }
        .alert("替换\(title)的数据？", isPresented: $confirmsRestore) {
            Button("取消", role: .cancel) { pending = nil }
            Button("恢复并替换", role: .destructive) { Task { await performRestore() } }
        } message: { Text(summary) }
        .alert("数据操作", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
        .onChange(of: busy) { _, value in session.setBusy(value, reason: "transfer") }
        .onDisappear { session.setBusy(false, reason: "transfer") }
    }

    @MainActor private func performExport() async {
        busy = true; session.setBusy(true, reason: "transfer")
        defer { busy = false; session.setBusy(false, reason: "transfer") }
        do { document = TransferDocument(data: try await exportData()); showsExporter = true }
        catch { message = error.localizedDescription }
    }

    @MainActor private func performRestore() async {
        guard let data = pending else { return }
        busy = true; session.setBusy(true, reason: "transfer")
        defer { busy = false; session.setBusy(false, reason: "transfer") }
        do { try await restore(data); pending = nil; message = "恢复完成。" }
        catch { message = "恢复失败：\(error.localizedDescription)" }
    }
}
