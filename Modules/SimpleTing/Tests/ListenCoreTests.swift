import Foundation
import XCTest
@testable import SimpleTing

final class ListenCoreTests: XCTestCase {
    private func draft(_ day: Int, count: Int = 2) throws -> ImportDraft {
        try MarkdownArticleParser.parse((1...count).map { "# Article \($0): Title \($0)\n\nBody \($0).\n" }.joined(separator: "\n"), fileName: "Day \(day).md")
    }
    private func library() throws -> ListenLibrary { try ListenLibrary().importing([draft(7), draft(1, count: 3)]) }

    func testParsesArticlesAfterQuestionsAndSkipsAppendixHeadings() throws {
        let text = """
        # Article 1: First: A title
        A **smartphone** works.
        ## Inside
        Body.
        ## Reading Comprehension
        1. Question?
        A. Option
        # ARTICLE 3 — Second
        Another paragraph.
        # Answer Key
        ## Article 1
        1. A
        ## Article 3
        1. B
        # Fact Sources
        ## Article 1
        A source
        """
        let value = try MarkdownArticleParser.parse(text, fileName: "Day 001.md")
        XCTAssertEqual(value.dayNumber, 1)
        XCTAssertEqual(value.articles.map(\.articleNumber), [1, 3])
        XCTAssertEqual(value.articles[0].title, "First: A title")
        XCTAssertEqual(value.articles[0].speechText, "A smartphone works.\nInside.\nBody.")
        XCTAssertFalse(value.articles.contains { $0.speechText.contains("Option") || $0.speechText.contains("source") })
    }
    func testHeadingVariantsAndWhitespace() throws {
        for separator in [":", "：", "-", "—", "–"] {
            let item = try MarkdownArticleParser.parse("\u{feff}  ### aRtIcLe 2 \(separator) A title ###\r\nText.\r\n ## REFERENCES: \r\nIgnore.", fileName: "day 0002.txt")
            XCTAssertEqual(item.articles.count, 1)
            XCTAssertEqual(item.articles[0].title, "A title")
            XCTAssertEqual(item.articles[0].speechText, "Text.")
            XCTAssertEqual(item.dayNumber, 2)
        }
    }
    func testBodyMentionAndFencedExampleDoNotStartArticles() throws {
        let item = try MarkdownArticleParser.parse("# Article 1: Real\nThe phrase Article 2: is body text.\n```md\n# Article 8: Fake\nCode\n```\n## Good heading\nMore body.", fileName: "Story.md")
        XCTAssertEqual(item.articles.count, 1)
        XCTAssertFalse(item.articles[0].speechText.contains("Fake"))
        XCTAssertTrue(item.articles[0].speechText.contains("Good heading."))
    }
    func testRejectsMalformedMaterial() {
        for text in ["No articles.", "# Article 1\nBody", "# Article 1: Title\n", "# Article 1: A\nBody\n# Article 1: B\nBody", "# Article 1: A\nBody\n```\nUnclosed", "# Article 1: A\n| table | cell |"] {
            XCTAssertThrowsError(try MarkdownArticleParser.parse(text, fileName: "Day 1.md"))
        }
    }
    func testCleanerPreservesPunctuationLinksAndWords() throws {
        XCTAssertEqual(try MarkdownCleaner.plainText("A **smartphone** takes a *photograph*.\nUse `PC` and [a website](https://example.com).\n\n## A heading\n---\n![picture](image.png)"), "A smartphone takes a photograph.\nUse PC and a website.\n\nA heading.")
        XCTAssertEqual(try MarkdownCleaner.plainText("A_B, 1989, en-US, and \"a quote\"."), "A_B, 1989, en-US, and \"a quote\".")
        XCTAssertEqual(try MarkdownCleaner.plainText("[A link](https://example.com/a(b))."), "A link.")
        XCTAssertEqual(try MarkdownCleaner.plainText("A URL: <https://example.com>."), "A URL: .")
    }
    func testDayIdentityDoesNotMatchAnEmbeddedWeekday() throws {
        let value = try MarkdownArticleParser.parse("# Article 1: A\nBody", fileName: "Birthday 04.markdown")
        XCTAssertNil(value.dayNumber)
        XCTAssertEqual(value.sourceKey, "file:birthday 04")
    }
    func testForwardUsesImportOrderAndReverseReversesArticles() throws {
        let value = try library()
        let forward = PlaybackQueue.build(value, order: .forward)
        XCTAssertEqual(forward.map { value.day(for: $0.articleID)!.dayNumber! }, [7, 7, 1, 1, 1])
        XCTAssertEqual(forward.map { value.article($0.articleID)!.articleNumber }, [1, 2, 1, 2, 3])
        XCTAssertEqual(PlaybackQueue.build(value, order: .reverse), Array(forward.reversed()))
    }
    func testUpdateKeepsSequenceIdentityAndFirstImportDate() throws {
        let first = Date(timeIntervalSince1970: 1_000)
        let initial = try ListenLibrary().importing([draft(1), draft(2)], at: first)
        let replacement = try MarkdownArticleParser.parse("# Article 1: Changed\nNew text.\n# Article 3: Added\nAdded text.", fileName: "Day 001.txt")
        let updated = try initial.importing([replacement], at: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(updated.days[0].id, initial.days[0].id)
        XCTAssertEqual(updated.days[0].articles[0].id, initial.days[0].articles[0].id)
        XCTAssertEqual(updated.days[0].firstImportedAt, first)
        XCTAssertEqual(updated.days.map(\.importSequence), [1, 2])
        XCTAssertEqual(updated.nextImportSequence, 3)
        XCTAssertEqual(updated.days[0].articles.map(\.articleNumber), [1, 3])
    }
    func testConflictingBatchIsRejectedWithoutChangingValue() throws {
        let value = try library()
        let snapshot = value
        XCTAssertThrowsError(try value.importing([draft(3), draft(3)]))
        XCTAssertEqual(value, snapshot)
    }
    func testBatchNaturalOrderAndClockChangesDoNotControlLibraryOrder() throws {
        let batch = MarkdownArticleParser.defaultOrder(try [draft(10), draft(2), draft(1)])
        XCTAssertEqual(batch.map(\.dayNumber), [1, 2, 10])
        let value = try ListenLibrary().importing([draft(10)], at: Date(timeIntervalSince1970: 500)).importing([draft(2)], at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(value.newestFirst.map(\.dayNumber), [2, 10])
    }
    func testShuffleContainsEveryArticleAndHonorsStartAndCycleBoundary() throws {
        let value = try library()
        let ids = Set(value.days.flatMap(\.articles).map(\.id))
        let start = value.days[1].articles[1].id
        for _ in 0..<30 {
            let queue = PlaybackQueue.build(value, order: .shuffle, startingAt: start)
            XCTAssertEqual(Set(queue.map(\.articleID)), ids)
            XCTAssertEqual(queue.count, ids.count)
            XCTAssertEqual(queue.first?.articleID, start)
            XCTAssertNotEqual(PlaybackQueue.build(value, order: .shuffle, avoidingFirst: start).first?.articleID, start)
        }
    }
    func testStorageRoundTripAndWriteFailurePreserveOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appendingPathComponent("library.json"))
        let value = try library()
        try file.save(value)
        XCTAssertEqual(try file.load(), value)
        let original = try Data(contentsOf: file.url)
        let broken = LibraryFile(url: file.url, writer: { _, _ in throw ListenError.message("Disk failure") })
        XCTAssertThrowsError(try broken.save(value.importing([draft(3)])))
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try file.load(), value)
    }
    func testCorruptLibraryIsNotReplacedOnLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.json")
        let bad = Data("broken JSON".utf8)
        try bad.write(to: url)
        XCTAssertThrowsError(try LibraryFile(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }
    func testSessionStaleCompletionCannotAdvanceAfterStopOrReplacement() async throws {
        let value = try library()
        try await MainActor.run {
            let session = PlaybackSession(loopEnabled: false)
            session.library = value
            let old = try XCTUnwrap(session.begin())
            session.stop()
            XCTAssertNil(session.finished(old.id))
            let current = try XCTUnwrap(session.begin(value.days[1].articles[1].id))
            XCTAssertNil(session.finished(old.id))
            XCTAssertEqual(session.requestID, current.id)
            XCTAssertTrue(session.started(current.id))
            let next = try XCTUnwrap(session.finished(current.id))
            XCTAssertEqual(value.article(next.item.articleID)?.articleNumber, 3)
            XCTAssertTrue(session.started(next.id))
            XCTAssertNil(session.finished(next.id))
            XCTAssertEqual(session.state, .stopped)
        }
    }
    func testPauseResumeAndModeChangeKeepCurrentRequest() async throws {
        let value = try library()
        try await MainActor.run {
            let session = PlaybackSession()
            session.library = value
            let request = try XCTUnwrap(session.begin(value.days[1].articles[1].id))
            session.started(request.id); session.paused()
            session.changeOrder(.reverse)
            XCTAssertEqual(session.state, .paused)
            XCTAssertEqual(session.requestID, request.id)
            XCTAssertEqual(session.selectedArticleID, request.item.articleID)
            XCTAssertNil(session.finished(request.id))
            session.resumed()
            let next = try XCTUnwrap(session.finished(request.id))
            XCTAssertEqual(value.article(next.item.articleID)?.articleNumber, 1)
        }
    }
    func testTimerRunsWhilePausedAndBlocksExpiredResumeAndFinish() async throws {
        let value = try library()
        try await MainActor.run {
            var clock = Date(timeIntervalSince1970: 500)
            let session = PlaybackSession(now: { clock })
            session.library = value
            session.setTimer(minutes: 10)
            let request = try XCTUnwrap(session.begin())
            session.started(request.id); session.paused()
            clock = clock.addingTimeInterval(601)
            XCTAssertTrue(session.expired)
            XCTAssertEqual(session.secondsRemaining, 0)
            session.resumed()
            XCTAssertEqual(session.state, .paused)
            XCTAssertNil(session.restartCurrent())
            XCTAssertEqual(session.state, .stopped)
            XCTAssertNil(session.timerEndDate)
            XCTAssertNil(session.finished(request.id))
        }
    }
    func testResetTimerAndSongChangePreserveDeadline() async throws {
        let value = try library()
        await MainActor.run {
            var clock = Date(timeIntervalSince1970: 1_000)
            let session = PlaybackSession(now: { clock })
            session.library = value
            session.setTimer(minutes: 20)
            let deadline = session.timerEndDate
            _ = session.begin(); _ = session.move(1)
            XCTAssertEqual(session.timerEndDate, deadline)
            clock = clock.addingTimeInterval(60)
            session.setTimer(minutes: 10)
            XCTAssertEqual(session.timerEndDate, clock.addingTimeInterval(600))
            session.beginStopping()
            XCTAssertNil(session.requestID)
            XCTAssertNil(session.timerEndDate)
        }
    }
    func testEmptySingleAndLoopingQueues() async throws {
        let value = try ListenLibrary().importing([draft(1, count: 1)])
        try await MainActor.run {
            let session = PlaybackSession(order: .shuffle)
            XCTAssertNil(session.begin())
            session.library = value
            let request = try XCTUnwrap(session.begin())
            session.started(request.id)
            let next = try XCTUnwrap(session.finished(request.id))
            XCTAssertEqual(next.item, request.item)
            XCTAssertNotEqual(next.id, request.id)
        }
    }
    func testPreviousBoundaryDoesNotCancelTheCurrentArticle() async throws {
        let value = try library()
        try await MainActor.run {
            let session = PlaybackSession(loopEnabled: false)
            session.library = value
            session.restoreSelection(nil)
            XCTAssertFalse(session.canGoPrevious)
            let first = try XCTUnwrap(session.begin())
            session.started(first.id)
            XCTAssertNil(session.move(-1))
            XCTAssertEqual(session.requestID, first.id)
            XCTAssertEqual(session.state, .playing)
            session.loopEnabled = true
            XCTAssertTrue(session.canGoPrevious)
            let wrapped = try XCTUnwrap(session.move(-1))
            XCTAssertEqual(wrapped.item.articleID, value.days[1].articles.last?.id)
        }
    }
    func testPastedMarkdownExtractsArticlesWithoutDayIdentity() throws {
        let text = """
        # Day 99
        # Article 1: First
        First body.
        ## Reading Comprehension
        1. A question?
        # Article 2: Second
        Second body.
        # Answer Key
        ## Article 1
        1. A
        ## Article 2
        1. B
        """
        let pasted = try MarkdownArticleParser.parsePastedText(text)
        XCTAssertNil(pasted.dayNumber)
        XCTAssertTrue(pasted.sourceKey.hasPrefix("paste:"))
        XCTAssertEqual(pasted.title, "First")
        XCTAssertEqual(pasted.articles.map(\.title), ["First", "Second"])
        XCTAssertEqual(pasted.articles.map(\.speechText), ["First body.", "Second body."])
    }
    func testRepeatedPastesAppendAndKeepSuccessfulImportOrder() throws {
        let text = "# Day 1\n# Article 1: A\nBody.\n# Article 2: B\nAnother body."
        let a = try MarkdownArticleParser.parsePastedText(text)
        let b = try MarkdownArticleParser.parsePastedText(text)
        XCTAssertNotEqual(a.sourceKey, b.sourceKey)
        let initial = try ListenLibrary().importing([draft(7)], at: Date(timeIntervalSince1970: 1_000))
        let saved = try initial.importing([a], at: Date(timeIntervalSince1970: 500)).importing([b], at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(saved.days.count, 3)
        XCTAssertEqual(saved.days.map(\.importSequence), [1, 2, 3])
        XCTAssertEqual(saved.days[0], initial.days[0])
        XCTAssertNotEqual(saved.days[1].articles[0].id, saved.days[2].articles[0].id)
        let forward = PlaybackQueue.build(saved, order: .forward)
        XCTAssertEqual(forward.map { saved.day(for: $0.articleID)!.importSequence }, [1, 1, 2, 2, 3, 3])
        XCTAssertEqual(PlaybackQueue.build(saved, order: .reverse), Array(forward.reversed()))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appendingPathComponent("library.json"))
        try file.save(saved)
        XCTAssertEqual(try file.load(), saved)
    }
    func testInvalidPasteCannotProduceAnImport() throws {
        let library = try ListenLibrary().importing([draft(1)])
        for text in ["", "  \n ", "# Day 1\nNo articles", "# Article 1: Title\n"] {
            XCTAssertThrowsError(try MarkdownArticleParser.parsePastedText(text))
        }
        XCTAssertEqual(library.days.count, 1)
        XCTAssertEqual(library.nextImportSequence, 2)
    }
    func testRealMaterialsWhenProvided() throws {
        #if SWIFT_PACKAGE
        guard let path = Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Fixtures") else { throw XCTSkip("Private material corpus was not supplied.") }
        struct Entry: Decodable { let name: String; let text: String; let count: Int }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: path))
        var count = 0
        for entry in entries {
            let parsed = try MarkdownArticleParser.parsePastedText(entry.text)
            XCTAssertNil(parsed.dayNumber)
            XCTAssertEqual(parsed.articles.count, entry.count, entry.name)
            for article in parsed.articles {
                XCTAssertFalse(article.speechText.contains("Reading Comprehension"))
                XCTAssertFalse(article.speechText.contains("Answer Key"))
                XCTAssertFalse(article.speechText.contains("Fact Sources"))
                XCTAssertNil(ListenRegex.captures("(?m)^\\s*[A-D]\\.\\s+", article.speechText))
                XCTAssertNil(ListenRegex.captures("(?m)^\\s*\\d+\\.\\s+[A-D]\\s*$", article.speechText))
            }
            count += parsed.articles.count
        }
        XCTAssertEqual(entries.count, 7)
        XCTAssertEqual(count, 12)
        #else
        throw XCTSkip("Private corpus is verified by Scripts/run-listen-validation.py.")
        #endif
    }
}
