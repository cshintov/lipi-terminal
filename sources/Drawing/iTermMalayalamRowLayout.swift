import CoreText
import Foundation

@objc enum iTermMalayalamCaretKind: Int {
    case nativeEdge
    case provisionalClusterStart
    case unresolved
}

@objcMembers final class iTermMalayalamNativeEdge: NSObject {
    let x: CGFloat
    let utf16Index: Int
    let leading: Bool

    init(x: CGFloat, utf16Index: Int, leading: Bool) {
        self.x = x
        self.utf16Index = utf16Index
        self.leading = leading
    }
}

@objcMembers final class iTermMalayalamCellProjection: NSObject {
    let logicalColumn: Int
    let utf16Index: Int
    let anchorUTF16Index: Int
    let kind: iTermMalayalamCaretKind
    let nativeEdge: iTermMalayalamNativeEdge?

    init(column: Int, index: Int, anchor: Int, kind: iTermMalayalamCaretKind,
         edge: iTermMalayalamNativeEdge?) {
        logicalColumn = column
        utf16Index = index
        anchorUTF16Index = anchor
        self.kind = kind
        nativeEdge = edge
    }
}

@objcMembers final class iTermMalayalamRowHit: NSObject {
    let utf16Index: Int
    let logicalColumns: [NSNumber]
    let nativeEdge: iTermMalayalamNativeEdge

    init(index: Int, columns: [NSNumber], edge: iTermMalayalamNativeEdge) {
        utf16Index = index
        logicalColumns = columns
        nativeEdge = edge
    }
}

@objcMembers final class iTermMalayalamRowSelection: NSObject {
    let logicalColumns: NSRange
    let utf16Range: NSRange
    let sourceText: String
    let startsInsideCluster: Bool
    let endsInsideCluster: Bool

    init(columns: NSRange, utf16Range: NSRange, text: String,
         startsInside: Bool, endsInside: Bool) {
        logicalColumns = columns
        self.utf16Range = utf16Range
        sourceText = text
        startsInsideCluster = startsInside
        endsInsideCluster = endsInside
    }
}

/// Natural row geometry. Terminal cell ownership is supplied by the caller.
@objc(iTermMalayalamRowLayout)
final class iTermMalayalamRowLayout: NSObject {
    @objc let attributedString: NSAttributedString
    @objc let cellUTF16Boundaries: [NSNumber]
    @objc let line: CTLine
    @objc let naturalWidth: CGFloat
    @objc let nativeEdges: [iTermMalayalamNativeEdge]
    private let clusterBoundaries: [Int]
    private let resolvedEdges: [Int: iTermMalayalamNativeEdge]
    private let logicalColumnsByIndex: [Int: [NSNumber]]

    @objc init?(attributedString: NSAttributedString, cellUTF16Boundaries: [NSNumber]) {
        let text = attributedString.string as NSString
        guard cellUTF16Boundaries.first == 0,
              cellUTF16Boundaries.last?.intValue == text.length else { return nil }
        var previous = 0
        for number in cellUTF16Boundaries {
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= Double(text.length),
                  value.rounded(.towardZero) == value else { return nil }
            let offset = number.intValue
            guard offset >= previous else { return nil }
            if offset > 0 && offset < text.length &&
                CFStringIsSurrogateHighCharacter(text.character(at: offset - 1)) &&
                CFStringIsSurrogateLowCharacter(text.character(at: offset)) { return nil }
            previous = offset
        }
        self.attributedString = attributedString.copy() as! NSAttributedString
        self.cellUTF16Boundaries = cellUTF16Boundaries
        line = CTLineCreateWithAttributedString(self.attributedString)
        naturalWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        var edges: [iTermMalayalamNativeEdge] = []
        CTLineEnumerateCaretOffsets(line) { x, index, leading, _ in
            if x.isFinite {
                edges.append(iTermMalayalamNativeEdge(x: x, utf16Index: index, leading: leading))
            }
        }
        nativeEdges = edges
        let string = self.attributedString.string
        // Graphemes classify display ambiguity only. Never use them to invent terminal cells.
        clusterBoundaries = Self.graphemeBoundaries(string)
        let lastScalar = string.unicodeScalars.indices.last?.utf16Offset(in: string)
        var resolved: [Int: iTermMalayalamNativeEdge] = [:]
        for index in clusterBoundaries {
            resolved[index] = Self.resolveNativeEdge(atUTF16Index: index, line: line, edges: edges,
                                                     textLength: text.length, lastScalar: lastScalar)
        }
        resolvedEdges = resolved
        var columns: [Int: [NSNumber]] = [:]
        for (column, offset) in cellUTF16Boundaries.enumerated() {
            columns[offset.intValue, default: []].append(NSNumber(value: column))
        }
        logicalColumnsByIndex = columns
        super.init()
    }

    private static func graphemeBoundaries(_ text: String) -> [Int] {
        text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
    }

    /// Outline-only source ranges do not receive a filled-selection foreground.
    @objc(wholeSelectedColumnsForText:cellUTF16Boundaries:selectedColumns:)
    static func wholeSelectedColumns(forText text: String, cellUTF16Boundaries: [NSNumber],
                                     selectedColumns: IndexSet) -> IndexSet {
        let edges = Set(graphemeBoundaries(text))
        let count = cellUTF16Boundaries.count - 1
        var result = IndexSet()
        for range in selectedColumns.rangeView {
            guard range.lowerBound >= 0, range.upperBound <= count,
                  edges.contains(cellUTF16Boundaries[range.lowerBound].intValue),
                  edges.contains(cellUTF16Boundaries[range.upperBound].intValue) else { continue }
            result.insert(integersIn: range)
        }
        return result
    }

    @objc func projection(atColumn column: Int) -> iTermMalayalamCellProjection? {
        guard cellUTF16Boundaries.indices.contains(column) else { return nil }
        let index = cellUTF16Boundaries[column].intValue
        let anchor = clusterBoundaries.last(where: { $0 <= index }) ?? 0
        let edge = resolvedEdges[anchor]
        let kind: iTermMalayalamCaretKind = edge == nil ? .unresolved :
            (anchor == index ? .nativeEdge : .provisionalClusterStart)
        return iTermMalayalamCellProjection(column: column, index: index, anchor: anchor,
                                           kind: kind, edge: edge)
    }

    /// Ties choose the earlier source boundary. Duplicate cell boundaries stay explicit.
    @objc func hitTest(nativeX: CGFloat) -> iTermMalayalamRowHit? {
        guard nativeX.isFinite else { return nil }
        var bestIndex: Int?
        var bestEdge: iTermMalayalamNativeEdge?
        for index in clusterBoundaries {
            guard let edge = resolvedEdges[index] else { continue }
            if let previous = bestEdge, abs(previous.x - nativeX) <= abs(edge.x - nativeX) {
                continue
            }
            bestIndex = index
            bestEdge = edge
        }
        guard let index = bestIndex, let edge = bestEdge else { return nil }
        return iTermMalayalamRowHit(index: index, columns: logicalColumnsByIndex[index] ?? [], edge: edge)
    }

    /// Source selection is never expanded to make its display endpoints convenient.
    @objc func selection(forColumns columns: NSRange) -> iTermMalayalamRowSelection? {
        let count = cellUTF16Boundaries.count - 1
        guard columns.location >= 0, columns.length >= 0,
              columns.location <= count, columns.length <= count - columns.location else { return nil }
        let start = cellUTF16Boundaries[columns.location].intValue
        let end = cellUTF16Boundaries[columns.location + columns.length].intValue
        let range = NSRange(location: start, length: end - start)
        return iTermMalayalamRowSelection(columns: columns, utf16Range: range,
                                         text: (attributedString.string as NSString).substring(with: range),
                                         startsInside: !clusterBoundaries.contains(start),
                                         endsInside: !clusterBoundaries.contains(end))
    }

    private static func resolveNativeEdge(atUTF16Index index: Int, line: CTLine,
                                          edges: [iTermMalayalamNativeEdge], textLength: Int,
                                          lastScalar: Int?) -> iTermMalayalamNativeEdge? {
        var secondary: CGFloat = 0
        let primary = CTLineGetOffsetForStringIndex(line, index, &secondary)
        let candidates = edges.filter { edge in
            let representsBoundary = index == textLength
                ? (!edge.leading && edge.utf16Index == lastScalar)
                : (edge.leading && edge.utf16Index == index)
            return representsBoundary && (abs(edge.x - primary) < 0.000001 ||
                                           abs(edge.x - secondary) < 0.000001)
        }
        guard let first = candidates.first,
              candidates.allSatisfy({ abs($0.x - first.x) < 0.000001 }) else { return nil }
        return first
    }

    /// Stateless viewport projection; does not alter text, logical cells or client wrapping.
    @objc static func panOffset(naturalWidth: CGFloat, viewportWidth: CGFloat,
                                caretX: CGFloat, previousOffset: CGFloat) -> CGFloat {
        guard naturalWidth.isFinite, viewportWidth.isFinite, caretX.isFinite,
              previousOffset.isFinite, naturalWidth >= 0, viewportWidth > 0 else { return 0 }
        let limit = max(0, naturalWidth - viewportWidth)
        let caret = min(naturalWidth, max(0, caretX))
        let previous = min(limit, max(0, previousOffset))
        return min(limit, max(0, min(caret, max(previous, caret - viewportWidth))))
    }
}
