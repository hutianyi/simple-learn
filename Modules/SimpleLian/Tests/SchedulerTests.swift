import Foundation
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
    #expect(try PracticeService.overviewStatus(context: context).isComplete)
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
    #expect(try !PracticeService.overviewStatus(context: context).isComplete)
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

@MainActor
@Test func twentyQuestionStockKeepsWorkingAfterRepeatedWrongAnswers() throws {
    let (container, context, batch) = try practiceFixture()
    _ = container
    let group = try #require(batch.groups.first)
    for index in 2...20 {
        group.questions.append(Question(externalID: "n\(index)", kind: .near,
            promptMarkdown: "\(index)+1=?", answerMarkdown: "\(index + 1)", explanationMarkdown: "相加"))
    }
    try context.save()
    var selectedIDs: [UUID] = []
    // 25 failed formal reviews plus successful corrections use the stock 2.5 times.
    for round in 0..<25 {
        let day = try #require(DayKey.adding(days: round * 3, to: "2026-01-01"))
        let bits = day.split(separator: "-").compactMap { Int($0) }
        let now = try #require(Calendar.current.date(from: DateComponents(year: bits[0], month: bits[1], day: bits[2], hour: 12)))
        let session = try #require(try PracticeService.makeDailySession(context: context, day: day))
        let initial = try #require(session.attempts.first)
        initial.presentedAt = now
        selectedIDs.append(try #require(initial.question?.id))
        initial.draftResult = .wrong
        try PracticeService.commitMarking(session: session, context: context, now: now)
        let progress = try #require(session.groupProgress.first)
        let correction = try #require(try PracticeService.makeCorrectionAttempt(for: progress, context: context))
        correction.presentedAt = now.addingTimeInterval(1)
        selectedIDs.append(try #require(correction.question?.id))
        #expect(correction.question?.id != initial.question?.id)
        try PracticeService.gradeCorrection(.correct, progress: progress, context: context, now: now.addingTimeInterval(2))
        #expect(group.reviewState?.creditedCorrectCount == 0)
        #expect(group.reviewState?.nextReviewDay == DayKey.adding(days: 3, to: day))
        try PracticeService.complete(session, context: context)
    }
    #expect(Set(selectedIDs.prefix(20)).count == 20)
    #expect(Array(selectedIDs.prefix(20)) == Array(selectedIDs[20..<40]))
    #expect(Array(selectedIDs.prefix(10)) == Array(selectedIDs[40..<50]))
    #expect(try context.fetchCount(FetchDescriptor<Attempt>()) == 50)
    _ = try BackupService.validate(BackupService.exportData(context: context))
}

@MainActor
@Test func correctionReusesSingleQuestionButStillStopsAfterThreeFailures() throws {
    let (container, context, _) = try practiceFixture()
    _ = container
    let session = try #require(try PracticeService.makeDailySession(context: context))
    let initial = try #require(session.attempts.first)
    initial.draftResult = .wrong
    try PracticeService.commitMarking(session: session, context: context)
    let progress = try #require(session.groupProgress.first)
    for failure in 1...3 {
        let correction = try #require(try PracticeService.makeCorrectionAttempt(for: progress, context: context))
        #expect(correction.question?.id == initial.question?.id)
        #expect(correction.id != initial.id)
        #expect(!correction.eligibleForCredit)
        PracticeService.markPresented(correction, context: context)
        try PracticeService.gradeCorrection(.wrong, progress: progress, context: context)
        #expect(progress.correctionFailureCount == failure)
        #expect(progress.stage == (failure == 3 ? .needsExplanation : .pendingReview))
    }
    #expect(session.phase == .summary)
    #expect(progress.group?.reviewState?.status == .needsExplanation)
    #expect(session.attempts.count == 4)
    _ = try BackupService.validate(BackupService.exportData(context: context))
}

@MainActor
@Test func correctionUsesRemainingQuestionBeforeRecyclingAndRestoresItsRotation() throws {
    let (container, context, batch) = try practiceFixture()
    _ = container
    let group = try #require(batch.groups.first)
    let second = Question(externalID: "n2", kind: .near, promptMarkdown: "3+3=?", answerMarkdown: "6", explanationMarkdown: "相加")
    group.questions.append(second)
    try context.save()
    let session = try #require(try PracticeService.makeDailySession(context: context))
    let initial = try #require(session.attempts.first)
    initial.presentedAt = Date(timeIntervalSince1970: 100)
    initial.draftResult = .wrong
    try PracticeService.commitMarking(session: session, context: context)
    let progress = try #require(session.groupProgress.first)
    let firstCorrection = try #require(try PracticeService.makeCorrectionAttempt(for: progress, context: context))
    #expect(firstCorrection.question?.id != initial.question?.id)
    firstCorrection.presentedAt = Date(timeIntervalSince1970: 200)
    try PracticeService.gradeCorrection(.wrong, progress: progress, context: context)
    let recycled = try #require(try PracticeService.makeCorrectionAttempt(for: progress, context: context))
    #expect(recycled.question?.id == initial.question?.id)
    recycled.presentedAt = Date(timeIntervalSince1970: 300)
    try context.save()

    let backup = try BackupService.validate(BackupService.exportData(context: context))
    let target = try ModelContainer(for: AppSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let restoredContext = target.mainContext
    try BackupService.restore(backup, context: restoredContext)
    let restored = try #require(try PracticeService.activeSession(context: restoredContext))
    let restoredProgress = try #require(restored.groupProgress.first)
    #expect(restoredProgress.stage == .pendingFollowup)
    #expect(restored.attempts.contains { $0.id == recycled.id && $0.result == nil })
    try PracticeService.gradeCorrection(.wrong, progress: restoredProgress, context: restoredContext)
    let next = try #require(try PracticeService.makeCorrectionAttempt(for: restoredProgress, context: restoredContext))
    #expect(next.question?.id == firstCorrection.question?.id)
    try PracticeService.gradeCorrection(.correct, progress: restoredProgress, context: restoredContext)
    #expect(restoredProgress.stage == .passed)
    #expect(restoredProgress.group?.reviewState?.creditedCorrectCount == 0)
    #expect(restored.attempts.count == 4)
    _ = try BackupService.validate(BackupService.exportData(context: restoredContext))
}

@MainActor
@Test func correctionReportsShortageOnlyWhenNoUsableNearQuestionRemains() throws {
    let (container, context, batch) = try practiceFixture()
    _ = container
    let group = try #require(batch.groups.first)
    let near = try #require(group.questions.first { $0.kind == .near })
    near.disabledAt = .now
    group.questions.append(Question(externalID: "t1", kind: .transfer,
        promptMarkdown: "1+2+3=?", answerMarkdown: "6", explanationMarkdown: "相加"))
    let session = try PracticeService.makeCorrectionSession(for: group, context: context)
    let progress = try #require(session.groupProgress.first)
    #expect(try PracticeService.makeCorrectionAttempt(for: progress, context: context) == nil)
    #expect(progress.stage == .materialShortage)
    #expect(session.attempts.isEmpty)
    near.disabledAt = nil
    let attempt = try #require(try PracticeService.makeCorrectionAttempt(for: progress, context: context))
    #expect(attempt.question?.id == near.id)
    #expect(progress.stage == .pendingFollowup)
}
