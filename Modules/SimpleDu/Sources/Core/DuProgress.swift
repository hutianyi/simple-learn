import Foundation

enum DuStage: String, Codable { case reading, quiz, result }
struct DuAnchor: Codable, Equatable {
    var unitID: String
    var paragraphID: String
    var offset: Int
}
struct DuAttempt: Codable, Equatable {
    var run: Int
    var answers: [String: Int]
    var finishedAt: Date
}
struct DuProgress: Codable, Equatable {
    var anchor: DuAnchor?
    var stage: DuStage = .reading
    var currentQuestionID: String?
    var selections: [String: Int] = [:]
    var answers: [String: Int] = [:]
    var firstAnswers: [String: Int] = [:]
    var attempts: [DuAttempt] = []
    var run = 1
    var updatedAt = Date()
    var readingCompleted: Bool? = nil
    var readingStartRun: Int? = nil

    var hasCompletedStudy: Bool {
        readingCompleted == true && attempts.contains { $0.run >= (readingStartRun ?? 1) }
    }

    mutating func select(_ choice: Int, question: DuQuestion) throws {
        try duRequire((0..<4).contains(choice) && answers[question.id] == nil, "这道题已提交，请继续下一题。")
        selections[question.id] = choice; currentQuestionID = question.id; stage = .quiz
    }
    mutating func submit(_ question: DuQuestion, article: DuArticle) throws {
        try duRequire(answers[question.id] == nil, "这道题已经提交。")
        guard let choice = selections[question.id] else { throw DuError("请先选择一个答案。") }
        answers[question.id] = choice
        if firstAnswers[question.id] == nil { firstAnswers[question.id] = choice }
        if answers.count == article.questions.count {
            attempts.append(DuAttempt(run: run, answers: answers, finishedAt: Date()))
        }
    }
    mutating func restart(article: DuArticle) {
        run += 1; answers = [:]; selections = [:]; stage = .quiz
        currentQuestionID = article.questions.first?.id
    }
    mutating func resetForReading() {
        if !selections.isEmpty || !answers.isEmpty || attempts.contains(where: { $0.run == run }) { run += 1 }
        anchor = nil; stage = .reading; currentQuestionID = nil
        selections = [:]; answers = [:]; readingCompleted = false
        readingStartRun = run
        updatedAt = Date()
    }
    func validated(article: DuArticle) throws {
        let questions = Set(article.questions.map(\.id))
        for values in [selections, answers, firstAnswers] + attempts.map(\.answers) {
            try duRequire(Set(values.keys).isSubset(of: questions) && values.values.allSatisfy { (0..<4).contains($0) }, "保存的答题记录无效。")
        }
        try duRequire(run >= 1 && run <= 100_000 && (currentQuestionID.map { questions.contains($0) } ?? true), "答题位置无效。")
        try duRequire(readingStartRun.map { $0 >= 1 && $0 <= run } ?? true, "阅读轮次无效。")
        try duRequire(answers.allSatisfy { selections[$0.key] == $0.value } && Set(answers.keys).isSubset(of: Set(firstAnswers.keys)), "答题记录不完整。")
        try duRequire(Set(attempts.map(\.run)).count == attempts.count && attempts.allSatisfy { $0.run > 0 && $0.run <= run && Set($0.answers.keys) == questions }, "练习历史不完整。")
        if stage == .result { try duRequire(answers.count == article.questions.count, "答题尚未完成。") }
        if let anchor {
            guard let unit = article.units.first(where: { $0.id == anchor.unitID }),
                  let paragraph = unit.paragraphs.first(where: { $0.id == anchor.paragraphID }) else { throw DuError("阅读位置无效。") }
            try duRequire(anchor.offset >= 0 && anchor.offset <= paragraph.text.utf16.count, "阅读位置无效。")
        }
    }
    func score(_ answers: [String: Int], article: DuArticle) -> Int {
        article.questions.filter { answers[$0.id] == $0.answer }.count
    }
}
