import CoreData
import SwiftUI

struct AddWordsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case single = "单个添加"
        case batch = "批量导入"

        var id: String { rawValue }
    }

    @StateObject private var viewModel = AddWordsViewModel()
    @State private var mode: Mode = .batch
    private let repository: VocabularyRepository

    init(container: NSPersistentContainer) {
        repository = VocabularyRepository(container: container)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("添加方式", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .single {
                    singleForm
                } else {
                    batchForm
                }
            }
            .frame(maxWidth: 760)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(AppPalette.background.ignoresSafeArea())
        .navigationTitle("添加单词")
        .navigationBarTitleDisplayMode(.inline)
        .alert("导入完成", isPresented: resultBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.resultMessage ?? "")
        }
        .alert("无法完成", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var singleForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            fieldLabel("英文")
            TextField("例如：apple", text: $viewModel.singleEnglish)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .accessibilityIdentifier("addWords.english")

            fieldLabel("中文")
            TextField("例如：苹果", text: $viewModel.singleChinese)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .accessibilityIdentifier("addWords.chinese")

            Button {
                Task { await viewModel.addSingle(using: repository) }
            } label: {
                if viewModel.isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text("添加")
                }
            }
            .buttonStyle(LargePrimaryButtonStyle())
            .accessibilityIdentifier("addWords.add")
            .disabled(
                viewModel.isWorking
                    || viewModel.singleEnglish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.singleChinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(22)
        .background(AppPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var batchForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("粘贴 Markdown 或纯文本总词库")
                .font(.headline)

            TextEditor(text: $viewModel.batchText)
                .font(.body.monospaced())
                .frame(minHeight: 260)
                .padding(10)
                .background(AppPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.textSecondary.opacity(0.22))
                )
                .onChange(of: viewModel.batchText) { _ in viewModel.inputChanged() }

            Text("支持标题、项目符号、Tab、空格、短横线，以及 ice cream 冰淇淋这类词组。分析前不会写入数据库。")
                .font(.footnote)
                .foregroundStyle(AppPalette.textSecondary)

            Button {
                Task { await viewModel.analyzeBatch(using: repository) }
            } label: {
                if viewModel.isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text("分析")
                }
            }
            .buttonStyle(LargePrimaryButtonStyle())
            .disabled(viewModel.isWorking || viewModel.batchText.isEmpty)

            if let analysis = viewModel.analysis {
                analysisView(analysis)
            }
        }
    }

    private func analysisView(_ analysis: ImportAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("分析结果")
                .font(.title3.weight(.bold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                summaryTile("扫描", value: analysis.totalLineCount, tint: AppPalette.textSecondary)
                summaryTile("识别", value: analysis.recognizedCount, tint: AppPalette.accent)
                summaryTile("新增", value: analysis.additions.count, tint: .green)
                summaryTile("已存在", value: analysis.existing.count, tint: .secondary)
                summaryTile("冲突", value: analysis.conflicts.count, tint: .orange)
                summaryTile("无法识别", value: analysis.unrecognized.count, tint: .red)
            }

            if !analysis.additions.isEmpty {
                DisclosureGroup("查看新增（\(analysis.additions.count)）") {
                    entryRows(analysis.additions)
                }
            }

            if !analysis.conflicts.isEmpty || !analysis.unrecognized.isEmpty {
                DisclosureGroup("查看问题（\(analysis.conflicts.count + analysis.unrecognized.count)）") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(analysis.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("第 \(conflict.incoming.lineNumber) 行：\(conflict.incoming.english)")
                                    .font(.subheadline.weight(.semibold))
                                Text("已有：\(conflict.existingChinese)；导入：\(conflict.incoming.chinese)")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                        ForEach(analysis.unrecognized) { issue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("第 \(issue.lineNumber) 行：\(issue.text)")
                                    .font(.subheadline.weight(.semibold))
                                Text(issue.reason)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }

            Button {
                Task { await viewModel.importAnalyzedAdditions(using: repository) }
            } label: {
                Text("导入 \(analysis.additions.count) 个新单词")
            }
            .buttonStyle(LargePrimaryButtonStyle())
            .disabled(viewModel.isWorking || !analysis.canImport)
        }
        .padding(20)
        .background(AppPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func entryRows(_ entries: [ParsedVocabularyEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.english).fontWeight(.semibold)
                    Spacer(minLength: 12)
                    Text(entry.chinese).foregroundStyle(AppPalette.textSecondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 8)
    }

    private func summaryTile(_ title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppPalette.textSecondary)
            Text("\(value)")
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value).font(.headline)
    }

    private var resultBinding: Binding<Bool> {
        Binding(
            get: { viewModel.resultMessage != nil },
            set: { if !$0 { viewModel.resultMessage = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}
