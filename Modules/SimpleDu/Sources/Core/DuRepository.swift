import Foundation
import StudyShell

struct DuInstallation: Codable, Equatable {
    var key: String
    var batchID: String
    var revision: Int
    var sequence: Int
    var importedAt: Date
}
struct DuLibraryState: Codable, Equatable {
    var readOverride: Bool? = nil
    var archived = false
    var listeningPromptHandled: Bool? = nil
}

enum DuLibraryAction {
    case markRead, markUnread, archive, unarchive, markReadAndArchive
    var resultText: String {
        switch self {
        case .markRead: "篇已标为已读"
        case .markUnread: "篇已标为未读"
        case .archive: "篇已移至已读文章"
        case .unarchive: "篇已标为未读"
        case .markReadAndArchive: "篇已标为已读"
        }
    }
}

struct DuIndex: Codable, Equatable {
    var schemaVersion = 1
    var readingStateVersion: Int? = 1
    var installations: [DuInstallation] = []
    var progress: [String: DuProgress] = [:]
    var fontSize: Double = 28
    var lastArticle: String?
    var deletedArticles: [String]? = nil
    var libraryStates: [String: DuLibraryState]? = nil

    static func deletionKey(_ batchID: String, _ articleID: String) -> String { "\(batchID):\(articleID)" }
    func isDeleted(batchID: String, articleID: String) -> Bool {
        (deletedArticles ?? []).contains(Self.deletionKey(batchID, articleID))
    }

    func validated(packages: [String: DuPackage]) throws {
        try duRequire(readingStateVersion == nil || readingStateVersion == 1, "阅读状态版本暂不受支持。")
        try duRequire(schemaVersion == 1 && Set(installations.map(\.key)).count == installations.count &&
                      Set(installations.map(\.sequence)).count == installations.count &&
                      Set(installations.map(\.key)) == Set(packages.keys) && (24...36).contains(fontSize), "简单读文章列表数据无效，原文件已保留。")
        var editions = Set<String>(), validKeys = Set<String>(), articleIdentities = Set<String>()
        for item in installations {
            let package = packages[item.key]!
            try duRequire(item.batchID == package.manifest.batchID && item.revision == package.manifest.revision && item.sequence > 0 &&
                          editions.insert("\(item.batchID):\(item.revision)").inserted, "简单读阅读包记录不一致。")
            for article in package.content.articles {
                let key = Self.articleKey(item.key, article.id)
                articleIdentities.insert(Self.deletionKey(item.batchID, article.id))
                if !isDeleted(batchID: item.batchID, articleID: article.id) { validKeys.insert(key) }
                if let value = progress[key] { try value.validated(article: article) }
            }
        }
        let deleted = deletedArticles ?? []
        try duRequire(Set(deleted).count == deleted.count && Set(deleted).isSubset(of: articleIdentities), "文章删除记录无效。")
        try duRequire(Set((libraryStates ?? [:]).keys).isSubset(of: validKeys), "阅读状态缺少对应文章。")
        try duRequire(Set(progress.keys).isSubset(of: validKeys) && (lastArticle.map { validKeys.contains($0) } ?? true), "简单读进度缺少对应文章。")
    }
    static func articleKey(_ package: String, _ article: String) -> String { "\(package):\(article)" }
}
struct DuBook: Identifiable {
    let package: DuPackage
    let article: DuArticle
    let progress: DuProgress
    var libraryState = DuLibraryState()
    var isRead: Bool { libraryState.readOverride ?? progress.hasCompletedStudy }
    var isArchived: Bool { isRead }
    var canContinue: Bool { !isArchived && (progress.anchor != nil || progress.stage != .reading) }
    var shouldOfferListening: Bool {
        progress.hasCompletedStudy && libraryState.listeningPromptHandled != true
    }
    var readingStatus: String {
        if isRead { return "已读" }
        if progress.stage == .quiz { return "答题中" }
        if progress.stage == .result && progress.readingCompleted != true { return "待完成阅读" }
        return progress.anchor == nil ? "未读" : "阅读中"
    }
    var id: String { DuIndex.articleKey(package.key, article.id) }
    var dayLabel: String { dayNumber.map { "Day \($0)" } ?? "Reading" }
    var articleLabel: String {
        let siblings = package.content.articles.filter { Self.day(of: $0, package: package) == dayNumber }
        guard siblings.count > 1 else { return "Article" }
        let number = article.articleNumber ?? Self.capture("^day[0-9]+-article([1-9][0-9]*)$", in: article.id)
            ?? ((siblings.firstIndex { $0.id == article.id } ?? 0) + 1)
        return "Article \(number)"
    }
    var shelfLabel: String { "\(dayLabel), \(articleLabel)" }
    var dayNumber: Int? { Self.day(of: article, package: package) }
    private static func day(of article: DuArticle, package: DuPackage) -> Int? {
        article.dayNumber ?? capture("^day0*([1-9][0-9]*)-article[0-9]+$", in: article.id)
            ?? capture("^ket-day0*([1-9][0-9]*)$", in: package.manifest.batchID)
    }
    private static func capture(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}
struct DuSnapshot {
    var index: DuIndex
    var packages: [String: DuPackage]
    var continuingBook: DuBook? {
        books.first { $0.id == index.lastArticle && $0.canContinue }
    }
    var books: [DuBook] {
        let active = Dictionary(grouping: index.installations, by: \.batchID).values.compactMap { $0.max { $0.revision < $1.revision } }
        return active.sorted { $0.sequence > $1.sequence }.flatMap { item in
            let package = packages[item.key]!
            return package.content.articles.filter {
                !index.isDeleted(batchID: item.batchID, articleID: $0.id)
            }.map { article in
                DuBook(package: package, article: article, progress: index.progress[DuIndex.articleKey(package.key, article.id)] ?? DuProgress(),
                       libraryState: index.libraryStates?[DuIndex.articleKey(package.key, article.id)] ?? DuLibraryState())
            }
        }
    }
    func normalizingReadingState() -> DuSnapshot {
        guard index.readingStateVersion == nil else { return self }
        var value = self
        var states = index.libraryStates ?? [:]
        for id in Set(index.progress.keys).union(states.keys) {
            var state = states[id] ?? DuLibraryState()
            if state.readOverride == false && index.progress[id]?.readingStartRun == nil {
                var progress = index.progress[id] ?? DuProgress()
                progress.resetForReading()
                value.index.progress[id] = progress
                if value.index.lastArticle == id { value.index.lastArticle = nil }
            } else if state.readOverride == nil && !(index.progress[id]?.attempts.isEmpty ?? true) {
                // Preserve the read status inferred by older versions from completed quizzes.
                state.readOverride = true
            }
            state.archived = state.readOverride ?? (value.index.progress[id]?.hasCompletedStudy ?? false)
            states[id] = state
        }
        value.index.libraryStates = states
        value.index.readingStateVersion = 1
        return value
    }
}

enum DuImportKind: String {
    case new = "新文章", update = "更新版本", restore = "重新导入已删文章", duplicate = "已导入", older = "较旧版本", conflict = "版本冲突"
    var canImport: Bool { self == .new || self == .update || self == .restore }
}
struct DuImportItem: Identifiable {
    let id = UUID()
    let filename: String
    let package: DuPackage?
    let error: String?
}

struct DuDisk {
    let directory: URL
    var indexURL: URL { directory.appendingPathComponent("Index.json") }
    func archiveURL(_ key: String) throws -> URL {
        try duRequire(key.count == 64 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "阅读包存储编号无效。")
        return directory.appendingPathComponent("Packages", isDirectory: true).appendingPathComponent(key + ".simpledu")
    }
    func load() throws -> DuSnapshot {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return DuSnapshot(index: DuIndex(), packages: [:]) }
        let index = try JSONDecoder().decode(DuIndex.self, from: Data(contentsOf: indexURL))
        var packages: [String: DuPackage] = [:]
        for item in index.installations {
            let package = try DuPackage.decode(Data(contentsOf: archiveURL(item.key)))
            try duRequire(package.key == item.key, "本地阅读包校验失败，原文件已保留。")
            packages[item.key] = package
        }
        try index.validated(packages: packages)
        return DuSnapshot(index: index, packages: packages).normalizingReadingState()
    }
    func writeArchive(_ package: DuPackage, preservingCorrupt: Bool = false) throws {
        let url = try archiveURL(package.key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            // Verify an existing orphan too, rather than trusting its filename.
            do {
                let existing = try DuPackage.decode(Data(contentsOf: url))
                try duRequire(existing.key == package.key, "本地同名阅读包校验失败。")
            } catch {
                guard preservingCorrupt else { throw error }
                let folder = directory.appendingPathComponent("PreservedFiles", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let preserved = folder.appendingPathComponent("\(package.key)-\(UUID().uuidString).simpledu")
                try FileManager.default.copyItem(at: url, to: preserved)
                try package.archive.write(to: url, options: .atomic)
            }
        } else { try package.archive.write(to: url, options: .atomic) }
    }
    func save(_ index: DuIndex) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }
}

actor DuRepository {
    let disk: DuDisk
    private var snapshot: DuSnapshot?
    init(directory: URL) { disk = DuDisk(directory: directory) }
    func load() throws -> DuSnapshot {
        let result = try disk.load(); snapshot = result; return result
    }
    static func kind(_ package: DuPackage, in snapshot: DuSnapshot) -> DuImportKind {
        if snapshot.packages[package.key] != nil {
            let latest = snapshot.index.installations.filter { $0.batchID == package.manifest.batchID }.map(\.revision).max()
            let hasDeleted = package.content.articles.contains { snapshot.index.isDeleted(batchID: package.manifest.batchID, articleID: $0.id) }
            return latest == package.manifest.revision && hasDeleted ? .restore : .duplicate
        }
        let editions = snapshot.index.installations.filter { $0.batchID == package.manifest.batchID }
        if editions.contains(where: { $0.revision == package.manifest.revision }) { return .conflict }
        if let revision = editions.map(\.revision).max() {
            return revision < package.manifest.revision ? .update : .older
        }
        return .new
    }
    func install(_ package: DuPackage) throws -> (DuSnapshot, DuImportKind) {
        var current = try snapshot ?? disk.load()
        let kind = Self.kind(package, in: current)
        guard kind.canImport else { return (current, kind) }
        if kind == .restore {
            let restoring = Set(package.content.articles.map { DuIndex.deletionKey(package.manifest.batchID, $0.id) })
            current.index.deletedArticles = (current.index.deletedArticles ?? []).filter { !restoring.contains($0) }
            try current.index.validated(packages: current.packages)
            try disk.save(current.index); snapshot = current
            return (current, kind)
        }
        try disk.writeArchive(package)
        current.packages[package.key] = package
        current.index.installations.append(DuInstallation(key: package.key, batchID: package.manifest.batchID,
            revision: package.manifest.revision, sequence: (current.index.installations.map(\.sequence).max() ?? 0) + 1, importedAt: Date()))
        try current.index.validated(packages: current.packages)
        try disk.save(current.index); snapshot = current
        return (current, kind)
    }
    func deleteArticle(_ bookID: String) throws -> DuSnapshot {
        var current = try snapshot ?? disk.load()
        guard let book = current.books.first(where: { $0.id == bookID }) else { throw DuError("文章已删除或已更新，请返回文章列表刷新。") }
        let batch = book.package.manifest.batchID
        var deleted = Set(current.index.deletedArticles ?? [])
        deleted.insert(DuIndex.deletionKey(batch, book.article.id))
        current.index.deletedArticles = deleted.sorted()
        // Remove saved selections, first answers and all attempts from every installed edition.
        // The shared source package remains immutable for the other articles in the same package.
        for item in current.index.installations where item.batchID == batch {
            let key = DuIndex.articleKey(item.key, book.article.id)
            current.index.progress.removeValue(forKey: key)
            current.index.libraryStates?.removeValue(forKey: key)
            if current.index.lastArticle == key { current.index.lastArticle = nil }
        }
        try current.index.validated(packages: current.packages)
        try disk.save(current.index); snapshot = current
        return current
    }
    func arrangeArticles(_ ids: Set<String>, action: DuLibraryAction) throws -> DuSnapshot {
        var current = try snapshot ?? disk.load()
        let books = Dictionary(uniqueKeysWithValues: current.books.map { ($0.id, $0) })
        try duRequire(!ids.isEmpty && ids.isSubset(of: Set(books.keys)), "所选文章已改变，请刷新文章列表后重新选择。")
        var states = current.index.libraryStates ?? [:]
        for id in ids {
            var state = states[id] ?? DuLibraryState()
            switch action {
            case .markRead, .archive, .markReadAndArchive: state.readOverride = true; state.archived = true
            case .markUnread, .unarchive:
                state.readOverride = false; state.archived = false
                var progress = current.index.progress[id] ?? DuProgress()
                progress.resetForReading()
                current.index.progress[id] = progress
                if current.index.lastArticle == id { current.index.lastArticle = nil }
            }
            states[id] = state
        }
        current.index.libraryStates = states
        try current.index.validated(packages: current.packages)
        try disk.save(current.index); snapshot = current
        return current
    }
    func acknowledgeListeningOffer(_ bookID: String) throws -> DuSnapshot {
        var current = try snapshot ?? disk.load()
        guard let book = current.books.first(where: { $0.id == bookID }) else { throw DuError("这篇文章已更新，请返回文章列表重新打开。") }
        if book.libraryState.listeningPromptHandled == true { return current }
        try duRequire(book.shouldOfferListening, "请先完成文章阅读和全部题目。")
        var state = book.libraryState
        state.listeningPromptHandled = true
        if current.index.libraryStates == nil { current.index.libraryStates = [:] }
        current.index.libraryStates?[bookID] = state
        try current.index.validated(packages: current.packages)
        try disk.save(current.index); snapshot = current
        return current
    }
    func saveProgress(_ progress: DuProgress, bookID: String, fontSize: Double? = nil) throws -> DuSnapshot {
        var current = try snapshot ?? disk.load()
        guard let book = current.books.first(where: { $0.id == bookID }) else { throw DuError("这篇文章已更新，请返回文章列表重新打开。") }
        try progress.validated(article: book.article)
        if progress.hasCompletedStudy && !book.progress.hasCompletedStudy {
            var state = current.index.libraryStates?[bookID] ?? DuLibraryState()
            state.readOverride = true
            state.archived = true
            if current.index.libraryStates == nil { current.index.libraryStates = [:] }
            current.index.libraryStates?[bookID] = state
        }
        current.index.progress[bookID] = progress; current.index.lastArticle = bookID
        if let fontSize { current.index.fontSize = fontSize }
        try current.index.validated(packages: current.packages)
        try disk.save(current.index); snapshot = current; return current
    }
}

struct DuBackup: Codable {
    var app = "SimpleXue"
    var module = "SimpleDu"
    var formatVersion = 1
    var index: DuIndex
    var archives: [String: Data]
    func validated() throws -> DuSnapshot {
        try duRequire(app == "SimpleXue" && module == "SimpleDu" && formatVersion == 1, "这不是简单读的完整备份。")
        var packages: [String: DuPackage] = [:]
        for (key, archive) in archives {
            let package = try DuPackage.decode(archive)
            try duRequire(package.key == key, "简单读备份阅读包校验失败。")
            packages[key] = package
        }
        try index.validated(packages: packages)
        return DuSnapshot(index: index, packages: packages).normalizingReadingState()
    }
    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        _ = try value.validated(); return value
    }
}

public enum SimpleDuBackupTransfer {
    private static func disk(_ directory: URL?) throws -> DuDisk {
        DuDisk(directory: try directory ?? ModuleStorage.directory("SimpleDu"))
    }
    public static func exportData(directory: URL? = nil) throws -> Data {
        let current = try disk(directory).load()
        let backup = DuBackup(index: current.index, archives: current.packages.mapValues(\.archive))
        return try JSONEncoder().encode(backup)
    }
    public static func validate(_ data: Data) throws -> String {
        let value = try DuBackup.decode(data).validated()
        let archived = value.books.filter(\.isArchived).count
        return "文章 \(value.books.count) 篇（未读文章 \(value.books.count - archived)，已读文章 \(archived)），包含插图、历史版本、阅读状态与答题进度"
    }
    public static func restore(_ data: Data, directory: URL? = nil) throws {
        let incoming = try DuBackup.decode(data).validated(), disk = try disk(directory)
        // Immutable archives first, atomic index last. A failed write leaves the current index intact.
        for package in incoming.packages.values { try disk.writeArchive(package, preservingCorrupt: true) }
        if FileManager.default.fileExists(atPath: disk.indexURL.path) {
            let safety = disk.directory.appendingPathComponent("SafetyBackups", isDirectory: true)
            try FileManager.default.createDirectory(at: safety, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: disk.indexURL, to: safety.appendingPathComponent("PreRestore-\(UUID().uuidString).json"))
        }
        try disk.save(incoming.index)
    }
}

private enum DuListeningBlock {
    case heading(String)
    case paragraph(stem: String?, sequence: Int?, runs: [DuRun])
}

extension DuBook {
    func listeningArticle() -> SimpleDuListeningArticle {
        var blocks: [DuListeningBlock] = []
        var previousHeading = ""
        for unit in article.units {
            let heading = unit.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            if !heading.isEmpty && heading.caseInsensitiveCompare(article.title) != .orderedSame && heading != previousHeading {
                blocks.append(.heading(heading))
            }
            previousHeading = heading
            for paragraph in unit.paragraphs {
                let fragment = Self.listeningFragment(paragraph.id)
                // Migration packages split some source paragraphs across picture pages.
                // Rejoin only consecutive fragments of that known form, keeping the original spaces.
                if let fragment, let last = blocks.last,
                   case let .paragraph(stem, sequence, oldRuns) = last,
                   stem == fragment.stem, sequence.map({ $0 + 1 }) == fragment.sequence {
                    blocks[blocks.count - 1] = .paragraph(stem: fragment.stem, sequence: fragment.sequence, runs: oldRuns + paragraph.runs)
                } else {
                    blocks.append(.paragraph(stem: fragment?.stem, sequence: fragment?.sequence, runs: paragraph.runs))
                }
            }
        }
        let markdown = blocks.map { block -> String in
            switch block {
            case .heading(let heading): return "## " + Self.listeningEscape(heading)
            case .paragraph(_, _, let runs):
                var merged: [DuRun] = []
                for run in runs {
                    if merged.last?.target == run.target { merged[merged.count - 1].text += run.text }
                    else { merged.append(run) }
                }
                return merged.map { run in
                    let text = Self.listeningEscape(run.text)
                    return run.target ? "**\(text)**" : text
                }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.joined(separator: "\n\n")
        return SimpleDuListeningArticle(sourceID: id, title: article.title, bodyMarkdown: markdown)
    }
    private static func listeningFragment(_ id: String) -> (stem: String, sequence: Int)? {
        guard let regex = try? NSRegularExpression(pattern: "^(p[0-9]+)-s([1-9][0-9]*)$"),
              let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
              let stemRange = Range(match.range(at: 1), in: id), let sequenceRange = Range(match.range(at: 2), in: id),
              let sequence = Int(id[sequenceRange]) else { return nil }
        return (String(id[stemRange]), sequence)
    }
    private static func listeningEscape(_ text: String) -> String {
        let special: Set<Character> = ["\\", "`", "*", "_", "[", "]", "#"]
        return text.map { character in
            switch character {
            case "&": return "&amp;"
            case "<": return "&lt;"
            case ">": return "&gt;"
            default: return special.contains(character) ? "\\\(character)" : String(character)
            }
        }.joined()
    }
}
