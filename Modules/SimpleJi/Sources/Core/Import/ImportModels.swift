import Foundation

struct ParsedVocabularyEntry: Identifiable, Equatable {
    let id: UUID
    let lineNumber: Int
    let originalLine: String
    let english: String
    let normalizedEnglish: String
    let chinese: String

    init(
        id: UUID = UUID(),
        lineNumber: Int,
        originalLine: String,
        english: String,
        chinese: String
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.originalLine = originalLine
        self.english = english
        self.normalizedEnglish = EnglishNormalizer.normalize(english)
        self.chinese = chinese
    }
}

struct UnrecognizedVocabularyLine: Identifiable, Equatable {
    let id: UUID
    let lineNumber: Int
    let text: String
    let reason: String

    init(id: UUID = UUID(), lineNumber: Int, text: String, reason: String) {
        self.id = id
        self.lineNumber = lineNumber
        self.text = text
        self.reason = reason
    }
}

struct VocabularyParseResult: Equatable {
    let totalLineCount: Int
    let ignoredLineCount: Int
    let entries: [ParsedVocabularyEntry]
    let unrecognized: [UnrecognizedVocabularyLine]
}

struct ExistingWordSnapshot: Equatable {
    let english: String
    let normalizedEnglish: String
    let chinese: String
}

struct ImportConflict: Identifiable, Equatable {
    let id: UUID
    let incoming: ParsedVocabularyEntry
    let existingEnglish: String
    let existingChinese: String

    init(
        id: UUID = UUID(),
        incoming: ParsedVocabularyEntry,
        existingEnglish: String,
        existingChinese: String
    ) {
        self.id = id
        self.incoming = incoming
        self.existingEnglish = existingEnglish
        self.existingChinese = existingChinese
    }
}

struct ImportAnalysis: Equatable {
    let totalLineCount: Int
    let ignoredLineCount: Int
    let recognizedCount: Int
    let additions: [ParsedVocabularyEntry]
    let existing: [ParsedVocabularyEntry]
    let conflicts: [ImportConflict]
    let unrecognized: [UnrecognizedVocabularyLine]

    var canImport: Bool { !additions.isEmpty }
}

struct ImportCommitResult: Equatable {
    let insertedWords: Int
    let createdReviewStates: Int
    let skippedBecauseAlreadyPresent: Int
}
