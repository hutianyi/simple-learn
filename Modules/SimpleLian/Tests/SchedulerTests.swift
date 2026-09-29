import SwiftData
import Testing
@testable import SimpleLian

@Test func masteredGroupsAreNeverDue() {
    let state = ReviewSnapshot(status: .mastered, creditedCorrectCount: 3)
    let unchanged = ReviewScheduler.apply(.formalCorrect(day: "2026-09-29"), to: state)
    #expect(unchanged == state)
}

@MainActor
@Test func importsIntoAnInMemoryStore() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: AppSchema.schema, configurations: configuration)
    let context = ModelContext(container)
    let json = """
    {"schema_version":1,"batch_title":"测试批次","groups":[{"group_id":"g1","title":"加法","original":{"question_id":"o1","prompt_markdown":"1+1=?","answer_markdown":"2","explanation_markdown":"相加"},"variants":[{"question_id":"n1","variant_kind":"near","prompt_markdown":"2+2=?","answer_markdown":"4","explanation_markdown":"相加"}]}]}
    """
    let preview = try ImportService.preview(text: json, context: context)
    #expect(preview.report.canImport)
    try ImportService.commit(preview, context: context)
    #expect(try context.fetchCount(FetchDescriptor<ImportBatch>()) == 1)
    #expect(try PracticeService.dueGroups(context: context).count == 1)
}
