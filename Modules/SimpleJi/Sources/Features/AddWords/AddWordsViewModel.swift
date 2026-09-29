import Foundation

@MainActor
final class AddWordsViewModel: ObservableObject {
    @Published var batchText = ""
    @Published var singleEnglish = ""
    @Published var singleChinese = ""
    @Published private(set) var analysis: ImportAnalysis?
    @Published private(set) var isWorking = false
    @Published var resultMessage: String?
    @Published var errorMessage: String?

    func analyzeBatch(using repository: VocabularyRepository) async {
        let parseResult = VocabularyParser.parse(batchText)
        await analyze(parseResult, using: repository)
    }

    func addSingle(using repository: VocabularyRepository) async {
        let source = "\(singleEnglish)\t\(singleChinese)"
        let parseResult = VocabularyParser.parse(source)

        guard parseResult.entries.count == 1, parseResult.unrecognized.isEmpty else {
            errorMessage = "请输入至少包含一个英文字母的英文，以及至少包含一个汉字的中文释义。"
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let singleAnalysis = try await repository.analyze(parseResult)
            if let conflict = singleAnalysis.conflicts.first {
                errorMessage = "\(conflict.existingEnglish) 已存在，当前释义是“\(conflict.existingChinese)”。"
                return
            }
            guard !singleAnalysis.additions.isEmpty else {
                errorMessage = "\(parseResult.entries[0].english) 已经存在。"
                return
            }

            let result = try await repository.importAdditions(singleAnalysis.additions)
            singleEnglish = ""
            singleChinese = ""
            resultMessage = "成功新增 \(result.insertedWords) 个单词，并创建 \(result.createdReviewStates) 张双向复习卡。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importAnalyzedAdditions(using repository: VocabularyRepository) async {
        guard let analysis, !analysis.additions.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await repository.importAdditions(analysis.additions)
            resultMessage = "成功新增 \(result.insertedWords) 个单词，并创建 \(result.createdReviewStates) 张双向复习卡。"
            self.analysis = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func inputChanged() {
        analysis = nil
    }

    private func analyze(
        _ parseResult: VocabularyParseResult,
        using repository: VocabularyRepository
    ) async {
        isWorking = true
        defer { isWorking = false }

        do {
            analysis = try await repository.analyze(parseResult)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
