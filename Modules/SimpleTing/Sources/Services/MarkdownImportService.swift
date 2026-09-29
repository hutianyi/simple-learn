import Foundation

enum MarkdownImportService {
    static func parsePastedText(_ text: String) async throws -> ImportDraft {
        try await Task.detached(priority: .userInitiated) {
            try MarkdownArticleParser.parsePastedText(text)
        }.value
    }
}
