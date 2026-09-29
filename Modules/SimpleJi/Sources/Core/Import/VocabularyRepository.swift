import CoreData
import Foundation

final class VocabularyRepository {
    enum RepositoryError: LocalizedError {
        case invalidEntry

        var errorDescription: String? {
            switch self {
            case .invalidEntry:
                return "词条缺少有效的英文或中文内容。"
            }
        }
    }

    private let container: NSPersistentContainer
    private let calendar: Calendar

    init(container: NSPersistentContainer, calendar: Calendar = .current) {
        self.container = container
        self.calendar = calendar
    }

    func analyze(_ parseResult: VocabularyParseResult) async throws -> ImportAnalysis {
        let normalized = Set(parseResult.entries.map(\.normalizedEnglish))
        let existing = try await existingSnapshots(for: normalized)
        return ImportAnalyzer.analyze(parseResult: parseResult, existingWords: existing)
    }

    func importAdditions(
        _ entries: [ParsedVocabularyEntry],
        now: Date = Date()
    ) async throws -> ImportCommitResult {
        guard entries.allSatisfy({ !$0.normalizedEnglish.isEmpty && !$0.chinese.isEmpty }) else {
            throw RepositoryError.invalidEntry
        }

        let context = container.newBackgroundContext()
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        let startOfToday = calendar.startOfDay(for: now)

        return try await context.perform {
            do {
                let normalizedValues = Array(Set(entries.map(\.normalizedEnglish)))
                let request = WordEntity.fetchRequest()
                request.predicate = NSPredicate(format: "normalizedEnglish IN %@", normalizedValues)
                request.propertiesToFetch = ["normalizedEnglish"]
                let alreadyPresent = Set(try context.fetch(request).map(\.normalizedEnglish))

                var inserted = 0
                var skipped = 0

                for (position, entry) in entries.enumerated() {
                    guard !alreadyPresent.contains(entry.normalizedEnglish) else {
                        skipped += 1
                        continue
                    }

                    let word = WordEntity(context: context)
                    word.id = UUID()
                    word.english = entry.english.trimmingCharacters(in: .whitespacesAndNewlines)
                    word.normalizedEnglish = entry.normalizedEnglish
                    word.chinese = entry.chinese.trimmingCharacters(in: .whitespacesAndNewlines)
                    word.importPosition = Int64(position)
                    word.createdAt = now
                    word.updatedAt = now

                    for direction in ReviewDirection.allCases {
                        let state = ReviewStateEntity(context: context)
                        state.id = UUID()
                        state.direction = direction.rawValue
                        state.level = 0
                        state.nextReviewDate = startOfToday
                        state.fsrsCardData = try SRSScheduler.encodeCard(
                            SRSScheduler.emptyCard(due: startOfToday)
                        )
                        state.fsrsMigrationVersion = SRSScheduler.migrationVersion
                        state.createdAt = now
                        state.updatedAt = now
                        state.word = word
                    }
                    inserted += 1
                }

                if context.hasChanges { try context.save() }
                return ImportCommitResult(
                    insertedWords: inserted,
                    createdReviewStates: inserted * ReviewDirection.allCases.count,
                    skippedBecauseAlreadyPresent: skipped
                )
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private func existingSnapshots(
        for normalizedEnglish: Set<String>
    ) async throws -> [ExistingWordSnapshot] {
        guard !normalizedEnglish.isEmpty else { return [] }
        let context = container.newBackgroundContext()
        context.undoManager = nil

        return try await context.perform {
            let request = WordEntity.fetchRequest()
            request.predicate = NSPredicate(
                format: "normalizedEnglish IN %@",
                Array(normalizedEnglish)
            )
            return try context.fetch(request).map {
                ExistingWordSnapshot(
                    english: $0.english,
                    normalizedEnglish: $0.normalizedEnglish,
                    chinese: $0.chinese
                )
            }
        }
    }
}
