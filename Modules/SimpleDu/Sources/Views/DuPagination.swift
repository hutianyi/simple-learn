import SwiftUI
#if canImport(UIKit)
import UIKit
private typealias DuLayoutFont = UIFont
private let duLayoutTextColor = UIColor.label
private let duLayoutTargetColor = UIColor.systemTeal
#else
import AppKit
private typealias DuLayoutFont = NSFont
private let duLayoutTextColor = NSColor.labelColor
private let duLayoutTargetColor = NSColor.systemTeal
#endif

struct DuPageBlock: Identifiable {
    var id: String { paragraphID + ":\(offset)" }
    let paragraphID: String
    let offset: Int
    let length: Int
    let text: AttributedString
}
struct DuPage: Identifiable {
    var id: String { unit.id + ":" + (blocks.first?.id ?? "") }
    let unit: DuUnit
    let blocks: [DuPageBlock]
    var anchor: DuAnchor { DuAnchor(unitID: unit.id, paragraphID: blocks[0].paragraphID, offset: blocks[0].offset) }
    func contains(_ anchor: DuAnchor) -> Bool {
        unit.id == anchor.unitID && blocks.contains { $0.paragraphID == anchor.paragraphID &&
            anchor.offset >= $0.offset && anchor.offset < $0.offset + $0.length }
    }
}

@MainActor
enum DuPagination {
    static func attributed(_ paragraph: DuParagraph, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let style = NSMutableParagraphStyle(); style.lineSpacing = fontSize * 0.18
        for run in paragraph.runs {
            result.append(NSAttributedString(string: run.text, attributes: [
                .font: DuLayoutFont.systemFont(ofSize: fontSize, weight: run.target ? .bold : .regular),
                .foregroundColor: run.target ? duLayoutTargetColor : duLayoutTextColor,
                .paragraphStyle: style
            ]))
        }
        return result
    }
    static func pages(_ article: DuArticle, width: CGFloat, height: CGFloat, fontSize: CGFloat) -> [DuPage] {
        let width = max(100, width), budget = max(fontSize * 2, height - 100)
        var result: [DuPage] = []
        for unit in article.units {
            var blocks: [DuPageBlock] = [], used: CGFloat = 0
            func flush() {
                if !blocks.isEmpty { result.append(DuPage(unit: unit, blocks: blocks)); blocks = []; used = 0 }
            }
            for paragraph in unit.paragraphs {
                let text = attributed(paragraph, fontSize: fontSize), plain = text.string as NSString
                var start = 0
                while start < text.length {
                    let remaining = budget - used
                    var low = 1, high = text.length - start, fit = 0
                    while low <= high {
                        let middle = (low + high) / 2
                        let range = plain.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: middle))
                        let length = min(text.length - start, range.location + range.length - start)
                        let slice = text.attributedSubstring(from: NSRange(location: start, length: length))
                        let measured = slice.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
                        if measured + 14 <= remaining { fit = length; low = middle + 1 } else { high = middle - 1 }
                    }
                    if fit == 0 && !blocks.isEmpty { flush(); continue }
                    if fit == 0 { fit = plain.rangeOfComposedCharacterSequence(at: start).length }
                    if start + fit < text.length {
                        // Prefer a word boundary; preserve all original characters in the next page.
                        let candidate = plain.substring(with: NSRange(location: start, length: fit)) as NSString
                        let boundary = candidate.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
                        if boundary.location != NSNotFound && boundary.location > 0 { fit = boundary.location + boundary.length }
                    }
                    let slice = text.attributedSubstring(from: NSRange(location: start, length: fit))
                    blocks.append(DuPageBlock(paragraphID: paragraph.id, offset: start, length: fit, text: AttributedString(slice)))
                    used += slice.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height + 14
                    start += fit
                    if start < text.length { flush() }
                }
            }
            flush()
        }
        return result
    }
}
