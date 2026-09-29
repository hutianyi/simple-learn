import Foundation
import SwiftData
import Testing
@testable import SimpleLian

@MainActor
@Test func completeBackupPreservesUnfinishedSessionAndReviewProgress() throws {
    let source = try ModelContainer(for: AppSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(source)
    let json = """
    {"schema_version":1,"batch_title":"迁移测试","groups":[{"group_id":"g1","title":"加法","original":{"question_id":"o1","prompt_markdown":"1+1=?","answer_markdown":"2","explanation_markdown":"相加"},"variants":[{"question_id":"n1","variant_kind":"near","prompt_markdown":"2+2=?","answer_markdown":"4","explanation_markdown":"相加"}]}]}
    """
    try ImportService.commit(ImportService.preview(text: json, context: context), context: context)
    let session = try #require(try PracticeService.makeDailySession(context: context))
    session.currentIndex = 0
    let group = try #require(try context.fetch(FetchDescriptor<ProblemGroup>()).first)
    group.reviewState?.creditedCorrectCount = 2
    try context.save()
    let backup = try BackupService.validate(BackupService.exportData(context: context))
    let destination = try ModelContainer(for: AppSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let target = ModelContext(destination)
    try BackupService.restore(backup, context: target)
    let restored = try #require(try target.fetch(FetchDescriptor<PracticeSession>()).first)
    #expect(restored.id == session.id)
    #expect(restored.completedAt == nil)
    #expect(restored.attempts.count == session.attempts.count)
    #expect(try target.fetch(FetchDescriptor<ProblemGroup>()).first?.reviewState?.creditedCorrectCount == 2)
    try BackupService.restore(backup, context: target)
    #expect(try target.fetchCount(FetchDescriptor<ImportBatch>()) == 1)
}
