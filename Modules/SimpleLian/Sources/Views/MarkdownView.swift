import SwiftUI

struct MarkdownView: View {
    let text: String

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let value):
                    Text(inline(value))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(inline(value))
                    }
                case .numbered(let number, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number).")
                        Text(inline(value))
                    }
                case .table(let table):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            GridRow {
                                ForEach(Array(table.headers.enumerated()), id: \.offset) { _, cell in
                                    Text(inline(cell)).bold()
                                }
                            }
                            Divider()
                            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                                GridRow {
                                    ForEach(0..<table.headers.count, id: \.self) { index in
                                        Text(inline(index < row.count ? row[index] : ""))
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
}

private enum MarkdownBlock {
    case paragraph(String)
    case bullet(String)
    case numbered(Int, String)
    case table(MarkdownTable)

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { index += 1; continue }
            if index + 1 < lines.count, lines[index + 1].contains("---") {
                var tableLines = [lines[index], lines[index + 1]]
                var cursor = index + 2
                while cursor < lines.count, lines[cursor].contains("|") {
                    tableLines.append(lines[cursor]); cursor += 1
                }
                if let table = MarkdownTableParser.parse(tableLines) {
                    blocks.append(.table(table)); index = cursor; continue
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]), line.index(after: dot) < line.endIndex {
                blocks.append(.numbered(number, String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
            } else {
                blocks.append(.paragraph(line))
            }
            index += 1
        }
        return blocks
    }
}
