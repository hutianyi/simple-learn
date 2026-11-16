import XCTest
import zlib
@testable import SimpleDu

final class DuCoreTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1sAAAAASUVORK5CYII=")!
    @MainActor
    func testPaginationPreservesEveryCharacterAcrossFontsAndUnicode() throws {
        var article = try package().content.articles[0]
        let plain = String(repeating: "A farm has wheat. 🌾 Families enjoy food, café and 苹果. ", count: 30)
        article.units[0].paragraphs = [DuParagraph(id: "p1", runs: [DuRun(text: plain, target: false)])]
        for size in [24.0, 28.0, 36.0] {
            let pages = DuPagination.pages(article, width: 260, height: 300, fontSize: size)
            XCTAssertGreaterThan(pages.count, 1)
            XCTAssertEqual(pages.flatMap(\.blocks).map { String($0.text.characters) }.joined(), plain)
            for page in pages { XCTAssertTrue(page.contains(page.anchor)) }
        }
    }
    @MainActor
    func testLargerFontAddsPagesAndStableAnchorCanBeRestored() throws {
        var article = try package().content.articles[0]
        article.units[0].paragraphs[0].runs[0].text = String(repeating: "A farm grows food. ", count: 60)
        let small = DuPagination.pages(article, width: 400, height: 450, fontSize: 24)
        let large = DuPagination.pages(article, width: 400, height: 450, fontSize: 36)
        XCTAssertGreaterThan(large.count, small.count)
        XCTAssertNotNil(large.firstIndex { $0.contains(small[small.count / 2].anchor) })
    }
    func testActualReviewedDeflatedPackageIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SIMPLEDU_SAMPLE"] else {
            throw XCTSkip("A local reading sample was not provided.")
        }
        let package = try DuPackage.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(package.content.articles.count, 1)
        XCTAssertEqual(package.content.articles[0].title, "From the Farm to Your Plate")
        XCTAssertEqual(package.content.articles[0].questions.count, 5)
        XCTAssertEqual(package.content.images.count, 5)
        XCTAssertEqual(package.content.articles[0].units.flatMap(\.paragraphs).count, 7)
    }
    private func content(count: Int = 1) -> DuContent {
        DuContent(articles: (1...count).map { number in
            DuArticle(id: "a\(number)", title: "A book \(number)", cover: "images/photo.png",
                units: [DuUnit(id: "u1", heading: "A heading", image: "images/photo.png",
                    paragraphs: [DuParagraph(id: "p1", runs: [DuRun(text: "A farm grows food.", target: false)])])],
                questions: (1...5).map { DuQuestion(id: "q\($0)", prompt: "What grows food?", options: ["A farm", "A lamp", "A phone", "A book"], answer: 0,
                    explanation: "The article says a farm grows food.", evidence: ["p1"]) }, sources: [])
        }, images: [DuImageAsset(path: "images/photo.png", alt: "A test photo", credit: "Test fixture")])
    }
    private func package(batch: String = "test", revision: Int = 1, count: Int = 1, transform: (inout DuContent) -> Void = { _ in }) throws -> DuPackage {
        try DuPackage.decode(archive(batch: batch, revision: revision, count: count, transform: transform))
    }
    private func archive(batch: String = "test", revision: Int = 1, count: Int = 1, transform: (inout DuContent) -> Void = { _ in }) throws -> Data {
        var value = content(count: count); transform(&value)
        let files = ["content.json": try JSONEncoder().encode(value), "images/photo.png": png]
        let manifest = DuManifest(format: "SimpleDu", schemaVersion: 1, batchID: batch, revision: revision, title: "Test batch", files: files.mapValues(duHash))
        return zip(files.merging(["manifest.json": try JSONEncoder().encode(manifest)]) { $1 })
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DuTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testMultiArticlePackageAndRealImageValidation() throws {
        let pack = try package(count: 2)
        XCTAssertEqual(pack.content.articles.count, 2)
        XCTAssertEqual(pack.content.articles[0].questions.count, 5)
        XCTAssertEqual(pack.files["images/photo.png"], png)
    }
    func testPathTraversalAbsoluteBackslashAndSymlinkRejected() {
        for name in ["../x", "/x", "images/../x", "a\\b", "a//b", "a/./b"] {
            XCTAssertThrowsError(try DuArchive.read(zip([name: Data("bad".utf8)])))
        }
        XCTAssertThrowsError(try DuArchive.read(zip(["link": Data()], attributes: 0xa000 << 16)))
    }
    func testTruncatedAndCorruptArchiveRejected() throws {
        let data = try archive()
        for size in [0, 20, data.count - 1] { XCTAssertThrowsError(try DuPackage.decode(data.prefix(size))) }
        var corrupt = data
        corrupt[50] ^= 1
        XCTAssertThrowsError(try DuPackage.decode(corrupt))
    }
    func testDuplicateNamesAndExpansionLimitRejected() {
        XCTAssertThrowsError(try DuArchive.read(zip(["A": Data(), "a": Data()])))
        var data = zip(["x": Data()])
        // Local header uncompressed length claims 16 MiB + 1 without allocating it.
        let central = 31
        data.replaceSubrange((central + 24)..<(central + 28), with: le(UInt32(DuArchive.maxEntryBytes + 1)))
        XCTAssertThrowsError(try DuArchive.read(data))
    }
    func testSemanticValidationRejectsBadAnswerMissingImageAndEvidence() {
        XCTAssertThrowsError(try package { $0.articles[0].questions[0].answer = 4 })
        XCTAssertThrowsError(try package { $0.articles[0].questions[0].evidence = ["missing"] })
        XCTAssertThrowsError(try package { $0.articles[0].units[0].image = "images/missing.jpg" })
        XCTAssertThrowsError(try package { $0.articles[0].units[0].paragraphs[0].runs = [] })
        XCTAssertThrowsError(try package { $0.articles.append($0.articles[0]) })
    }
    func testRequiresValidHashesAndSupportedVersion() throws {
        let original = try DuArchive.read(archive())
        var files = original
        files["content.json"] = Data("{}".utf8)
        XCTAssertThrowsError(try DuPackage.decode(zip(files)))
        var manifest = try JSONDecoder().decode(DuManifest.self, from: original["manifest.json"]!)
        manifest.schemaVersion = 99; files = original
        files["manifest.json"] = try JSONEncoder().encode(manifest)
        XCTAssertThrowsError(try DuPackage.decode(zip(files)))
    }
    func testSelectionIsNotSubmissionAndFirstAnswersSurviveRetake() throws {
        let article = try package().content.articles[0]
        var progress = DuProgress(); progress.stage = .quiz
        progress.selections["q1"] = 1
        XCTAssertTrue(progress.answers.isEmpty)
        try progress.submit(article.questions[0], article: article)
        XCTAssertEqual(progress.firstAnswers["q1"], 1)
        XCTAssertThrowsError(try progress.submit(article.questions[0], article: article))
        progress.restart(article: article)
        XCTAssertTrue(progress.answers.isEmpty)
        progress.selections["q1"] = 0
        try progress.submit(article.questions[0], article: article)
        XCTAssertEqual(progress.answers["q1"], 0)
        XCTAssertEqual(progress.firstAnswers["q1"], 1)
        try progress.validated(article: article)
    }
    func testResultsRequireAllQuestionsAndHistoryOnlyAppendsOnce() throws {
        let article = try package().content.articles[0]; var progress = DuProgress()
        progress.stage = .result
        XCTAssertThrowsError(try progress.validated(article: article))
        progress.stage = .quiz
        for question in article.questions {
            progress.selections[question.id] = 0
            try progress.submit(question, article: article)
        }
        XCTAssertEqual(progress.attempts.count, 1)
        XCTAssertEqual(progress.score(progress.answers, article: article), 5)
        progress.stage = .result
        try progress.validated(article: article)
    }
    func testInstallDuplicateUpdateConflictAndPersistentDraft() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let first = try package(count: 2)
        let initial = try await repo.install(first)
        XCTAssertEqual(initial.0.books.count, 2)
        XCTAssertEqual(initial.1, .new)
        let duplicate = try await repo.install(first)
        XCTAssertEqual(duplicate.1, .duplicate)
        let key = initial.0.books[0].id
        var progress = DuProgress(); progress.selections["q1"] = 2
        progress.currentQuestionID = "q1"; progress.stage = .quiz
        _ = try await repo.saveProgress(progress, bookID: key, fontSize: 32)
        let reloaded = try DuDisk(directory: directory).load()
        XCTAssertEqual(reloaded.index.progress[key]?.selections["q1"], 2)
        XCTAssertEqual(reloaded.index.fontSize, 32)
        let conflicting = try package(count: 2) { $0.articles[0].title = "Changed" }
        let conflict = try await repo.install(conflicting)
        XCTAssertEqual(conflict.1, .conflict)
        let updated = try await repo.install(package(revision: 2, count: 2))
        XCTAssertEqual(updated.1, .update)
        XCTAssertEqual(updated.0.books.count, 2)
        XCTAssertEqual(updated.0.index.progress[key], progress)
        XCTAssertTrue(updated.0.books[0].progress.answers.isEmpty)
        let older = try await repo.install(package(revision: 1, count: 1))
        XCTAssertEqual(older.1, .conflict)
    }
    func testPortableBackupContainsPicturesVersionsAndProgress() async throws {
        let original = try folder(), restored = try folder()
        defer { try? FileManager.default.removeItem(at: original); try? FileManager.default.removeItem(at: restored) }
        let repo = DuRepository(directory: original)
        let state = try await repo.install(package()).0
        var progress = DuProgress(); progress.selections["q1"] = 3
        _ = try await repo.saveProgress(progress, bookID: state.books[0].id)
        _ = try await repo.install(package(revision: 2))
        let data = try SimpleDuBackupTransfer.exportData(directory: original)
        try SimpleDuBackupTransfer.restore(data, directory: restored)
        let loaded = try DuDisk(directory: restored).load()
        XCTAssertEqual(loaded.index.installations.count, 2)
        XCTAssertEqual(loaded.index.progress[state.books[0].id]?.selections["q1"], 3)
        XCTAssertEqual(loaded.books[0].package.files["images/photo.png"], png)
    }
    func testInvalidBackupAndCorruptLibraryDoNotReplaceData() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        _ = try await repo.install(package())
        let disk = DuDisk(directory: directory), before = try Data(contentsOf: disk.indexURL)
        XCTAssertThrowsError(try SimpleDuBackupTransfer.restore(Data("{}".utf8), directory: directory))
        XCTAssertEqual(try Data(contentsOf: disk.indexURL), before)
        try Data("broken".utf8).write(to: disk.indexURL)
        XCTAssertThrowsError(try disk.load())
        XCTAssertEqual(try Data(contentsOf: disk.indexURL), Data("broken".utf8))
    }

    func testRestoreRepairsDamagedPackageAndKeepsOriginalBytes() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package()).0
        let backup = try SimpleDuBackupTransfer.exportData(directory: directory)
        let disk = DuDisk(directory: directory)
        let url = try disk.archiveURL(installed.books[0].package.key)
        let damaged = Data("damaged local package".utf8)
        try damaged.write(to: url)
        XCTAssertThrowsError(try disk.load())
        try SimpleDuBackupTransfer.restore(backup, directory: directory)
        XCTAssertEqual(try disk.load().books.count, 1)
        let originals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("PreservedFiles"), includingPropertiesForKeys: nil)
        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(try Data(contentsOf: originals[0]), damaged)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("SafetyBackups"), includingPropertiesForKeys: nil).isEmpty)
    }
    func testDeleteClearsEveryEditionButKeepsSiblingAndBackupState() async throws {
        let directory = try folder(), restored = try folder()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: restored) }
        let repo = DuRepository(directory: directory)
        let old = try await repo.install(package(count: 2)).0
        let oldFirst = old.books.first { $0.article.id == "a1" }!.id
        let oldSecond = old.books.first { $0.article.id == "a2" }!.id
        var progress = DuProgress(); progress.selections["q1"] = 1
        progress.stage = .quiz; progress.currentQuestionID = "q1"
        try progress.submit(old.books.first { $0.article.id == "a1" }!.article.questions[0], article: old.books.first { $0.article.id == "a1" }!.article)
        _ = try await repo.saveProgress(progress, bookID: oldFirst)
        _ = try await repo.saveProgress(progress, bookID: oldSecond)
        let newer = try await repo.install(package(revision: 2, count: 2)).0
        let newFirst = newer.books.first { $0.article.id == "a1" }!.id
        _ = try await repo.saveProgress(progress, bookID: newFirst)
        let deleted = try await repo.deleteArticle(newFirst)
        XCTAssertEqual(deleted.books.map { $0.article.id }, ["a2"])
        XCTAssertNil(deleted.index.progress[oldFirst])
        XCTAssertNil(deleted.index.progress[newFirst])
        XCTAssertNil(deleted.index.lastArticle)
        XCTAssertEqual(deleted.index.progress[oldSecond]?.firstAnswers["q1"], 1)
        XCTAssertEqual(try DuDisk(directory: directory).load().books.count, 1)
        let backup = try SimpleDuBackupTransfer.exportData(directory: directory)
        try SimpleDuBackupTransfer.restore(backup, directory: restored)
        let recovered = try DuDisk(directory: restored).load()
        XCTAssertEqual(recovered.books.map { $0.article.id }, ["a2"])
        XCTAssertNil(recovered.index.progress[oldFirst])
        XCTAssertNil(recovered.index.progress[newFirst])
    }
    func testDeleteLastBookAndExplicitReimportStartsFresh() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory), pack = try package()
        let initial = try await repo.install(pack).0
        let id = initial.books[0].id
        var progress = DuProgress(); progress.selections["q1"] = 2
        _ = try await repo.saveProgress(progress, bookID: id)
        let deleted = try await repo.deleteArticle(id)
        XCTAssertTrue(deleted.books.isEmpty)
        XCTAssertTrue(deleted.index.progress.isEmpty)
        XCTAssertEqual(DuRepository.kind(pack, in: deleted), .restore)
        let reimported = try await repo.install(pack)
        XCTAssertEqual(reimported.1, .restore)
        XCTAssertEqual(reimported.0.books.count, 1)
        XCTAssertTrue(reimported.0.books[0].progress.selections.isEmpty)
        XCTAssertTrue(reimported.0.books[0].progress.firstAnswers.isEmpty)
        XCTAssertTrue(reimported.0.books[0].progress.attempts.isEmpty)
        XCTAssertEqual(reimported.0.index.installations.count, 1)
    }
    func testOldIndexWithoutDeletionFieldStillLoadsAndInvalidDeletionDoesNotWrite() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        _ = try await repo.install(package(count: 2))
        let disk = DuDisk(directory: directory)
        let data = try Data(contentsOf: disk.indexURL)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "deletedArticles")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        try legacy.write(to: disk.indexURL)
        XCTAssertEqual(try disk.load().books.count, 2)
        do { _ = try await repo.deleteArticle("missing"); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(try Data(contentsOf: disk.indexURL), legacy)
    }
    func testBookCoverLabelsForExistingSingleAndMultipleArticlePackages() throws {
        let single = try package(batch: "ket-day14")
        let book = DuBook(package: single, article: single.content.articles[0], progress: DuProgress())
        XCTAssertEqual(book.dayLabel, "Day 14")
        XCTAssertEqual(book.articleLabel, "Article")
        let multiple = try package(count: 3) { content in
            for i in content.articles.indices { content.articles[i].id = "day05-article\(i + 1)" }
        }
        for i in multiple.content.articles.indices {
            let book = DuBook(package: multiple, article: multiple.content.articles[i], progress: DuProgress())
            XCTAssertEqual(book.dayLabel, "Day 5")
            XCTAssertEqual(book.articleLabel, "Article \(i + 1)")
        }
    }
    func testExplicitBookCoverMetadataAndInvalidNumberValidation() throws {
        let explicit = try package(count: 2) { content in
            for i in content.articles.indices {
                content.articles[i].dayNumber = 8
                content.articles[i].articleNumber = i + 1
            }
        }
        XCTAssertEqual(DuBook(package: explicit, article: explicit.content.articles[1], progress: DuProgress()).shelfLabel, "Day 8, Article 2")
        XCTAssertThrowsError(try package { $0.articles[0].dayNumber = 0 })
        XCTAssertThrowsError(try package { $0.articles[0].articleNumber = -1 })
    }
    func testMarkUnreadClearsResumeAndCurrentWorkThenResumesNewReadingAndQuiz() async throws {
        let directory = try folder(), restored = try folder()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: restored) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package(count: 2)).0
        let book = installed.books[0], other = installed.books[1]
        var progress = DuProgress()
        progress.anchor = DuAnchor(unitID: "u1", paragraphID: "p1", offset: 8)
        progress.readingCompleted = true
        try progress.select(2, question: book.article.questions[0])
        try progress.submit(book.article.questions[0], article: book.article)
        try progress.select(1, question: book.article.questions[1])
        _ = try await repo.saveProgress(progress, bookID: other.id)
        let started = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertEqual(started.continuingBook?.id, book.id)
        let unread = try await repo.arrangeArticles([book.id], action: .markUnread)
        let fresh = unread.books[0]
        XCTAssertNil(unread.index.lastArticle)
        XCTAssertNil(unread.continuingBook)
        XCTAssertNil(fresh.progress.anchor)
        XCTAssertNil(fresh.progress.currentQuestionID)
        XCTAssertEqual(fresh.progress.stage, .reading)
        XCTAssertEqual(fresh.readingStatus, "未读")
        XCTAssertEqual(fresh.progress.readingCompleted, false)
        XCTAssertTrue(fresh.progress.answers.isEmpty)
        XCTAssertTrue(fresh.progress.selections.isEmpty)
        XCTAssertEqual(fresh.progress.firstAnswers, progress.firstAnswers)
        XCTAssertEqual(fresh.progress.run, progress.run + 1)
        XCTAssertEqual(unread.index.progress[other.id], progress)
        XCTAssertEqual(try DuDisk(directory: directory).load().index, unread.index)
        let backup = try SimpleDuBackupTransfer.exportData(directory: directory)
        try SimpleDuBackupTransfer.restore(backup, directory: restored)
        let recovered = try DuDisk(directory: restored).load()
        XCTAssertEqual(recovered.index, unread.index)
        XCTAssertNil(recovered.continuingBook)
        let repeated = try await repo.arrangeArticles([book.id], action: .markUnread)
        XCTAssertEqual(repeated.books[0].progress.run, fresh.progress.run)
        var rereading = fresh.progress
        rereading.anchor = DuAnchor(unitID: "u1", paragraphID: "p1", offset: 0)
        let reading = try await repo.saveProgress(rereading, bookID: book.id)
        XCTAssertEqual(reading.continuingBook?.id, book.id)
        XCTAssertEqual(reading.books[0].readingStatus, "阅读中")
        try rereading.select(0, question: book.article.questions[0])
        let quiz = try await repo.saveProgress(rereading, bookID: book.id)
        XCTAssertEqual(quiz.continuingBook?.progress.stage, .quiz)
        XCTAssertEqual(quiz.books[0].readingStatus, "答题中")
        XCTAssertEqual(try DuDisk(directory: directory).load().continuingBook?.progress, rereading)
    }
    func testReturningArchivedUnreadArticleAlsoStartsFresh() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let book = try await repo.install(package()).0.books[0]
        XCTAssertFalse(book.canContinue)
        let settingsOnly = try await repo.saveProgress(book.progress, bookID: book.id, fontSize: 32)
        XCTAssertNil(settingsOnly.continuingBook)
        var progress = book.progress
        progress.anchor = DuAnchor(unitID: "u1", paragraphID: "p1", offset: 8)
        _ = try await repo.saveProgress(progress, bookID: book.id)
        let archived = try await repo.arrangeArticles([book.id], action: .archive)
        XCTAssertTrue(archived.books[0].isArchived)
        XCTAssertNil(archived.continuingBook)
        let returned = try await repo.arrangeArticles([book.id], action: .unarchive)
        XCTAssertFalse(returned.books[0].isArchived)
        XCTAssertNil(returned.books[0].progress.anchor)
        XCTAssertNil(returned.continuingBook)
        XCTAssertNil(returned.index.lastArticle)
    }
    func testRereadingDoesNotUseHistoricalAttemptsToOfferListeningPrematurely() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let book = try await repo.install(package()).0.books[0]
        var progress = DuProgress()
        progress.readingCompleted = true
        for question in book.article.questions {
            try progress.select(question.answer, question: question)
            try progress.submit(question, article: book.article)
        }
        let completed = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertTrue(completed.books[0].shouldOfferListening)
        let unread = try await repo.arrangeArticles([book.id], action: .unarchive)
        XCTAssertEqual(unread.books[0].progress.attempts, progress.attempts)
        XCTAssertEqual(unread.books[0].progress.firstAnswers, progress.firstAnswers)
        XCTAssertFalse(unread.books[0].shouldOfferListening)
        progress = unread.books[0].progress
        progress.readingCompleted = true
        let reread = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertFalse(reread.books[0].shouldOfferListening)
        let manuallyRead = try await repo.arrangeArticles([book.id], action: .markRead)
        XCTAssertFalse(manuallyRead.books[0].shouldOfferListening)
        for question in book.article.questions {
            try progress.select(question.answer, question: question)
            try progress.submit(question, article: book.article)
        }
        let recompleted = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertTrue(recompleted.books[0].shouldOfferListening)
        XCTAssertTrue(recompleted.books[0].isRead)
        XCTAssertEqual(recompleted.books[0].progress.attempts.map(\.run), [1, 2])
        XCTAssertEqual(recompleted.books[0].progress.firstAnswers, completed.books[0].progress.firstAnswers)
        progress.restart(article: book.article)
        let retry = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertTrue(retry.books[0].shouldOfferListening)
    }
    func testBatchMarkingAndArchivingPreservesAnswersAndSurvivesBackup() async throws {
        let directory = try folder(), restored = try folder()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: restored) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package(count: 3)).0
        let first = installed.books[0], second = installed.books[1], third = installed.books[2]
        var progress = DuProgress(); progress.stage = .quiz
        try progress.select(2, question: first.article.questions[0])
        try progress.submit(first.article.questions[0], article: first.article)
        _ = try await repo.saveProgress(progress, bookID: first.id)
        let ids: Set<String> = [first.id, second.id]
        let arranged = try await repo.arrangeArticles(ids, action: .markReadAndArchive)
        XCTAssertEqual(arranged.books.filter(\.isArchived).count, 2)
        XCTAssertEqual(arranged.books.filter(\.isRead).count, 2)
        XCTAssertFalse(arranged.books.first { $0.id == third.id }!.isArchived)
        XCTAssertEqual(arranged.index.progress[first.id], progress)
        XCTAssertNil(arranged.index.progress[second.id])
        let backup = try SimpleDuBackupTransfer.exportData(directory: directory)
        try SimpleDuBackupTransfer.restore(backup, directory: restored)
        let recovered = try DuDisk(directory: restored).load()
        XCTAssertEqual(recovered.books.filter(\.isArchived).count, 2)
        XCTAssertEqual(recovered.index.progress[first.id], progress)
        let unread = try await repo.arrangeArticles(ids, action: .markUnread)
        XCTAssertTrue(unread.books.allSatisfy { !$0.isArchived && !$0.isRead })
        XCTAssertEqual(unread.index.progress[first.id]?.firstAnswers, progress.firstAnswers)
        XCTAssertTrue(unread.index.progress[first.id]!.answers.isEmpty)
        XCTAssertNil(unread.index.lastArticle)
    }
    func testReadAutomaticallyArchivesAndReturningToShelfMarksUnread() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package(count: 2)).0
        let id = installed.books[0].id
        let archived = try await repo.arrangeArticles([id], action: .archive)
        XCTAssertTrue(archived.books[0].isArchived)
        XCTAssertTrue(archived.books[0].isRead)
        XCTAssertTrue(archived.index.progress.isEmpty)
        let unarchived = try await repo.arrangeArticles([id], action: .unarchive)
        XCTAssertFalse(unarchived.books[0].isArchived)
        XCTAssertFalse(unarchived.books[0].isRead)
        let read = try await repo.arrangeArticles([id], action: .markRead)
        XCTAssertTrue(read.books[0].isRead)
        XCTAssertTrue(read.books[0].isArchived)
        XCTAssertEqual(read.books[0].progress.stage, .reading)
        let returned = try await repo.arrangeArticles([id], action: .unarchive)
        XCTAssertFalse(returned.books[0].isRead)
        XCTAssertFalse(returned.books[0].isArchived)
        XCTAssertNil(returned.books[0].progress.anchor)
        XCTAssertEqual(returned.books[0].progress.readingStartRun, 1)
        XCTAssertEqual(try DuDisk(directory: directory).load().index, returned.index)
    }
    func testLegacyUnreadResetsOnceWhileModernRereadingAndHistoryArePreserved() async throws {
        let directory = try folder(), restored = try folder()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: restored) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package(count: 3)).0
        let first = installed.books[0], second = installed.books[1], third = installed.books[2]
        var completed = DuProgress()
        completed.anchor = DuAnchor(unitID: "u1", paragraphID: "p1", offset: 8)
        completed.readingCompleted = true
        for question in first.article.questions {
            try completed.select(question.answer, question: question)
            try completed.submit(question, article: first.article)
        }
        completed.stage = .result
        var rereading = completed
        rereading.resetForReading()
        rereading.anchor = DuAnchor(unitID: "u1", paragraphID: "p1", offset: 3)
        try rereading.select(1, question: second.article.questions[0])
        var legacy = installed.index
        legacy.readingStateVersion = nil
        legacy.progress = [first.id: completed, second.id: rereading]
        legacy.lastArticle = first.id
        legacy.libraryStates = [
            first.id: DuLibraryState(readOverride: false, listeningPromptHandled: true),
            second.id: DuLibraryState(readOverride: false), third.id: DuLibraryState(readOverride: true)]
        let disk = DuDisk(directory: directory)
        try disk.save(legacy)
        let original = try Data(contentsOf: disk.indexURL)
        let migrated = try await repo.load()
        let fresh = migrated.books[0]
        XCTAssertEqual(migrated.index.readingStateVersion, 1)
        XCTAssertFalse(fresh.isRead)
        XCTAssertNil(fresh.progress.anchor)
        XCTAssertEqual(fresh.progress.stage, .reading)
        XCTAssertTrue(fresh.progress.answers.isEmpty)
        XCTAssertTrue(fresh.progress.selections.isEmpty)
        XCTAssertEqual(fresh.progress.firstAnswers, completed.firstAnswers)
        XCTAssertEqual(fresh.progress.attempts, completed.attempts)
        XCTAssertEqual(fresh.libraryState.listeningPromptHandled, true)
        XCTAssertEqual(fresh.progress.readingStartRun, 2)
        XCTAssertNil(migrated.continuingBook)
        XCTAssertNil(migrated.index.lastArticle)
        XCTAssertEqual(migrated.books[1].progress, rereading)
        XCTAssertTrue(migrated.books[2].isRead)
        XCTAssertEqual(migrated.normalizingReadingState().index, migrated.index)
        XCTAssertEqual(try Data(contentsOf: disk.indexURL), original)
        // Restoring a pre-fix backup applies the same migration before it is saved.
        let oldBackup = try JSONEncoder().encode(DuBackup(index: legacy, archives: installed.packages.mapValues(\.archive)))
        try SimpleDuBackupTransfer.restore(oldBackup, directory: restored)
        let recovered = try DuDisk(directory: restored).load()
        XCTAssertEqual(recovered.books[0].progress.stage, .reading)
        XCTAssertNil(recovered.continuingBook)
        XCTAssertEqual(recovered.books[0].progress.attempts, completed.attempts)
        XCTAssertEqual(recovered.books[1].progress, rereading)
        XCTAssertTrue(recovered.books[2].isRead)
        let saved = try await repo.saveProgress(rereading, bookID: second.id)
        XCTAssertEqual(try disk.load().index, saved.index)
    }
    func testLegacyArchiveOnlyDoesNotMakeUnreadArticlesRead() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package(count: 2)).0
        let first = installed.books[0], second = installed.books[1]
        var legacy = installed.index
        legacy.readingStateVersion = nil
        var progress = DuProgress()
        progress.anchor = DuAnchor(unitID: "u1", paragraphID: "p1", offset: 8)
        legacy.progress[first.id] = progress
        legacy.lastArticle = first.id
        legacy.libraryStates = [first.id: DuLibraryState(archived: true),
                                second.id: DuLibraryState(readOverride: true)]
        try DuDisk(directory: directory).save(legacy)
        let migrated = try await repo.load()
        XCTAssertFalse(migrated.books[0].isRead)
        XCTAssertFalse(migrated.books[0].isArchived)
        XCTAssertEqual(migrated.books[0].readingStatus, "阅读中")
        XCTAssertEqual(migrated.books[0].progress, progress)
        XCTAssertEqual(migrated.continuingBook?.id, first.id)
        XCTAssertTrue(migrated.books[1].isRead)
        let backup = try SimpleDuBackupTransfer.exportData(directory: directory)
        XCTAssertTrue(try SimpleDuBackupTransfer.validate(backup).contains("未读文章 1，已读文章 1"))
    }
    func testReadingBeforeQuizOnlyMarksReadAfterAllQuestionsAreSubmitted() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let book = try await repo.install(package()).0.books[0]
        var progress = DuProgress()
        progress.anchor = DuAnchor(unitID: "u1", paragraphID: "p1", offset: 0)
        progress.readingCompleted = true
        let readOnly = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertFalse(readOnly.books[0].isRead)
        for question in book.article.questions.dropLast() {
            try progress.select(1, question: question)
            try progress.submit(question, article: book.article)
        }
        let partial = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertFalse(partial.books[0].isRead)
        XCTAssertEqual(partial.continuingBook?.id, book.id)
        let last = book.article.questions.last!
        try progress.select(1, question: last)
        try progress.submit(last, article: book.article)
        let completed = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertTrue(completed.books[0].isRead)
        XCTAssertTrue(completed.books[0].shouldOfferListening)
        XCTAssertNil(completed.continuingBook)
    }
    func testInvalidBatchSelectionIsAtomicAndDoesNotWrite() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package(count: 2)).0
        let disk = DuDisk(directory: directory), original = try Data(contentsOf: disk.indexURL)
        for ids: Set<String> in [[], [installed.books[0].id, "missing"]] {
            do { _ = try await repo.arrangeArticles(ids, action: .markReadAndArchive); XCTFail("Expected rejection") } catch {}
            XCTAssertEqual(try Data(contentsOf: disk.indexURL), original)
        }
    }
    func testOldIndexInfersCompletedReadingAndRereadCanCompleteAgain() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package()).0
        let book = installed.books[0]
        var progress = DuProgress()
        for question in book.article.questions {
            try progress.select(question.answer, question: question)
            try progress.submit(question, article: book.article)
        }
        progress.stage = .result
        _ = try await repo.saveProgress(progress, bookID: book.id)
        let disk = DuDisk(directory: directory)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: disk.indexURL)) as! [String: Any]
        json.removeValue(forKey: "libraryStates")
        json.removeValue(forKey: "readingStateVersion")
        try JSONSerialization.data(withJSONObject: json).write(to: disk.indexURL)
        let originalIndex = try Data(contentsOf: disk.indexURL)
        let legacy = try DuDisk(directory: directory).load()
        XCTAssertTrue(legacy.books[0].isRead)
        XCTAssertTrue(legacy.books[0].isArchived)
        XCTAssertEqual(try Data(contentsOf: disk.indexURL), originalIndex)
        _ = try await repo.load()
        let unread = try await repo.arrangeArticles([book.id], action: .markUnread)
        XCTAssertFalse(unread.books[0].isRead)
        XCTAssertFalse(unread.books[0].isArchived)
        XCTAssertEqual(unread.index.progress[book.id]?.attempts.count, 1)
        progress = unread.books[0].progress
        progress.readingCompleted = true
        _ = try await repo.saveProgress(progress, bookID: book.id)
        for question in book.article.questions {
            try progress.select(question.answer, question: question)
            try progress.submit(question, article: book.article)
        }
        let completed = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertTrue(completed.books[0].isRead)
        XCTAssertTrue(completed.books[0].isArchived)
        XCTAssertEqual(completed.index.libraryStates?[book.id]?.archived, true)
        XCTAssertEqual(completed.index.progress[book.id]?.attempts.count, 2)
    }
    func testOlderUnarchivedReadMarksMoveToCabinetThroughBackupWithoutChangingProgress() async throws {
        let directory = try folder(), restored = try folder()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: restored) }
        let repo = DuRepository(directory: directory)
        let installed = try await repo.install(package(count: 3)).0
        let first = installed.books[0], second = installed.books[1], third = installed.books[2]
        var progress = DuProgress()
        for question in first.article.questions {
            try progress.select(question.answer, question: question)
            try progress.submit(question, article: first.article)
        }
        _ = try await repo.saveProgress(progress, bookID: first.id)
        var legacy = try DuDisk(directory: directory).load().index
        legacy.readingStateVersion = nil
        // Previous versions could leave both completed and manually read articles on the shelf.
        legacy.libraryStates = [first.id: DuLibraryState(), second.id: DuLibraryState(readOverride: true)]
        try DuDisk(directory: directory).save(legacy)
        let backup = try SimpleDuBackupTransfer.exportData(directory: directory)
        XCTAssertTrue(try SimpleDuBackupTransfer.validate(backup).contains("未读文章 1，已读文章 2"))
        try SimpleDuBackupTransfer.restore(backup, directory: restored)
        let recovered = try DuDisk(directory: restored).load()
        XCTAssertEqual(Set(recovered.books.filter(\.isArchived).map(\.id)), [first.id, second.id])
        XCTAssertFalse(recovered.books.first { $0.id == third.id }!.isRead)
        XCTAssertEqual(recovered.index.progress[first.id], progress)
        XCTAssertNil(recovered.index.progress[second.id])
        let recoveredRepo = DuRepository(directory: restored)
        let unread = try await recoveredRepo.arrangeArticles([first.id, second.id], action: .unarchive)
        XCTAssertTrue(unread.books.allSatisfy { !$0.isRead && !$0.isArchived })
        var rereading = unread.books.first { $0.id == first.id }!.progress
        XCTAssertEqual(rereading.firstAnswers, progress.firstAnswers)
        XCTAssertEqual(rereading.attempts, progress.attempts)
        XCTAssertTrue(rereading.answers.isEmpty)
        // Ordinary reading-position saves must not mark the old completed attempt as read again.
        rereading.anchor = DuAnchor(unitID: "u1", paragraphID: "p1", offset: 0)
        let resumed = try await recoveredRepo.saveProgress(rereading, bookID: first.id)
        XCTAssertFalse(resumed.books.first { $0.id == first.id }!.isArchived)
        XCTAssertEqual(resumed.index.progress[first.id]?.firstAnswers, progress.firstAnswers)
    }
    func testDeletingArchivedBookClearsLibraryStateAndNewEditionStartsFresh() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory), first = try package()
        let initial = try await repo.install(first).0
        let oldID = initial.books[0].id
        _ = try await repo.arrangeArticles([oldID], action: .markReadAndArchive)
        let updated = try await repo.install(package(revision: 2)).0
        XCTAssertFalse(updated.books[0].isRead)
        XCTAssertFalse(updated.books[0].isArchived)
        XCTAssertEqual(updated.index.libraryStates?[oldID]?.archived, true)
        let currentID = updated.books[0].id
        _ = try await repo.arrangeArticles([currentID], action: .archive)
        let deleted = try await repo.deleteArticle(currentID)
        XCTAssertTrue(deleted.books.isEmpty)
        XCTAssertTrue(deleted.index.libraryStates?.isEmpty == true)
    }
    func testListeningOfferRequiresReadingAndAllQuestionsEvenWithZeroCorrectAnswers() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let book = try await repo.install(package()).0.books[0]
        let marked = try await repo.arrangeArticles([book.id], action: .markRead)
        XCTAssertFalse(marked.books[0].shouldOfferListening)
        var progress = DuProgress()
        progress.readingCompleted = true
        for question in book.article.questions.dropLast() {
            try progress.select((question.answer + 1) % 4, question: question)
            try progress.submit(question, article: book.article)
        }
        let partial = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertFalse(partial.books[0].shouldOfferListening)
        let before = try Data(contentsOf: DuDisk(directory: directory).indexURL)
        do { _ = try await repo.acknowledgeListeningOffer(book.id); XCTFail("Incomplete article must not consume the offer") } catch {}
        XCTAssertEqual(try Data(contentsOf: DuDisk(directory: directory).indexURL), before)
        let last = book.article.questions.last!
        try progress.select((last.answer + 1) % 4, question: last)
        try progress.submit(last, article: book.article)
        let completed = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertEqual(progress.score(progress.answers, article: book.article), 0)
        XCTAssertTrue(completed.books[0].shouldOfferListening)
        XCTAssertEqual(completed.books[0].progress.stage, .quiz)
        XCTAssertTrue(completed.books[0].isArchived)
        progress.restart(article: book.article)
        let retry = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertTrue(retry.books[0].shouldOfferListening)
        XCTAssertTrue(retry.books[0].progress.answers.isEmpty)
    }
    func testCompletingQuestionsBeforeReadingOffersOnlyAfterReadingIsFinished() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repo = DuRepository(directory: directory)
        let book = try await repo.install(package()).0.books[0]
        var progress = DuProgress()
        for question in book.article.questions {
            try progress.select(question.answer, question: question)
            try progress.submit(question, article: book.article)
        }
        progress.stage = .result
        let quizOnly = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertFalse(quizOnly.books[0].shouldOfferListening)
        XCTAssertFalse(quizOnly.books[0].isRead)
        XCTAssertFalse(quizOnly.books[0].isArchived)
        XCTAssertEqual(quizOnly.continuingBook?.id, book.id)
        XCTAssertEqual(quizOnly.books[0].readingStatus, "待完成阅读")
        let backup = try SimpleDuBackupTransfer.exportData(directory: directory)
        XCTAssertFalse(try DuBackup.decode(backup).validated().books[0].isRead)
        progress.readingCompleted = true
        let read = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertTrue(read.books[0].shouldOfferListening)
        XCTAssertTrue(read.books[0].isRead)
        XCTAssertTrue(read.books[0].isArchived)
        XCTAssertNil(read.continuingBook)
        XCTAssertTrue(try DuDisk(directory: directory).load().books[0].shouldOfferListening)
    }
    func testListeningOfferChoiceSurvivesRetryUnreadAndBackupAndResetsForNewEdition() async throws {
        let directory = try folder(), restored = try folder()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: restored) }
        let repo = DuRepository(directory: directory)
        let book = try await repo.install(package()).0.books[0]
        var progress = DuProgress()
        progress.readingCompleted = true
        for question in book.article.questions {
            try progress.select(question.answer, question: question)
            try progress.submit(question, article: book.article)
        }
        _ = try await repo.saveProgress(progress, bookID: book.id)
        let pendingBackup = try SimpleDuBackupTransfer.exportData(directory: directory)
        XCTAssertTrue(try DuBackup.decode(pendingBackup).validated().books[0].shouldOfferListening)
        let answered = try await repo.acknowledgeListeningOffer(book.id)
        XCTAssertFalse(answered.books[0].shouldOfferListening)
        XCTAssertEqual(answered.index.progress[book.id], progress)
        let before = try Data(contentsOf: DuDisk(directory: directory).indexURL)
        _ = try await repo.acknowledgeListeningOffer(book.id)
        XCTAssertEqual(try Data(contentsOf: DuDisk(directory: directory).indexURL), before)
        let unread = try await repo.arrangeArticles([book.id], action: .markUnread)
        progress = unread.books[0].progress
        let retry = try await repo.saveProgress(progress, bookID: book.id)
        XCTAssertFalse(retry.books[0].shouldOfferListening)
        let backup = try SimpleDuBackupTransfer.exportData(directory: directory)
        try SimpleDuBackupTransfer.restore(backup, directory: restored)
        let recovered = try DuDisk(directory: restored).load()
        XCTAssertFalse(recovered.books[0].shouldOfferListening)
        XCTAssertEqual(recovered.books[0].libraryState.listeningPromptHandled, true)
        XCTAssertEqual(recovered.index.progress[book.id], progress)
        let updated = try await repo.install(package(revision: 2)).0
        XCTAssertNil(updated.books[0].libraryState.listeningPromptHandled)
        XCTAssertNil(updated.books[0].progress.readingCompleted)
    }
    func testOlderReadingProgressAndLibraryStateDecodeWithoutListeningOfferFields() throws {
        let pack = try package(), article = pack.content.articles[0]
        var progress = DuProgress()
        for question in article.questions {
            try progress.select(question.answer, question: question)
            try progress.submit(question, article: article)
        }
        let decoded = try JSONDecoder().decode(DuProgress.self, from: JSONEncoder().encode(progress))
        let oldState = try JSONDecoder().decode(DuLibraryState.self, from: Data("{\"readOverride\":true,\"archived\":false}".utf8))
        let book = DuBook(package: pack, article: article, progress: decoded, libraryState: oldState)
        XCTAssertTrue(book.isArchived)
        XCTAssertFalse(book.shouldOfferListening)
        XCTAssertNil(decoded.readingCompleted)
        XCTAssertNil(decoded.readingStartRun)
        XCTAssertNil(oldState.listeningPromptHandled)
    }
    func testListeningExportIncludesOnlyChosenArticleBodyAndStableIdentity() throws {
        let pack = try package(count: 2)
        let book = DuBook(package: pack, article: pack.content.articles[0], progress: DuProgress())
        let exported = book.listeningArticle()
        XCTAssertEqual(exported.sourceID, book.id)
        XCTAssertEqual(exported.title, book.article.title)
        XCTAssertEqual(exported.bodyMarkdown, "## A heading\n\nA farm grows food.")
        XCTAssertFalse(exported.bodyMarkdown.contains("What grows food?"))
        XCTAssertFalse(exported.bodyMarkdown.contains("A lamp"))
        XCTAssertFalse(exported.bodyMarkdown.contains("Test fixture"))
        let updated = try package(revision: 2)
        XCTAssertNotEqual(exported.sourceID, DuBook(package: updated, article: updated.content.articles[0], progress: DuProgress()).listeningArticle().sourceID)
    }
    func testListeningExportJoinsPageFragmentsAndDoesNotRepeatRunningHeadings() throws {
        let pack = try package { content in
            content.articles[0].title = "Food"
            content.articles[0].units = [
                DuUnit(id: "u1", heading: "From Wheat", image: "images/photo.png", paragraphs: [
                    DuParagraph(id: "p1-s1", runs: [DuRun(text: "A farm ", target: false), DuRun(text: "grows", target: true), DuRun(text: " ", target: false)])]),
                DuUnit(id: "u2", heading: "From Wheat", image: "images/photo.png", paragraphs: [
                    DuParagraph(id: "p1-s2", runs: [DuRun(text: "food.", target: false)]),
                    DuParagraph(id: "p2-s1", runs: [DuRun(text: "Another sentence.", target: false)])])]
            for i in content.articles[0].questions.indices { content.articles[0].questions[i].evidence = [] }
        }
        let book = DuBook(package: pack, article: pack.content.articles[0], progress: DuProgress())
        XCTAssertEqual(book.listeningArticle().bodyMarkdown, "## From Wheat\n\nA farm **grows** food.\n\nAnother sentence.")
    }
    func testListeningExportEscapesLiteralMarkdownAndSkipsRepeatedTitle() throws {
        let pack = try package { content in
            content.articles[0].units[0].heading = content.articles[0].title
            content.articles[0].units[0].paragraphs[0].runs = [DuRun(text: "An [item] and 2*3.", target: false)]
        }
        let book = DuBook(package: pack, article: pack.content.articles[0], progress: DuProgress())
        XCTAssertEqual(book.listeningArticle().bodyMarkdown, "An \\[item\\] and 2\\*3.")
    }
    func testListeningExportPreservesLiteralAnglesAndExistingEntityText() throws {
        let plain = "Please write <name> & keep &lt; as text."
        let pack = try package { content in
            content.articles[0].units[0].heading = ""
            content.articles[0].units[0].paragraphs[0].runs = [DuRun(text: plain, target: false)]
        }
        let book = DuBook(package: pack, article: pack.content.articles[0], progress: DuProgress())
        let exported = book.listeningArticle()
        XCTAssertEqual(exported.bodyMarkdown, "Please write &lt;name&gt; &amp; keep &amp;lt; as text.")
        let parsed = try AttributedString(markdown: exported.bodyMarkdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        XCTAssertEqual(String(parsed.characters), plain)
    }
    private func le(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
    private func word(_ value: Int) -> Data { Data([UInt8(value & 255), UInt8((value >> 8) & 255)]) }
    private func zip(_ files: [String: Data], attributes: UInt32 = 0) -> Data {
        var output = Data(), directory = Data()
        for (name, bytes) in files.sorted(by: { $0.key < $1.key }) {
            let start = UInt32(output.count), n = Data(name.utf8)
            let crc = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            output += le(0x04034b50) + word(20) + word(0x800) + word(0) + word(0) + word(0)
            output += le(UInt32(crc)) + le(UInt32(bytes.count)) + le(UInt32(bytes.count)) + word(n.count) + word(0) + n + bytes
            directory += le(0x02014b50) + word(20) + word(20) + word(0x800) + word(0) + word(0) + word(0)
            directory += le(UInt32(crc)) + le(UInt32(bytes.count)) + le(UInt32(bytes.count)) + word(n.count) + word(0) + word(0)
            directory += word(0) + word(0) + le(attributes) + le(start) + n
        }
        let start = UInt32(output.count)
        output += directory
        output += le(0x06054b50) + word(0) + word(0) + word(files.count) + word(files.count) + le(UInt32(directory.count)) + le(start) + word(0)
        return output
    }
}
