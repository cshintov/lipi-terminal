import CoreText
import Foundation

struct WrapSourceRow: Codable {
    let sourceRow: Int
    let cells: [String]
    let hardBreak: Bool
    var sourceText: String { cells.joined() }
    // API NUL gaps are display spaces only. Source extraction retains the original NULs.
    var layoutText: String { sourceText.replacingOccurrences(of: "\0", with: " ") }
    var cellBoundaries: [Int] {
        cells.reduce(into: [0]) { $0.append($0.last! + $1.utf16.count) }
    }
}

struct WrapCellSlice: Codable, Equatable {
    let column: Int
    let utf16Start: Int
    let utf16Length: Int
}

struct WrapFragment {
    let rowIndex: Int
    let sourceRange: NSRange
    let line: CTLine
    let advance: CGFloat
    let oversizedCluster: Bool
    var inkBounds: CGRect {
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return bounds.isNull || bounds.isInfinite ? .zero : bounds
    }
    var originX: CGFloat { max(0, -inkBounds.minX) }
    var occupiedWidth: CGFloat { originX + max(advance, inkBounds.maxX) }
}

struct WrapHit: Equatable {
    let sourceRow: Int
    let utf16Index: Int
    let cellColumns: [Int]
    let coreTextStringIndex: Int
}

enum WrapFailure: Error {
    case invalidWidth
    case invalidRow
}

/// Saved-output experiment only. No PTY state, source rewriting or display-row integration.
struct WrappedRows {
    let rows: [WrapSourceRow]
    let width: CGFloat
    let fragments: [WrapFragment]
    let fontSize: CGFloat

    init(rows: [WrapSourceRow], width: CGFloat, fontSize: CGFloat = 20,
         singleRow: Bool = false) throws {
        guard width.isFinite, width > 0, fontSize.isFinite, fontSize > 0 else { throw WrapFailure.invalidWidth }
        guard Set(rows.map(\.sourceRow)).count == rows.count,
              rows.allSatisfy({ !$0.sourceText.contains("\n") && !$0.sourceText.contains("\r") }) else {
            throw WrapFailure.invalidRow
        }
        self.rows = rows
        self.width = width
        self.fontSize = fontSize
        var result: [WrapFragment] = []
        for (index, row) in rows.enumerated() {
            let geometry = try LineGeometry(text: row.layoutText, fontSize: fontSize)
            let typesetter = CTTypesetterCreateWithAttributedString(geometry.attributedString)
            let length = row.layoutText.utf16.count
            let boundaries = row.layoutText.indices.map { $0.utf16Offset(in: row.layoutText) } + [length]
            func fragment(_ start: Int, _ end: Int, oversized: Bool = false) -> WrapFragment {
                let range = CFRange(location: start, length: end - start)
                let line = CTTypesetterCreateLine(typesetter, range)
                return WrapFragment(rowIndex: index, sourceRange: NSRange(location: start, length: end - start),
                    line: line, advance: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)),
                    oversizedCluster: oversized)
            }
            if singleRow || length == 0 {
                result.append(fragment(0, length))
                continue
            }
            var start = 0
            while start < length {
                let next = boundaries.first(where: { $0 > start })!
                let suggested = start + CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                var end = boundaries.last(where: { $0 > start && $0 <= suggested }) ?? next
                var candidate = fragment(start, end)
                // Native word breaks may include trailing spaces or overhanging ink. Never trim source.
                while candidate.occupiedWidth > width && end > next {
                    end = boundaries.last(where: { $0 < end && $0 > start })!
                    candidate = fragment(start, end)
                }
                result.append(fragment(start, end, oversized: candidate.occupiedWidth > width))
                start = end
            }
        }
        fragments = result
    }

    var extractedText: String { rows.map { $0.sourceText + ($0.hardBreak ? "\n" : "") }.joined() }

    func cellSlices(in fragment: WrapFragment) -> [WrapCellSlice] {
        let row = rows[fragment.rowIndex]
        let boundaries = row.cellBoundaries
        return row.cells.indices.compactMap { column in
            let start = max(boundaries[column], fragment.sourceRange.location)
            let end = min(boundaries[column + 1], NSMaxRange(fragment.sourceRange))
            if start < end || (boundaries[column] == boundaries[column + 1] &&
                start == end && start >= fragment.sourceRange.location &&
                (start < NSMaxRange(fragment.sourceRange) || start == row.sourceText.utf16.count)) {
                return WrapCellSlice(column: column, utf16Start: start, utf16Length: end - start)
            }
            return nil
        }
    }

    func legalBoundaries(for rowIndex: Int) -> [Int] {
        let text = rows[rowIndex].layoutText
        return text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
    }

    func x(forSourceIndex index: Int, in fragment: WrapFragment) -> CGFloat? {
        guard index >= fragment.sourceRange.location, index <= NSMaxRange(fragment.sourceRange),
              legalBoundaries(for: fragment.rowIndex).contains(index) else { return nil }
        return fragment.originX + CTLineGetOffsetForStringIndex(fragment.line, index, nil)
    }

    // Nearest Swift-grapheme boundary, not a claim that each inferred stop is a native caret.
    func hit(x: CGFloat, fragmentIndex: Int) -> WrapHit? {
        guard x.isFinite, fragments.indices.contains(fragmentIndex) else { return nil }
        let fragment = fragments[fragmentIndex]
        let candidates = legalBoundaries(for: fragment.rowIndex).filter {
            $0 >= fragment.sourceRange.location && $0 <= NSMaxRange(fragment.sourceRange)
        }
        guard let index = candidates.min(by: {
            abs(CTLineGetOffsetForStringIndex(fragment.line, $0, nil) + fragment.originX - x) <
                abs(CTLineGetOffsetForStringIndex(fragment.line, $1, nil) + fragment.originX - x)
        }) else { return nil }
        let row = rows[fragment.rowIndex]
        let boundaries = row.cellBoundaries
        var columns = boundaries.indices.filter { boundaries[$0] == index }
        if columns.isEmpty {
            columns = row.cells.indices.filter { boundaries[$0] < index && index < boundaries[$0 + 1] }
        }
        let nativeIndex = CTLineGetStringIndexForPosition(fragment.line,
            CGPoint(x: x - fragment.originX, y: 0))
        return WrapHit(sourceRow: row.sourceRow, utf16Index: index, cellColumns: columns,
                       coreTextStringIndex: nativeIndex)
    }
}
