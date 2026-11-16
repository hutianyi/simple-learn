import Foundation
import CryptoKit
import zlib

struct DuError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func duRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DuError(message) }
}

func duHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// Read ZIP entries in memory. Nothing from an archive is extracted to a supplied path.
// Limits apply before allocation and again after inflation; ZIP64 and encrypted ZIPs are rejected.
enum DuArchive {
    static let maxArchiveBytes = 64 * 1024 * 1024
    static let maxExpandedBytes = 96 * 1024 * 1024
    static let maxEntryBytes = 16 * 1024 * 1024

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count < 240 && !path.hasPrefix("/") && !path.contains("\\") &&
        !path.contains(":") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func read(_ input: Data) throws -> [String: Data] {
        let data = Data(input)
        try duRequire(data.count >= 22 && data.count <= maxArchiveBytes, "阅读包过大或不是完整的 ZIP 文件。")
        let b = [UInt8](data)
        func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        let lower = max(0, b.count - 65557)
        guard let end = stride(from: b.count - 22, through: lower, by: -1).first(where: {
            u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == b.count
        }) else { throw DuError("阅读包不完整，请等待 iCloud 下载完成后重新选择。") }
        let count = u16(end + 10), directorySize = u32(end + 12), directory = u32(end + 16)
        try duRequire(u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 8) == count && count > 0 && count <= 256,
                      "阅读包的分卷或文件数量不受支持。")
        try duRequire(directory >= 0 && directory + directorySize == end, "阅读包目录损坏或使用了不支持的 ZIP64。")
        var offset = directory, total = 0, result: [String: Data] = [:]
        var names = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<count {
            try duRequire(offset + 46 <= end, "阅读包目录不完整。")
            try duRequire(u32(offset) == 0x02014b50, "阅读包目录损坏。")
            let flags = u16(offset + 8), method = u16(offset + 10), checksum = u32(offset + 16)
            let compressed = u32(offset + 20), expanded = u32(offset + 24)
            let nameLength = u16(offset + 28), extra = u16(offset + 30), comment = u16(offset + 32)
            let local = u32(offset + 42), attributes = u32(offset + 38)
            let next = offset + 46 + nameLength + extra + comment
            try duRequire(next <= end && u16(offset + 34) == 0 && flags & ~0x0808 == 0 && [0, 8].contains(method),
                          "阅读包含有不支持的压缩方式或加密内容。")
            guard let name = String(bytes: b[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8) else {
                throw DuError("阅读包内文件名必须使用 UTF-8。")
            }
            try duRequire(safePath(name) && names.insert(name.lowercased()).inserted, "阅读包含有不安全或重复的文件名。")
            try duRequire((attributes >> 16) & 0xf000 != 0xa000, "阅读包不能包含链接文件。")
            try duRequire(expanded <= maxEntryBytes && total + expanded <= maxExpandedBytes, "阅读包解压后过大。")
            try duRequire(local >= 0 && local + 30 <= directory && u32(local) == 0x04034b50, "阅读包文件头损坏。")
            let localName = u16(local + 26), localExtra = u16(local + 28)
            let start = local + 30 + localName + localExtra, finish = start + compressed
            try duRequire(finish <= directory && u16(local + 6) == flags && u16(local + 8) == method && localName == nameLength,
                          "阅读包文件头与目录不一致。")
            try duRequire(Array(b[(local + 30)..<(local + 30 + localName)]) == Array(name.utf8), "阅读包文件名不一致。")
            if flags & 8 == 0 {
                try duRequire(u32(local + 14) == checksum && u32(local + 18) == compressed && u32(local + 22) == expanded,
                              "阅读包文件大小不一致。")
            }
            let range = local..<finish
            try duRequire(!ranges.contains { $0.overlaps(range) }, "阅读包包含重叠的文件。")
            ranges.append(range)
            let encoded = Data(b[start..<finish])
            let decoded = try method == 0 ? encoded : inflate(encoded, size: expanded)
            try duRequire(decoded.count == expanded, "阅读包文件长度校验失败。")
            let crc = decoded.withUnsafeBytes { buffer in crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)) }
            try duRequire(Int(crc) == checksum, "阅读包文件损坏，校验失败。")
            result[name] = decoded; total += decoded.count; offset = next
        }
        try duRequire(offset == end, "阅读包目录数量不一致。")
        return result
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        var stream = z_stream()
        try duRequire(inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK,
                      "无法读取阅读包压缩内容。")
        defer { inflateEnd(&stream) }
        var output = Data(count: max(1, size))
        let status: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { target in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(target.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        try duRequire(status == Z_STREAM_END && stream.total_out == size && stream.avail_in == 0,
                      "阅读包压缩内容损坏或长度不符。")
        return output.prefix(size)
    }
}
