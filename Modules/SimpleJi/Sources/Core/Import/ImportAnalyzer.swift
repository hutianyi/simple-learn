import Foundation

enum ImportAnalyzer {
    static func analyze(
        parseResult: VocabularyParseResult,
        existingWords: [ExistingWordSnapshot]
    ) -> ImportAnalysis {
        var knownByNormalized = Dictionary(
            uniqueKeysWithValues: existingWords.map { ($0.normalizedEnglish, $0) }
        )
        var additions: [ParsedVocabularyEntry] = []
        var existing: [ParsedVocabularyEntry] = []
        var conflicts: [ImportConflict] = []

        for entry in parseResult.entries {
            if let known = knownByNormalized[entry.normalizedEnglish] {
                if equivalentChinese(entry.chinese, known.chinese) {
                    existing.append(entry)
                } else {
                    conflicts.append(
                        ImportConflict(
                            incoming: entry,
                            existingEnglish: known.english,
                            existingChinese: known.chinese
                        )
                    )
                }
            } else {
                additions.append(entry)
                knownByNormalized[entry.normalizedEnglish] = ExistingWordSnapshot(
                    english: entry.english,
                    normalizedEnglish: entry.normalizedEnglish,
                    chinese: entry.chinese
                )
            }
        }

        return ImportAnalysis(
            totalLineCount: parseResult.totalLineCount,
            ignoredLineCount: parseResult.ignoredLineCount,
            recognizedCount: parseResult.entries.count,
            additions: additions,
            existing: existing,
            conflicts: conflicts,
            unrecognized: parseResult.unrecognized
        )
    }

    private static func equivalentChinese(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
