import SwiftUI

struct MarkdownBodyView: View {
    let markdown: String
    private struct Block: Identifiable {
        let id: Int
        let text: String
        let heading: Bool
    }
    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(Block(id: result.count, text: paragraph.joined(separator: "\n"), heading: false)); paragraph = [] }
        }
        for line in markdown.components(separatedBy: "\n") {
            if let heading = ListenRegex.heading(line) { flush(); result.append(Block(id: result.count, text: heading, heading: true)) }
            else if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else if ListenRegex.captures("^(?:[-*_]\\s*){3,}$", line.trimmingCharacters(in: .whitespaces)) == nil { paragraph.append(line) }
        }
        flush()
        return result
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(blocks) { block in
                Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                    .font(block.heading ? .title2.weight(.semibold) : .title3)
                    .lineSpacing(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }
}

#Preview {
    ScrollView { MarkdownBodyView(markdown: "An English paragraph with **important words**.\n\n## A Section\nA second paragraph.").padding(24) }
}
