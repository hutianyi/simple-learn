import Foundation

public enum ImportParserError: LocalizedError, Equatable {
    case empty
    case tooLarge(maxBytes: Int)
    case multipleFencedBlocks
    case malformedFence
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "没有可导入的内容。"
        case .tooLarge(let maxBytes): return "导入内容超过 \(maxBytes / 1_024 / 1_024) MB。"
        case .multipleFencedBlocks: return "一次只能导入一个 simplelian-json 代码块。"
        case .malformedFence: return "simplelian-json 代码块没有正确结束。"
        case .invalidJSON(let detail): return "JSON 无法解析：\(detail)"
        }
    }
}

public enum ImportParser {
    public static let defaultMaximumBytes = 5 * 1_024 * 1_024

    public static func parse(_ input: String, maximumBytes: Int = defaultMaximumBytes) throws -> SimpleLianPayload {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportParserError.empty
        }
        guard input.utf8.count <= maximumBytes else {
            throw ImportParserError.tooLarge(maxBytes: maximumBytes)
        }

        let jsonText = try extractJSON(from: input)
        do {
            return try JSONDecoder().decode(SimpleLianPayload.self, from: Data(jsonText.utf8))
        } catch {
            throw ImportParserError.invalidJSON(error.localizedDescription)
        }
    }

    public static func extractJSON(from input: String) throws -> String {
        let marker = "```simplelian-json"
        let ranges = input.ranges(of: marker)
        if ranges.count > 1 { throw ImportParserError.multipleFencedBlocks }
        guard let markerRange = ranges.first else {
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let afterMarker = input[markerRange.upperBound...]
        guard let closing = afterMarker.range(of: "```") else {
            throw ImportParserError.malformedFence
        }
        let trailing = afterMarker[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty else { throw ImportParserError.multipleFencedBlocks }
        return String(afterMarker[..<closing.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ImportFileError: LocalizedError {
    case unsupportedType, invalidEncoding

    public var errorDescription: String? {
        switch self {
        case .unsupportedType: return "请选择 TXT 或 JSON 题库文件。"
        case .invalidEncoding: return "文件不是 UTF-8 文本，请重新生成题库文件。"
        }
    }
}

public enum ImportFileReader {
    public static func read(_ url: URL) throws -> String {
        guard ["txt", "json"].contains(url.pathExtension.lowercased()) else {
            throw ImportFileError.unsupportedType
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // Coordinate with iCloud and bound the read before decoding untrusted files.
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let handle = try FileHandle(forReadingFrom: readableURL)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: ImportParser.defaultMaximumBytes + 1) ?? Data()
                guard data.count <= ImportParser.defaultMaximumBytes else {
                    throw ImportParserError.tooLarge(maxBytes: ImportParser.defaultMaximumBytes)
                }
                guard var text = String(data: data, encoding: .utf8) else {
                    throw ImportFileError.invalidEncoding
                }
                if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
                return text
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}

private extension String {
    func ranges(of text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = startIndex
        while cursor < endIndex, let range = range(of: text, range: cursor..<endIndex) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }
}
