import Foundation
import ImageIO

struct DuManifest: Codable, Equatable {
    var format: String
    var schemaVersion: Int
    var batchID: String
    var revision: Int
    var title: String
    var files: [String: String]
}

struct DuRun: Codable, Equatable { var text: String; var target: Bool }
struct DuParagraph: Codable, Equatable, Identifiable {
    var id: String
    var runs: [DuRun]
    var text: String { runs.map(\.text).joined() }
}
struct DuUnit: Codable, Equatable, Identifiable {
    var id: String
    var heading: String
    var image: String
    var paragraphs: [DuParagraph]
}
struct DuQuestion: Codable, Equatable, Identifiable {
    var id: String
    var prompt: String
    var options: [String]
    var answer: Int
    var explanation: String
    var evidence: [String]
}
struct DuSource: Codable, Equatable { var title: String; var url: String }
struct DuArticle: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var cover: String
    var units: [DuUnit]
    var questions: [DuQuestion]
    var sources: [DuSource]
    var dayNumber: Int? = nil
    var articleNumber: Int? = nil
}
struct DuImageAsset: Codable, Equatable {
    var path: String
    var alt: String
    var credit: String
}
struct DuContent: Codable, Equatable {
    var articles: [DuArticle]
    var images: [DuImageAsset]
}

struct DuPackage {
    let archive: Data
    let manifest: DuManifest
    let content: DuContent
    let files: [String: Data]
    let key: String

    static func decode(_ data: Data) throws -> Self {
        let files = try DuArchive.read(data)
        guard let manifestData = files["manifest.json"], manifestData.count <= 128 * 1024,
              let contentData = files["content.json"], contentData.count <= 2 * 1024 * 1024 else {
            throw DuError("阅读包缺少 manifest.json 或 content.json，或内容过大。")
        }
        let decoder = JSONDecoder()
        let manifest: DuManifest, content: DuContent
        do {
            manifest = try decoder.decode(DuManifest.self, from: manifestData)
            content = try decoder.decode(DuContent.self, from: contentData)
        } catch { throw DuError("阅读包内容格式不完整。请使用简单读 v1 阅读包。") }
        try duRequire(manifest.format == "SimpleDu" && manifest.schemaVersion == 1, "此阅读包版本暂不支持，请更新 App 后再试。")
        try duRequire(validID(manifest.batchID) && (1...1_000_000).contains(manifest.revision) && validText(manifest.title, max: 180), "阅读包批次信息无效。")
        try duRequire(Set(manifest.files.keys) == Set(files.keys).subtracting(["manifest.json"]), "阅读包文件清单不完整。")
        for (name, hash) in manifest.files {
            try duRequire(hash == duHash(files[name]!), "阅读包校验失败：\(name)。")
        }
        try validate(content, files: files)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Self(archive: data, manifest: manifest, content: content, files: files,
                    key: duHash(try encoder.encode(manifest)))
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func validText(_ value: String, max: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= max &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }
    private static func uniqueIDs(_ values: [String]) -> Bool {
        Set(values).count == values.count && values.allSatisfy(validID)
    }
    private static func validate(_ content: DuContent, files: [String: Data]) throws {
        try duRequire((1...30).contains(content.articles.count) && uniqueIDs(content.articles.map(\.id)), "文章编号重复或文章数量不受支持。")
        let paths = content.images.map(\.path)
        try duRequire(!paths.isEmpty && Set(paths).count == paths.count && paths.count <= 200, "阅读包插图清单无效。")
        for image in content.images {
            try duRequire(image.path.hasPrefix("images/") && DuArchive.safePath(image.path) &&
                          ["jpg", "jpeg", "png"].contains((image.path as NSString).pathExtension.lowercased()) &&
                          validText(image.alt, max: 1000) && validText(image.credit, max: 2000), "插图缺少说明、来源或使用了不支持的格式。")
            guard let data = files[image.path], let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw DuError("插图无法读取：\(image.path)。") }
            try duRequire(width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 24_000_000,
                          "插图尺寸过大：\(image.path)。")
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary
            try duRequire(CGImageSourceCreateThumbnailAtIndex(source, 0, options) != nil, "插图文件损坏：\(image.path)。")
        }
        for article in content.articles {
            try duRequire(article.dayNumber.map { (1...1_000_000).contains($0) } ?? true, "文章 Day 编号无效。")
            try duRequire(article.articleNumber.map { (1...1_000_000).contains($0) } ?? true, "文章 Article 编号无效。")
            try duRequire(validText(article.title, max: 180) && paths.contains(article.cover) &&
                          (1...80).contains(article.units.count) && uniqueIDs(article.units.map(\.id)), "文章标题、封面或阅读单元无效。")
            let paragraphs = article.units.flatMap(\.paragraphs)
            try duRequire(uniqueIDs(paragraphs.map(\.id)) && paragraphs.count <= 400, "文章段落编号重复或数量过多。")
            var characters = 0
            for unit in article.units {
                try duRequire(unit.heading.utf16.count <= 180 && paths.contains(unit.image) && !unit.paragraphs.isEmpty, "阅读单元缺少正文或插图。")
                for paragraph in unit.paragraphs {
                    try duRequire((1...200).contains(paragraph.runs.count) && validText(paragraph.text, max: 10_000) &&
                                  paragraph.runs.allSatisfy { !$0.text.isEmpty }, "文章段落为空或文字过长。")
                    characters += paragraph.text.utf16.count
                }
            }
            try duRequire(characters <= 60_000, "文章文字过长。")
            try duRequire((1...60).contains(article.questions.count) && uniqueIDs(article.questions.map(\.id)), "题目编号重复或数量不受支持。")
            for question in article.questions {
                try duRequire(validText(question.prompt, max: 1000) && question.options.count == 4 &&
                              question.options.allSatisfy { validText($0, max: 1000) } && Set(question.options).count == 4 &&
                              (0..<4).contains(question.answer) && question.explanation.utf16.count <= 2000 &&
                              Set(question.evidence).isSubset(of: Set(paragraphs.map(\.id))), "题目、答案或正文依据无效。")
            }
            for source in article.sources {
                let url = URL(string: source.url)
                try duRequire(validText(source.title, max: 500) && ["http", "https"].contains(url?.scheme?.lowercased() ?? "") && url?.host != nil,
                              "事实来源链接无效。")
            }
        }
    }
}

public struct SimpleDuListeningArticle: Sendable {
    public let sourceID: String
    public let title: String
    public let bodyMarkdown: String
}
