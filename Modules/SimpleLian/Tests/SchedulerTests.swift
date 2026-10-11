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

@MainActor
private func practiceFixture() throws -> (ModelContainer, ModelContext, ImportBatch) {
    let container = try ModelContainer(for: AppSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let json = """
    {"schema_version":1,"batch_title":"回归题库","groups":[{"group_id":"g1","title":"加法","original":{"question_id":"o1","prompt_markdown":"1+1=?","answer_markdown":"2","explanation_markdown":"相加"},"variants":[{"question_id":"n1","variant_kind":"near","prompt_markdown":"2+2=?","answer_markdown":"4","explanation_markdown":"相加"}]}]}
    """
    try ImportService.commit(ImportService.preview(text: json, context: context), context: context)
    return (container, context, try #require(context.fetch(FetchDescriptor<ImportBatch>()).first))
}

@MainActor
@Test func deletingBatchUsedByUnfinishedSessionKeepsPracticeResumable() throws {
    let (container, context, batch) = try practiceFixture()
    _ = container
    let made = try PracticeService.makeDailySession(context: context)
    let session = try #require(made)
    do { try PracticeService.deleteBatch(batch, context: context); Issue.record("Must reject deletion") }
    catch PracticeFailure.batchInUse {}
    #expect(try context.fetchCount(FetchDescriptor<ImportBatch>()) == 1)
    #expect(try PracticeService.activeSession(context: context)?.id == session.id)
    session.attempts.first?.draftResult = .correct
    try PracticeService.commitMarking(session: session, context: context)
    try PracticeService.complete(session, context: context)
    try PracticeService.deleteBatch(batch, context: context)
    #expect(try context.fetchCount(FetchDescriptor<PracticeSession>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Attempt>()) == 0)
    _ = try BackupService.validate(BackupService.exportData(context: context))
}

@MainActor
@Test func emptyLegacySessionIsRemovedButTargetedCorrectionIsPreserved() throws {
    let (container, context, batch) = try practiceFixture()
    _ = container
    context.insert(PracticeSession(dayKey: DayKey.make(from: .now)))
    try context.save()
    let created = try PracticeService.makeDailySession(context: context)
    let daily = try #require(created)
    #expect(daily.attempts.count == 1)
    #expect(try context.fetchCount(FetchDescriptor<PracticeSession>()) == 1)
    try PracticeService.complete(daily, context: context)
    let correction = try PracticeService.makeCorrectionSession(for: try #require(batch.groups.first), context: context)
    #expect(correction.attempts.isEmpty)
    try PracticeService.discardEmptySessions(context: context)
    #expect(try PracticeService.activeSession(context: context)?.id == correction.id)
    do { try PracticeService.deleteBatch(batch, context: context); Issue.record("Correction must protect its batch") }
    catch PracticeFailure.batchInUse {}
}

@MainActor
@Test func disabledVariantsAreMissingMaterialsRatherThanRunnableTasks() throws {
    let (container, context, batch) = try practiceFixture()
    _ = container
    let group = try #require(batch.groups.first)
    let variant = try #require(group.questions.first { $0.kind != .original })
    variant.disabledAt = .now
    try context.save()
    #expect(try PracticeService.dueGroups(context: context).isEmpty)
    #expect(try PracticeService.makeDailySession(context: context) == nil)
    #expect(try PracticeService.overview(context: context) == "缺题 1 类")
    #expect(try context.fetchCount(FetchDescriptor<PracticeSession>()) == 0)
    variant.disabledAt = nil
    try context.save()
    #expect(try PracticeService.dueGroups(context: context).count == 1)
    #expect(try PracticeService.makeDailySession(context: context)?.attempts.count == 1)
}

@MainActor
@Test func deletingPartOfCompletedSessionKeepsRemainingBackupValid() throws {
    let (container, context, first) = try practiceFixture()
    _ = container
    let second = ImportBatch(title: "第二题库", sourceNote: nil, schemaVersion: 1, payloadHash: "second")
    let group = ProblemGroup(externalID: "g2", title: "减法")
    group.reviewState = ReviewState()
    group.questions = [Question(externalID: "n2", kind: .near, promptMarkdown: "2-1=?", answerMarkdown: "1", explanationMarkdown: "相减")]
    second.groups.append(group)
    context.insert(second)
    try context.save()
    let made = try PracticeService.makeDailySession(context: context)
    let session = try #require(made)
    #expect(session.attempts.count == 2)
    session.currentIndex = 1
    for attempt in session.attempts { attempt.draftResult = .correct }
    try PracticeService.commitMarking(session: session, context: context)
    try PracticeService.complete(session, context: context)
    try PracticeService.deleteBatch(first, context: context)
    #expect(session.attempts.count == 1)
    #expect(session.currentIndex == 0)
    _ = try BackupService.validate(BackupService.exportData(context: context))
}
