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


@MainActor
private func fourFixesPracticeFixture() throws -> ModelContainer {
    let container = try ModelContainer(for: AppSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let text = """
    {"schema_version":1,"batch_title":"边界验证","groups":[{"group_id":"g1","title":"加法","original":{"question_id":"o1","prompt_markdown":"1+1=?","answer_markdown":"2","explanation_markdown":"相加"},"variants":[{"question_id":"n1","variant_kind":"near","prompt_markdown":"2+2=?","answer_markdown":"4","explanation_markdown":"相加"},{"question_id":"n2","variant_kind":"near","prompt_markdown":"3+3=?","answer_markdown":"6","explanation_markdown":"相加"}]}]}
    """
    try ImportService.commit(ImportService.preview(text: text, context: container.mainContext), context: container.mainContext)
    return container
}

@MainActor
@Test(arguments: ["answering", "marking", "pendingReview", "pendingFollowup", "awaitingGrade", "summary", "targeted"])
func leavingPracticeResumesSavedCheckpoint(checkpoint: String) throws {
    let container = try fourFixesPracticeFixture()
    let context = container.mainContext
    let group = try #require(try context.fetch(FetchDescriptor<ProblemGroup>()).first)
    let session: PracticeSession
    if checkpoint == "targeted" {
        session = try PracticeService.makeCorrectionSession(for: group, context: context)
    } else {
        let second = ProblemGroup(externalID: "g2", title: "减法")
        second.reviewState = ReviewState()
        second.questions = [Question(externalID: "n3", kind: .near,
            promptMarkdown: "3-1=?", answerMarkdown: "2", explanationMarkdown: "相减")]
        group.batch?.groups.append(second)
        context.insert(second)
        session = try #require(try PracticeService.makeDailySession(context: context))
        session.currentIndex = 1
        if checkpoint != "answering" {
            session.phase = .marking
            for attempt in session.attempts { attempt.draftResult = .wrong }
        }
        if !["answering", "marking"].contains(checkpoint) {
            try PracticeService.commitMarking(session: session, context: context)
        }
    }
    if ["pendingFollowup", "awaitingGrade", "targeted"].contains(checkpoint) {
        let progress = try #require(session.groupProgress.first)
        _ = try PracticeService.makeCorrectionAttempt(for: progress, context: context)
        try PracticeService.gradeCorrection(.wrong, progress: progress, context: context)
        let followup = try #require(try PracticeService.makeCorrectionAttempt(for: progress, context: context))
        if checkpoint == "awaitingGrade" {
            PracticeService.markPresented(followup, context: context)
            progress.stage = .awaitingGrade
        }
    }
    if checkpoint == "summary" { session.phase = .summary }
    try context.save()

    // A new context must reconstruct the checkpoint without the previous view's objects.
    let reentered = ModelContext(container)
    let restored = try #require(try PracticeService.activeSession(context: reentered))
    #expect(restored.id == session.id)
    #expect(restored.phase == session.phase)
    #expect(restored.mode == session.mode)
    #expect(restored.currentIndex == session.currentIndex)
    #expect(restored.completedAt == nil)
    #expect(restored.attempts.count == session.attempts.count)
    #expect(restored.currentCorrectionProgress?.id == session.currentCorrectionProgress?.id)
    restored.groupProgress.reverse()
    #expect(restored.currentCorrectionProgress?.id == session.currentCorrectionProgress?.id)
    for saved in session.attempts {
        let loaded = try #require(restored.attempts.first { $0.id == saved.id })
        #expect(loaded.question?.id == saved.question?.id)
        #expect(loaded.draftResult == saved.draftResult)
        #expect(loaded.result == saved.result)
        #expect(loaded.presentedAt == saved.presentedAt)
    }
    for saved in session.groupProgress {
        let loaded = try #require(restored.groupProgress.first { $0.id == saved.id })
        #expect(loaded.stage == saved.stage)
        #expect(loaded.correctionFailureCount == saved.correctionFailureCount)
    }
    let resumed = try #require(try PracticeService.makeDailySession(context: reentered))
    #expect(resumed.id == restored.id)
    #expect(try reentered.fetchCount(FetchDescriptor<PracticeSession>()) == 1)
    #expect(try reentered.fetchCount(FetchDescriptor<Attempt>()) == session.attempts.count)
    #expect(restored.attempts.allSatisfy { $0.group?.reviewState?.creditedCorrectCount == 0 })
}

@MainActor @Test func resumedPracticeSchedulesFromActualMarkingDay() throws {
    let container = try fourFixesPracticeFixture()
    let context = container.mainContext
    let session = try #require(try PracticeService.makeDailySession(context: context, day: "2026-09-01"))
    let resumed = try #require(try PracticeService.makeDailySession(context: context, day: "2026-10-02"))
    #expect(resumed.id == session.id)
    let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
    for attempt in resumed.attempts { attempt.draftResult = .correct }
    try PracticeService.commitMarking(session: resumed, context: context, now: now)
    let state = try #require(resumed.attempts.first?.group?.reviewState)
    #expect(resumed.dayKey == "2026-09-01")
    #expect(state.lastCreditedDay == "2026-10-02")
    #expect(state.nextReviewDay == "2026-10-09")
    #expect(resumed.attempts.first?.committedAt == now)
    try PracticeService.commitMarking(session: resumed, context: context, now: now)
    #expect(state.creditedCorrectCount == 1)
}

@MainActor @Test func resumedCorrectionSchedulesFromActualCorrectionDay() throws {
    let container = try fourFixesPracticeFixture()
    let context = container.mainContext
    let session = try #require(try PracticeService.makeDailySession(context: context, day: "2026-09-01"))
    let october2 = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
    for attempt in session.attempts { attempt.draftResult = .wrong }
    try PracticeService.commitMarking(session: session, context: context, now: october2)
    let progress = try #require(session.groupProgress.first)
    #expect(progress.group?.reviewState?.nextReviewDay == "2026-10-02")
    let attempt = try #require(try PracticeService.makeCorrectionAttempt(for: progress, context: context))
    let october3 = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
    try PracticeService.gradeCorrection(.correct, progress: progress, context: context, now: october3)
    #expect(progress.group?.reviewState?.nextReviewDay == "2026-10-06")
    #expect(attempt.committedAt == october3)
    #expect(session.dayKey == "2026-09-01")
    _ = try BackupService.validate(BackupService.exportData(context: context))
}

@MainActor @Test func invalidBackupProgressIsRejectedBeforeReplacingData() throws {
    let container = try fourFixesPracticeFixture()
    let context = container.mainContext
    _ = try #require(try PracticeService.makeDailySession(context: context))
    let original = try BackupService.exportData(context: context)
    let valid = try BackupService.validate(original)
    for (table, field, badValue) in [
        ("sessions", "currentIndex", 999 as Any), ("sessions", "currentIndex", -1 as Any),
        ("sessions", "phaseRaw", "unknown" as Any), ("sessions", "modeRaw", "unknown" as Any),
        ("sessions", "dayKey", "2026-02-30" as Any),
        ("reviewStates", "statusRaw", "unknown" as Any), ("reviewStates", "creditedCorrectCount", 4 as Any),
        ("attempts", "contextRaw", "unknown" as Any), ("attempts", "draftResultRaw", "unknown" as Any),
        ("attempts", "orderIndex", -1 as Any)
    ] {
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try #require(object[table] as? [[String: Any]])
        records[0][field] = badValue; object[table] = records
        #expect(throws: BackupFailure.self) { try BackupService.validate(JSONSerialization.data(withJSONObject: object)) }
    }
    var invalid = valid
    let old = try #require(invalid.sessions.first)
    invalid.sessions = [SessionRecord(id: old.id, createdAt: old.createdAt, completedAt: old.completedAt,
        phaseRaw: old.phaseRaw, modeRaw: old.modeRaw, currentIndex: 999, dayKey: old.dayKey)]
    #expect(throws: BackupFailure.self) { try BackupService.restore(invalid, context: context) }
    let unchanged = try BackupService.validate(BackupService.exportData(context: context))
    #expect(unchanged.groups.map(\.id) == valid.groups.map(\.id))
    #expect(unchanged.sessions.first?.currentIndex == valid.sessions.first?.currentIndex)
}

@MainActor @Test func invalidBackupRelationshipsAndDuplicateIDsAreRejected() throws {
    let container = try fourFixesPracticeFixture()
    let context = container.mainContext
    _ = try #require(try PracticeService.makeDailySession(context: context))
    let original = try BackupService.exportData(context: context)
    for table in ["reviewStates", "attempts"] {
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try #require(object[table] as? [[String: Any]])
        records.append(records[0]); object[table] = records
        #expect(throws: BackupFailure.self) { try BackupService.validate(JSONSerialization.data(withJSONObject: object)) }
    }
    var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    var records = try #require(object["attempts"] as? [[String: Any]])
    records[0]["groupID"] = UUID().uuidString; object["attempts"] = records
    #expect(throws: BackupFailure.self) { try BackupService.validate(JSONSerialization.data(withJSONObject: object)) }
    _ = try BackupService.validate(original)
}


@MainActor @Test func correctionBackupValidatesStagesAndPreservesFollowupOnRestore() throws {
    let source = try fourFixesPracticeFixture()
    let context = source.mainContext
    let group = try #require(try context.fetch(FetchDescriptor<ProblemGroup>()).first)
    let session = try PracticeService.makeCorrectionSession(for: group, context: context)
    let original = try BackupService.exportData(context: context)
    _ = try BackupService.validate(original)
    for (field, badValue) in [("stageRaw", "unknown" as Any), ("stageRaw", "pendingFollowup" as Any),
                              ("correctionFailureCount", -1 as Any), ("correctionFailureCount", 4 as Any)] {
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try #require(object["progress"] as? [[String: Any]])
        records[0][field] = badValue; object["progress"] = records
        #expect(throws: BackupFailure.self) { try BackupService.validate(JSONSerialization.data(withJSONObject: object)) }
    }
    let progress = try #require(session.groupProgress.first)
    let attempt = try #require(try PracticeService.makeCorrectionAttempt(for: progress, context: context))
    let valid = try BackupService.validate(BackupService.exportData(context: context))
    let target = try ModelContainer(for: AppSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    try BackupService.restore(valid, context: target.mainContext)
    let restored = try #require(try PracticeService.activeSession(context: target.mainContext))
    #expect(restored.groupProgress.first?.stage == .pendingFollowup)
    #expect(restored.attempts.first?.id == attempt.id)
    #expect(restored.attempts.first?.question?.id == attempt.question?.id)
}

private func fileImportFixture(title: String = "文件导入") throws -> Data {
    let original = QuestionPayload(questionID: "G001-O", promptMarkdown: "1+1=?", answerMarkdown: "2", explanationMarkdown: "相加")
    let variant = VariantPayload(questionID: "G001-N01", variantKind: .near,
        promptMarkdown: "2+2=?", answerMarkdown: "4", explanationMarkdown: "相加")
    return try JSONEncoder().encode(SimpleLianPayload(schemaVersion: 1, batchTitle: title, groups: [
        GroupPayload(groupID: "G001", title: title, original: original, variants: [variant])
    ]))
}

@MainActor @Test func multipleFilesPreviewWithoutWritingAndCommitOnlyValidUniqueFiles() async throws {
    let container = try ModelContainer(for: AppSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("旧格式题库.txt")
    let second = directory.appendingPathComponent("新题库.json")
    let duplicate = directory.appendingPathComponent("重复副本.txt")
    let broken = directory.appendingPathComponent("内容损坏.txt")
    let invalid = directory.appendingPathComponent("缺少题型.txt")
    let missing = directory.appendingPathComponent("不存在.txt")
    try fileImportFixture(title: "第一题").write(to: first)
    try fileImportFixture(title: "第二题").write(to: second)
    try FileManager.default.copyItem(at: first, to: duplicate)
    try Data("{broken".utf8).write(to: broken)
    try Data(#"{"schema_version":1,"batch_title":"无效","groups":[]}"#.utf8).write(to: invalid)
    let urls = [first, broken, second, duplicate, invalid, missing]
    let originalData = try urls.dropLast().map { try Data(contentsOf: $0) }

    let previews = await ImportService.previewFiles(urls, context: context)
    #expect(previews.map(\.status) == [.ready, .invalid, .ready, .duplicate, .invalid, .invalid])
    #expect(previews[3].message?.contains("本次选择") == true)
    #expect(previews[4].preview?.report.canImport == false)
    #expect(try context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
    // Warnings about small legacy banks remain visible and do not prevent importing.
    #expect(previews[0].preview?.report.warnings.isEmpty == false)

    let results = ImportService.commitFiles(previews, context: context)
    #expect(results.map(\.status) == [.imported, .invalid, .imported, .duplicate, .invalid, .invalid])
    let saved = ModelContext(container)
    #expect(try saved.fetchCount(FetchDescriptor<ImportBatch>()) == 2)
    #expect(try saved.fetchCount(FetchDescriptor<ProblemGroup>()) == 2)
    #expect(try saved.fetchCount(FetchDescriptor<Question>()) == 4)
    #expect(try saved.fetch(FetchDescriptor<ReviewState>()).allSatisfy { $0.creditedCorrectCount == 0 })
    #expect(try urls.dropLast().map { try Data(contentsOf: $0) } == originalData)
    _ = ImportService.commitFiles(results, context: context)
    #expect(try context.fetchCount(FetchDescriptor<ImportBatch>()) == 2)
    let again = await ImportService.previewFiles([first, second], context: context)
    #expect(again.allSatisfy { $0.status == .duplicate && $0.message?.contains("题库中已有") == true })
}

@MainActor @Test func staleFilePreviewSkipsDuplicateAtCommitAndContinuesOtherFiles() async throws {
    let container = try ModelContainer(for: AppSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let first = try ImportService.preview(text: String(decoding: fileImportFixture(title: "第一题"), as: UTF8.self), context: context)
    let second = try ImportService.preview(text: String(decoding: fileImportFixture(title: "第二题"), as: UTF8.self), context: context)
    try ImportService.commit(first, context: context)
    let results = ImportService.commitFiles([
        FileImportPreview(fileName: "第一题.txt", preview: first, status: .ready),
        FileImportPreview(fileName: "第二题.txt", preview: second, status: .ready)
    ], context: context)
    #expect(results.map(\.status) == [.duplicate, .imported])
    #expect(try context.fetchCount(FetchDescriptor<ImportBatch>()) == 2)
    #expect(try context.fetchCount(FetchDescriptor<ProblemGroup>()) == 2)
}
