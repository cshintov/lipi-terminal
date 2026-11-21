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

/// A piece of an anchored row. `rawStart...rawEnd` is its x range in the one shaped line; it is drawn
/// at `origin`, stretched horizontally by `scale`.
@objcMembers final class iTermMalayalamAnchoredSegment: NSObject {
    let utf16Range: NSRange
    let rawStart: CGFloat
    let rawEnd: CGFloat
    let origin: CGFloat
    let scale: CGFloat
    let isAnchor: Bool

    init(range: NSRange, rawStart: CGFloat, rawEnd: CGFloat, origin: CGFloat, scale: CGFloat, isAnchor: Bool) {
        utf16Range = range
        self.rawStart = rawStart
        self.rawEnd = rawEnd
        self.origin = origin
        self.scale = scale
        self.isAnchor = isAnchor
    }

    func x(forRaw raw: CGFloat) -> CGFloat { origin + scale * (raw - rawStart) }
    var drawnEnd: CGFloat { x(forRaw: rawEnd) }
}

/// "Natural text, anchored columns": a row with structural border cells keeps its natural shaping, but each
/// border cell sits at its true column x and the text after it starts at its own column x. Text between two
/// borders is condensed just enough to fit the cells it owns; narrower text keeps its natural width.
@objcMembers final class iTermMalayalamAnchoredGeometry: NSObject {
    let segments: [iTermMalayalamAnchoredSegment]
    let extent: CGFloat

    /// The single definition of a structural anchor: a cell holding one vertical or junction box-drawing
    /// character, so U+2500...U+257F without the pure horizontals.
    static func isAnchor(cell: String) -> Bool {
        let scalars = cell.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, (0x2500...0x257f).contains(scalar.value) else { return false }
        return ![0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254c, 0x254d, 0x2550,
                 0x2574, 0x2576, 0x2578, 0x257a, 0x257c, 0x257e].contains(scalar.value)
    }

    /// Nil when the row has no anchor cell or `cellWidth` is not positive.
    init?(line: CTLine, text: NSString, boundaries: [NSNumber], cellWidth: CGFloat) {
        guard cellWidth > 0, cellWidth.isFinite, boundaries.count > 1 else { return nil }
        let count = boundaries.count - 1
        func range(_ first: Int, _ end: Int) -> NSRange {
            NSRange(location: boundaries[first].intValue, length: boundaries[end].intValue - boundaries[first].intValue)
        }
        let anchors = (0..<count).filter { column in
            let cell = range(column, column + 1)
            return cell.length > 0 && iTermMalayalamAnchoredGeometry.isAnchor(cell: text.substring(with: cell))
        }
        guard !anchors.isEmpty else { return nil }
        var pieces: [iTermMalayalamAnchoredSegment] = []
        func add(_ first: Int, _ end: Int, anchor: Bool) {
            let source = range(first, end)
            guard source.length > 0 else { return }
            let start = CTLineGetOffsetForStringIndex(line, source.location, nil)
            let finish = CTLineGetOffsetForStringIndex(line, NSMaxRange(source), nil)
            let natural = finish - start
            // Text only condenses; an anchor fills exactly its own cell.
            let span = CGFloat(end - first) * cellWidth
            let scale = natural > 0 && (anchor || natural > span) ? span / natural : 1
            pieces.append(iTermMalayalamAnchoredSegment(range: source, rawStart: start, rawEnd: finish,
                origin: CGFloat(first) * cellWidth, scale: scale, isAnchor: anchor))
        }
        var next = 0
        for column in anchors {
            add(next, column, anchor: false)
            add(column, column + 1, anchor: true)
            next = column + 1
        }
        add(next, count, anchor: false)
        segments = pieces
        extent = pieces.map(\.drawnEnd).max() ?? 0
        super.init()
    }

    func segment(containingUTF16 index: Int) -> iTermMalayalamAnchoredSegment? {
        segments.first { NSLocationInRange(index, $0.utf16Range) }
    }

    /// A native edge belongs to the character it describes. A boundary shared by a text segment's end and the
    /// next anchor's start therefore has two edges: the text's own end and the anchor's column x.
    func mapped(_ edge: iTermMalayalamNativeEdge) -> iTermMalayalamNativeEdge {
        guard let piece = segment(containingUTF16: edge.utf16Index) else { return edge }
        return iTermMalayalamNativeEdge(x: piece.x(forRaw: edge.x), utf16Index: edge.utf16Index, leading: edge.leading)
    }
}

/// Natural row geometry. Terminal cell ownership is supplied by the caller.
@objc(iTermMalayalamRowLayout)
final class iTermMalayalamRowLayout: NSObject {
    @objc let attributedString: NSAttributedString
    @objc let cellUTF16Boundaries: [NSNumber]
    @objc let line: CTLine
    @objc let naturalWidth: CGFloat
    /// Set for rows with structural border cells when the caller supplied a cell width.
    @objc let anchoredGeometry: iTermMalayalamAnchoredGeometry?
    @objc let anchorCellWidth: CGFloat
    /// Uncolored geometry validated against this immutable painted layout.
    @objc let selectionBaseline: iTermMalayalamRowLayout?
    let trailingPlainSpaceStart: Int
    @objc let nativeEdges: [iTermMalayalamNativeEdge]
    private let clusterBoundaries: [Int]
    private let resolvedEdges: [Int: iTermMalayalamNativeEdge]
    private let logicalColumnsByIndex: [Int: [NSNumber]]
    private let firstBoundaryByExactX: [CGFloat: Int]

    @objc convenience init?(attributedString: NSAttributedString, cellUTF16Boundaries: [NSNumber]) {
        self.init(attributedString: attributedString, cellUTF16Boundaries: cellUTF16Boundaries, cellWidth: 0)
    }

    /// A positive `cellWidth` anchors structural border cells at their true columns.
    @objc convenience init?(attributedString: NSAttributedString, cellUTF16Boundaries: [NSNumber], cellWidth: CGFloat) {
        self.init(attributedString: attributedString, cellUTF16Boundaries: cellUTF16Boundaries,
                  cellWidth: cellWidth, selectionBaseline: nil)
    }

    @objc init?(attributedString: NSAttributedString, cellUTF16Boundaries: [NSNumber], cellWidth: CGFloat,
                selectionBaseline: iTermMalayalamRowLayout?) {
        guard selectionBaseline?.selectionBaseline == nil else { return nil }
        self.selectionBaseline = selectionBaseline
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
        anchorCellWidth = cellWidth
        let anchored = iTermMalayalamAnchoredGeometry(line: line, text: text, boundaries: cellUTF16Boundaries,
                                                      cellWidth: cellWidth)
        anchoredGeometry = anchored
        naturalWidth = anchored?.extent ?? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var padding = text.length
        let underline = NSAttributedString.Key("iTermMalayalamUnderlineAttribute")
        while padding > 0 && text.character(at: padding - 1) == 0x20 {
            if (self.attributedString.attribute(underline, at: padding - 1, effectiveRange: nil) as? NSNumber)?.boolValue == true { break }
            padding -= 1
        }
        // A new background segment within padding stays visible flow; uniform fills still cover the viewport.
        let backgrounds = text.length > 0 ? (self.attributedString.attribute(NSAttributedString.Key("iTermMalayalamSourceBackgroundsAttribute"),
            at: 0, effectiveRange: nil) as? [[NSNumber]] ?? []) : []
        if backgrounds.contains(where: { span in
            guard span.count == 6 else { return true }
            let column = span[0].intValue
            guard column > 0 && column < cellUTF16Boundaries.count else { return false }
            let offset = cellUTF16Boundaries[column].intValue
            return offset >= padding && offset <= text.length
        }) { padding = text.length }
        trailingPlainSpaceStart = padding
        var edges: [iTermMalayalamNativeEdge] = []
        CTLineEnumerateCaretOffsets(line) { x, index, leading, _ in
            if x.isFinite {
                edges.append(iTermMalayalamNativeEdge(x: x, utf16Index: index, leading: leading))
            }
        }
        let string = self.attributedString.string
        // Display spans may contain several graphemes. They never change terminal cells.
        let graphemes = Self.graphemeBoundaries(string)
        var resolved: [Int: iTermMalayalamNativeEdge] = [:]
        for index in graphemes {
            resolved[index] = Self.resolveNativeEdge(atUTF16Index: index, line: line, edges: edges,
                                                     textLength: text.length)
        }
        clusterBoundaries = Self.displayBoundaries(graphemes, resolved: resolved, edges: edges)
        // Cluster decisions use the shaped line; every reported x then follows the anchored columns.
        if let anchored {
            edges = edges.map(anchored.mapped)
            resolved = resolved.mapValues(anchored.mapped)
        }
        nativeEdges = edges
        resolvedEdges = resolved
        var exactBoundaries: [CGFloat: Int] = [:]
        for index in clusterBoundaries {
            if let edge = resolved[index], exactBoundaries[edge.x] == nil {
                // Keep the first source boundary when several native edges share an x.
                exactBoundaries[edge.x] = index
            }
        }
        firstBoundaryByExactX = exactBoundaries
        var columns: [Int: [NSNumber]] = [:]
        for (column, offset) in cellUTF16Boundaries.enumerated() {
            columns[offset.intValue, default: []].append(NSNumber(value: column))
        }
        logicalColumnsByIndex = columns
        super.init()
        if let selectionBaseline, !hasEquivalentGeometry(to: selectionBaseline) { return nil }
    }

    private static func graphemeBoundaries(_ text: String) -> [Int] {
        text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
    }

    private static func displayBoundaries(_ graphemes: [Int],
                                          resolved: [Int: iTermMalayalamNativeEdge],
                                          edges: [iTermMalayalamNativeEdge]) -> [Int] {
        var interior = Set<Int>()
        var previous: Int?
        for (position, end) in graphemes.enumerated() where resolved[end] != nil {
            defer { previous = position }
            guard let first = previous, position > first + 1,
                  let left = resolved[graphemes[first]], let right = resolved[end],
                  left.leading, left.x < right.x else { continue }
            let start = graphemes[first]
            // Require both actual sides of this span, not an offset that snapped to a neighbour.
            let leading = edges.filter { $0.leading && $0.utf16Index == start }
            let trailing = edges.filter { !$0.leading && $0.utf16Index == end - 1 }
            guard !leading.isEmpty, !trailing.isEmpty,
                  leading.allSatisfy({ abs($0.x - left.x) < 0.000001 }),
                  trailing.allSatisfy({ abs($0.x - right.x) < 0.000001 }),
                  !edges.contains(where: { edge in
                      // A trailing callback names the last UTF-16 unit, not a new leading stop.
                      // This conversion only vetoes coarsening; it never manufactures an edge.
                      let boundary = edge.utf16Index + (edge.leading ? 0 : 1)
                      return boundary > start && boundary < end
                  }) else { continue }
            interior.formUnion(graphemes[(first + 1)..<position])
        }
        return graphemes.filter { !interior.contains($0) }
    }

    /// Geometry only. Source selection and copied text retain their original exact range.
    @objc(displayEnclosureForUTF16Range:)
    func displayEnclosure(forUTF16Range range: NSRange) -> NSRange {
        let length = attributedString.length
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else { return NSRange(location: NSNotFound, length: 0) }
        guard range.length > 0 else { return range }
        guard let start = clusterBoundaries.last(where: { $0 <= range.location }),
              let end = clusterBoundaries.first(where: { $0 >= NSMaxRange(range) }),
              resolvedEdges[start] != nil, resolvedEdges[end] != nil else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    /// Outline-only source ranges do not receive a filled-selection foreground.
    @objc(wholeSelectedColumns:)
    func wholeSelectedColumns(_ selectedColumns: IndexSet) -> IndexSet {
        guard !selectedColumns.isEmpty else { return [] }
        let edges = Set(clusterBoundaries.filter { resolvedEdges[$0] != nil })
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
        hitTest(nativeX: nativeX, reportingASCII: false)
    }

    @objc(hitTestWithNativeX:reportingASCII:)
    func hitTest(nativeX: CGFloat, reportingASCII: Bool) -> iTermMalayalamRowHit? {
        guard nativeX.isFinite else { return nil }
        if reportingASCII {
            let text = attributedString.string as NSString
            for index in clusterBoundaries where index < text.length {
                guard (0x20...0x7e).contains(Int(text.character(at: index))),
                      let leading = resolvedEdges[index], let trailing = resolvedEdges[index + 1],
                      leading.x < trailing.x, nativeX >= leading.x, nativeX < trailing.x else { continue }
                let columns = (logicalColumnsByIndex[index] ?? []).filter { column in
                    let next = column.intValue + 1
                    return next < cellUTF16Boundaries.count && cellUTF16Boundaries[next].intValue == index + 1
                }
                guard !columns.isEmpty else { continue }
                // Reporting owns the ASCII cell interval; selection still chooses the nearest caret.
                return iTermMalayalamRowHit(index: index, columns: columns, edge: leading)
            }
        }
        if let index = firstBoundaryByExactX[nativeX], let edge = resolvedEdges[index] {
            return iTermMalayalamRowHit(index: index, columns: logicalColumnsByIndex[index] ?? [], edge: edge)
        }
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
                                         startsInside: !clusterBoundaries.contains(start) || resolvedEdges[start] == nil,
                                         endsInside: !clusterBoundaries.contains(end) || resolvedEdges[end] == nil)
    }

    /// Foreground changes may split runs, but must not change the shaped line or its caret spans.
    @objc(hasEquivalentGeometryTo:)
    func hasEquivalentGeometry(to other: iTermMalayalamRowLayout) -> Bool {
        let tolerance: CGFloat = 0.000001
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < tolerance }
        guard attributedString.string.utf16.elementsEqual(other.attributedString.string.utf16),
              cellUTF16Boundaries == other.cellUTF16Boundaries,
              clusterBoundaries == other.clusterBoundaries,
              close(naturalWidth, other.naturalWidth) else { return false }
        guard resolvedEdges.count == other.resolvedEdges.count,
              resolvedEdges.allSatisfy({ index, edge in
                  guard let otherEdge = other.resolvedEdges[index] else { return false }
                  return edge.utf16Index == otherEdge.utf16Index && edge.leading == otherEdge.leading &&
                      close(edge.x, otherEdge.x)
              }) else { return false }
        func normalizedEdges(_ layout: iTermMalayalamRowLayout) -> [iTermMalayalamNativeEdge] {
            layout.nativeEdges.sorted {
                if $0.utf16Index != $1.utf16Index { return $0.utf16Index < $1.utf16Index }
                if $0.leading != $1.leading { return $0.leading }
                return $0.x < $1.x
            }.reduce(into: []) { result, edge in
                if let last = result.last, last.utf16Index == edge.utf16Index,
                   last.leading == edge.leading, close(last.x, edge.x) { return }
                result.append(edge)
            }
        }
        let aEdges = normalizedEdges(self), bEdges = normalizedEdges(other)
        guard aEdges.count == bEdges.count,
              zip(aEdges, bEdges).allSatisfy({ a, b in
                  a.utf16Index == b.utf16Index && a.leading == b.leading && close(a.x, b.x)
              }) else { return false }
        typealias Glyph = (font: AnyObject, glyph: CGGlyph, index: Int, position: CGPoint,
                           advance: CGSize, matrix: CGAffineTransform, rightToLeft: Bool)
        func glyphs(_ line: CTLine) -> [Glyph]? {
            var result: [Glyph] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let font = attributes[kCTFontAttributeName] else { return nil }
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                let range = CFRange(location: 0, length: 0)
                CTRunGetGlyphs(run, range, &glyphs)
                CTRunGetStringIndices(run, range, &indices)
                CTRunGetPositions(run, range, &positions)
                CTRunGetAdvances(run, range, &advances)
                let matrix = CTRunGetTextMatrix(run)
                let rightToLeft = CTRunGetStatus(run).contains(.rightToLeft)
                for index in 0..<count {
                    result.append((font as AnyObject, glyphs[index], indices[index], positions[index], advances[index],
                                   matrix, rightToLeft))
                }
            }
            return result
        }
        guard let aGlyphs = glyphs(line), let bGlyphs = glyphs(other.line),
              aGlyphs.count == bGlyphs.count else { return false }
        return zip(aGlyphs, bGlyphs).allSatisfy { a, b in
            CFEqual(a.font, b.font) && a.glyph == b.glyph && a.index == b.index &&
                a.rightToLeft == b.rightToLeft &&
                close(a.position.x, b.position.x) && close(a.position.y, b.position.y) &&
                close(a.advance.width, b.advance.width) && close(a.advance.height, b.advance.height) &&
                close(a.matrix.a, b.matrix.a) && close(a.matrix.b, b.matrix.b) &&
                close(a.matrix.c, b.matrix.c) && close(a.matrix.d, b.matrix.d) &&
                close(a.matrix.tx, b.matrix.tx) && close(a.matrix.ty, b.matrix.ty)
        }
    }

    private static func resolveNativeEdge(atUTF16Index index: Int, line: CTLine,
                                          edges: [iTermMalayalamNativeEdge], textLength: Int) -> iTermMalayalamNativeEdge? {
        var secondary: CGFloat = 0
        let primary = CTLineGetOffsetForStringIndex(line, index, &secondary)
        let candidates = edges.filter { edge in
            let representsBoundary = index == textLength
                ? (!edge.leading && edge.utf16Index == textLength - 1)
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

/// One presentation fragment; all columns and UTF-16 ranges still refer to the source row.
@objcMembers final class iTermMalayalamDisplayFragment: NSObject {
    let sourceRow: Int
    let firstColumn: Int
    let endColumn: Int
    let displayRow: Int
    let sourceRange: NSRange
    let layout: iTermMalayalamRowLayout?
    let originX: CGFloat
    let oversizedCluster: Bool
    let retainsTrailingPadding: Bool
    let paragraph: iTermMalayalamProseParagraph?
    let tableRow: iTermMalayalamTableRow?
    let tableCellWidth: CGFloat

    init(row: Int, first: Int, end: Int, display: Int, range: NSRange,
         layout: iTermMalayalamRowLayout?, oversized: Bool = false, retainedPadding: Bool = false,
         paragraph: iTermMalayalamProseParagraph? = nil, indent: CGFloat = 0,
         tableRow: iTermMalayalamTableRow? = nil, tableCellWidth: CGFloat = 0, exactOrigin: Bool = false) {
        sourceRow = row
        firstColumn = first
        endColumn = end
        displayRow = display
        sourceRange = range
        self.layout = layout
        oversizedCluster = oversized
        retainsTrailingPadding = retainedPadding
        self.paragraph = paragraph
        self.tableRow = tableRow; self.tableCellWidth = tableCellWidth
        // Anchored rows start at their true column x, so ink overhang never shifts them.
        let ink = layout.map { $0.anchoredGeometry == nil ? CTLineGetBoundsWithOptions($0.line, .useGlyphPathBounds) : .null } ?? .zero
        originX = indent + (exactOrigin || ink.isNull ? 0 : max(0, -ink.minX))
    }

    func localColumn(_ column: Int, sourceRow: Int) -> NSNumber? {
        let flat = paragraph?.flatColumn(column, sourceRow: sourceRow) ?? (sourceRow == self.sourceRow ? column : -1)
        guard flat >= firstColumn, flat <= endColumn else { return nil }
        return NSNumber(value: flat - firstColumn)
    }

    func sourceCell(forLocalColumn column: Int) -> NSValue {
        if let tableRow, let piece = tableRow.fragments(atDisplayRow: displayRow).first {
            return piece.sourceCell(forLocalColumn: column)
        }
        if let paragraph { return paragraph.sourceCell(forFlatColumn: firstColumn + column) }
        return NSValue(point: NSPoint(x: CGFloat(firstColumn + column), y: CGFloat(sourceRow)))
    }

    func sourceCells(forLocalColumn column: Int) -> [NSValue] {
        let first = sourceCell(forLocalColumn: column)
        guard let paragraph else { return [first] }
        let flat = firstColumn + column
        if flat > 0 && flat < paragraph.rows.count * paragraph.columns && flat % paragraph.columns == 0 {
            return [first, NSValue(point: NSPoint(x: CGFloat(paragraph.columns), y: first.pointValue.y - 1))]
        }
        return [first]
    }

    // Geometry ranges are shared, but onscreen/offscreen selected text colors are not.
    func paintLayout(from source: iTermMalayalamRowLayout) -> iTermMalayalamRowLayout? {
        guard NSMaxRange(sourceRange) <= source.attributedString.length,
              endColumn < source.cellUTF16Boundaries.count else { return nil }
        let attributed = source.attributedString.attributedSubstring(from: sourceRange)
        if let layout, layout.attributedString.isEqual(to: attributed) { return layout }
        let base = sourceRange.location
        let boundaries = source.cellUTF16Boundaries[firstColumn...endColumn].map {
            NSNumber(value: $0.intValue - base)
        }
        return iTermMalayalamRowLayout(attributedString: attributed, cellUTF16Boundaries: boundaries,
                                       cellWidth: layout?.anchorCellWidth ?? 0)
    }
}

/// Document presentation only. It never owns or changes terminal cells.
@objcMembers final class iTermMalayalamDisplayMap: NSObject {
    let sourceRowCount: Int
    /// Source rows before this index are not laid out: each is one plain display row and has no fragment object.
    /// `fragments` and `starts` cover only the source rows from here on; every public row number is absolute.
    let leadingRows: Int
    private(set) var displayRowCount: Int
    private(set) var fragments: [iTermMalayalamDisplayFragment]
    private var starts: [Int]
    private var paragraphRanges: [Int: Range<Int>] = [:]
    /// The guessed client-prose joins were on when the map was built. Soft-wrap joins need no setting.
    private(set) var paragraphFlowEnabled = false
    private var hasSourceRows = false
    private var joinedContinuationRows = Set<Int>()

    /// A row without natural script that was laid out as the continuation of the natural-script row above it.
    @objc func isJoinedContinuationRow(_ row: Int) -> Bool { joinedContinuationRows.contains(row) }
    private var paragraphEols: [NSNumber] = []
    private var paragraphTexts: [String] = []
    private let sourceLayouts: [NSNumber: iTermMalayalamRowLayout]
    private let columns: Int
    private let width: CGFloat
    let proseFacts: [ObjectIdentifier: iTermMalayalamProseFacts]
    private let tableSources: [NSNumber: iTermMalayalamTableSource]
    private let tableRows: [Int: iTermMalayalamTableRow]
    private let tableCellWidth: CGFloat
    let tableNeedsWiderViewport: Bool

    convenience init?(rows: [NSNumber: iTermMalayalamRowLayout], rowCount: Int, columns: Int, width: CGFloat,
                      sourceEols: [NSNumber]?, sourceTexts: [String]?, tableSources: [NSNumber: iTermMalayalamTableSource],
                      cellWidth: CGFloat, leadingRows: Int = 0, continuationRows: Set<Int> = [],
                      previousMap: iTermMalayalamDisplayMap?) {
        guard (sourceEols == nil) == (sourceTexts == nil), leadingRows >= 0, leadingRows < rowCount,
              sourceEols == nil || (sourceEols?.count == rowCount - leadingRows &&
                                    sourceTexts?.count == rowCount - leadingRows) else { return nil }
        // Source arrays describe only the laid-out rows, from `leadingRows` on.
        let sources = sourceEols.flatMap { eols in sourceTexts.map { texts in
            (leadingRows..<rowCount).map { iTermMalayalamProseSourceRow(row: $0, layout: rows[NSNumber(value: $0)],
                eol: eols[$0 - leadingRows].int32Value, rawText: texts[$0 - leadingRows]) }
        }}
        self.init(rows: rows, rowCount: rowCount, columns: columns, width: width, previousMap: previousMap,
                  sourceRows: sources, tableSources: tableSources, cellWidth: cellWidth, leadingRows: leadingRows,
                  continuationRows: continuationRows)
        paragraphEols = sourceEols ?? []; paragraphTexts = sourceTexts ?? []
    }

    func tableRow(forSourceRow row: Int) -> iTermMalayalamTableRow? { tableRows[row] }

    func matchesTableSources(_ sources: [NSNumber: iTermMalayalamTableSource], cellWidth: CGFloat) -> Bool {
        (sources.isEmpty || tableCellWidth == cellWidth) && sources.count == tableSources.count && sources.allSatisfy { key, value in
            guard let old = tableSources[key] else { return false }
            return old.layout === value.layout && old.columns == value.columns && old.horizontal == value.horizontal && old.paddingColumns == value.paddingColumns
        }
    }

    convenience init?(rows: [NSNumber: iTermMalayalamRowLayout], rowCount: Int, columns: Int, width: CGFloat,
                      sourceEols: [NSNumber], sourceTexts: [String], leadingRows: Int = 0,
                      continuationRows: Set<Int> = [], previousMap: iTermMalayalamDisplayMap?) {
        guard leadingRows >= 0, leadingRows < rowCount, sourceEols.count == rowCount - leadingRows,
              sourceTexts.count == rowCount - leadingRows else { return nil }
        let sourceRows = (leadingRows..<rowCount).map {
            iTermMalayalamProseSourceRow(row: $0, layout: rows[NSNumber(value: $0)],
                eol: sourceEols[$0 - leadingRows].int32Value, rawText: sourceTexts[$0 - leadingRows])
        }
        self.init(rows: rows, rowCount: rowCount, columns: columns, width: width,
                  previousMap: previousMap, sourceRows: sourceRows, leadingRows: leadingRows,
                  continuationRows: continuationRows)
        paragraphEols = sourceEols
        paragraphTexts = sourceTexts
    }

    func matchesParagraphRows(_ rows: [NSNumber: iTermMalayalamRowLayout], rowCount: Int, columns: Int,
                              width: CGFloat, sourceEols: [NSNumber], sourceTexts: [String],
                              leadingRows: Int = 0) -> Bool {
        hasSourceRows && paragraphFlowEnabled == iTermAdvancedSettingsModel.malayalamParagraphFlow() &&
            paragraphEols == sourceEols && paragraphTexts == sourceTexts &&
            matches(rows: rows, rowCount: rowCount, columns: columns, width: width, leadingRows: leadingRows)
    }

    func lastSourceRow(atDisplayRow row: Int) -> Int {
        if row < leadingRows { return max(0, row) }
        let fragment = fragments[min(fragments.count - 1, row - leadingRows)]
        return fragment.paragraph?.lastSourceRow ?? fragment.sourceRow
    }

    /// The fragment drawn on a display row. Rows before `leadingRows` get a plain single-row fragment.
    func fragment(atDisplayRow row: Int) -> iTermMalayalamDisplayFragment {
        if row < leadingRows { return plainFragment(row: max(0, row)) }
        return fragments[min(fragments.count - 1, row - leadingRows)]
    }

    private func plainFragment(row: Int) -> iTermMalayalamDisplayFragment {
        iTermMalayalamDisplayFragment(row: row, first: 0, end: columns, display: row,
                                      range: NSRange(location: 0, length: 0), layout: nil)
    }

    @objc(sourceLayoutForRow:)
    func sourceLayout(forRow row: Int) -> iTermMalayalamRowLayout? {
        tableRows[row]?.source.layout ?? sourceLayouts[NSNumber(value: row)]
    }

    @objc(matchesRows:rowCount:columns:width:leadingRows:)
    func matches(rows: [NSNumber: iTermMalayalamRowLayout], rowCount: Int,
                 columns: Int, width: CGFloat, leadingRows: Int = 0) -> Bool {
        rowCount == sourceRowCount && leadingRows == self.leadingRows && columns == self.columns && width == self.width &&
            rows.count == sourceLayouts.count && rows.allSatisfy { key, layout in
                sourceLayouts[key] === layout
            }
    }

    convenience init?(rows: [NSNumber: iTermMalayalamRowLayout], rowCount: Int, columns: Int, width: CGFloat) {
        self.init(rows: rows, rowCount: rowCount, columns: columns, width: width, previousMap: nil)
    }

    convenience init?(rows: [NSNumber: iTermMalayalamRowLayout], rowCount: Int, columns: Int, width: CGFloat,
                      leadingRows: Int = 0, previousMap: iTermMalayalamDisplayMap?) {
        self.init(rows: rows, rowCount: rowCount, columns: columns, width: width, previousMap: previousMap,
                  sourceRows: nil, leadingRows: leadingRows)
    }

    private init?(rows: [NSNumber: iTermMalayalamRowLayout], rowCount: Int, columns: Int, width: CGFloat,
                  previousMap: iTermMalayalamDisplayMap?, sourceRows: [iTermMalayalamProseSourceRow]?,
                  tableSources: [NSNumber: iTermMalayalamTableSource] = [:], cellWidth: CGFloat = 0,
                  leadingRows: Int = 0, continuationRows: Set<Int> = []) {
        guard rowCount > 0, leadingRows >= 0, leadingRows < rowCount, columns > 0, width.isFinite, width > 0 else { return nil }
        let tableRows = iTermMalayalamTableRow.groups(tableSources, width: width, cellWidth: cellWidth)
        // Source layouts are immutable. Reuse geometry, never old document/display coordinates.
        var reusable: [ObjectIdentifier: [iTermMalayalamDisplayFragment]] = [:]
        if let previousMap, previousMap.columns == columns, previousMap.width == width {
            for row in previousMap.leadingRows..<previousMap.sourceRowCount {
                if let source = previousMap.sourceLayout(forRow: row) {
                    let pieces = previousMap.fragments(forSourceRow: row)
                    if pieces.first?.paragraph == nil && pieces.first?.tableRow == nil { reusable[ObjectIdentifier(source)] = pieces }
                }
            }
        }
        var paragraphs: [Int: iTermMalayalamProseParagraph] = [:]
        var currentFacts: [ObjectIdentifier: iTermMalayalamProseFacts] = [:]
        // Guessed client-prose joins are an explicit opt-in. A terminal soft wrap is a fact and always joins.
        let clientProse = iTermAdvancedSettingsModel.malayalamParagraphFlow()
        if let sourceRows {
            // Table rows are laid out as tables, so they end any run of rows to join.
            let sourceRows = sourceRows.map { source -> iTermMalayalamProseSourceRow in
                guard let layout = source.layout, tableRows[source.row] == nil else {
                    return iTermMalayalamProseSourceRow(row: source.row, layout: nil, eol: source.eol, rawText: source.rawText)
                }
                // Only the explicit prose policy needs classification, never fragment or wrap-only layouts.
                guard clientProse else { return source }
                let key = ObjectIdentifier(layout)
                let saved = currentFacts[key] ?? previousMap?.proseFacts[key]
                guard saved != nil || source.indent > 0 else { return source }
                let facts = saved ?? iTermMalayalamProseFacts(layout: layout)
                currentFacts[key] = facts
                var source = source
                source.cachedFacts = facts
                return source
            }
            var previousParagraphs: [iTermMalayalamProseParagraph] = []
            var seen = Set<ObjectIdentifier>()
            for piece in previousMap?.fragments ?? [] {
                if let paragraph = piece.paragraph, seen.insert(ObjectIdentifier(paragraph)).inserted {
                    previousParagraphs.append(paragraph)
                }
            }
            for group in iTermMalayalamProseFlow.groups(sourceRows, columns: columns, width: width,
                clientProse: clientProse, softWraps: true, previousParagraphs: previousParagraphs) {
                if let paragraph = group.paragraph {
                    for source in group.rows { paragraphs[source.row] = paragraph }
                }
            }
        }
        // A continuation row (no natural script of its own) is only laid out as part of a paragraph. Where its
        // paragraph did not form, it stays the plain row it was before.
        var layoutRows = rows
        var joinedContinuations = Set<Int>()
        for row in continuationRows {
            if paragraphs[row] != nil { joinedContinuations.insert(row) }
            else { layoutRows.removeValue(forKey: NSNumber(value: row)) }
        }
        joinedContinuationRows = joinedContinuations
        var result: [iTermMalayalamDisplayFragment] = []
        var rowStarts: [Int] = []
        var ranges: [Int: Range<Int>] = [:]
        for row in leadingRows..<rowCount {
            if let table = tableRows[row] {
                rowStarts.append(result.count); table.displayStart = leadingRows + result.count
                for _ in 0..<table.height {
                    result.append(iTermMalayalamDisplayFragment(row: row, first: 0, end: columns,
                        display: leadingRows + result.count, range: NSRange(location: 0, length: table.source.layout.attributedString.length),
                        layout: nil, oversized: table.oversized, tableRow: table))
                }
                continue
            }
            if let paragraph = paragraphs[row] {
                if row == paragraph.firstSourceRow {
                    let first = result.count
                    rowStarts.append(first)
                    for piece in paragraph.map.fragments {
                        result.append(iTermMalayalamDisplayFragment(row: row, first: piece.firstColumn,
                            end: piece.endColumn, display: leadingRows + result.count, range: piece.sourceRange, layout: piece.layout,
                            oversized: piece.oversizedCluster, paragraph: paragraph, indent: paragraph.indentWidth))
                    }
                    for source in paragraph.rows { ranges[source.row] = first..<result.count }
                } else {
                    let base = ranges[row]!.lowerBound
                    let local = paragraph.projection(iTermMalayalamProseCell(row: row, column: 0))?.fragment.displayRow ?? 0
                    rowStarts.append(base + local)
                }
                continue
            }
            rowStarts.append(result.count)
            guard let source = layoutRows[NSNumber(value: row)] else {
                result.append(iTermMalayalamDisplayFragment(row: row, first: 0, end: columns,
                    display: leadingRows + result.count, range: NSRange(location: 0, length: 0), layout: nil))
                continue
            }
            if let pieces = reusable[ObjectIdentifier(source)] {
                for piece in pieces {
                    result.append(iTermMalayalamDisplayFragment(row: row, first: piece.firstColumn, end: piece.endColumn,
                        display: leadingRows + result.count, range: piece.sourceRange, layout: piece.layout,
                        oversized: piece.oversizedCluster, retainedPadding: piece.retainsTrailingPadding))
                }
                continue
            }
            let length = source.attributedString.length
            if source.anchoredGeometry != nil {
                // Anchored text already fits between its borders, so the row never wraps.
                result.append(iTermMalayalamDisplayFragment(row: row, first: 0, end: source.cellUTF16Boundaries.count - 1,
                    display: leadingRows + result.count, range: NSRange(location: 0, length: length), layout: source,
                    retainedPadding: source.trailingPlainSpaceStart < length))
                continue
            }
            let typesetter = CTTypesetterCreateWithAttributedString(source.attributedString)
            let legal = source.cellUTF16Boundaries.enumerated().compactMap { column, offset -> Int? in
                source.projection(atColumn: column)?.kind == .nativeEdge ? offset.intValue : nil
            }.reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } }
            guard legal.first == 0, legal.last == length else { return nil }
            var start = 0
            repeat {
                let next = legal.first(where: { $0 > start }) ?? length
                let suggestion = start + CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                var end = legal.last(where: { $0 > start && $0 <= suggestion }) ?? next
                // Keep exact blank-cell advances on this fragment without manufacturing empty rows.
                if end >= source.trailingPlainSpaceStart { end = length }
                var chosen: iTermMalayalamDisplayFragment?
                while true {
                    guard let firstColumn = source.cellUTF16Boundaries.firstIndex(of: NSNumber(value: start)),
                          let endColumn = end == length ? source.cellUTF16Boundaries.indices.last :
                            source.cellUTF16Boundaries.firstIndex(of: NSNumber(value: end)) else { return nil }
                    let range = NSRange(location: start, length: end - start)
                    let boundaries = source.cellUTF16Boundaries[firstColumn...endColumn].map {
                        NSNumber(value: $0.intValue - start)
                    }
                    guard let piece = iTermMalayalamRowLayout(
                        attributedString: source.attributedString.attributedSubstring(from: range),
                        cellUTF16Boundaries: boundaries) else { return nil }
                    let fragment = iTermMalayalamDisplayFragment(row: row, first: firstColumn, end: endColumn,
                        display: leadingRows + result.count, range: range, layout: piece)
                    let ink = CTLineGetBoundsWithOptions(piece.line, .useGlyphPathBounds)
                    let flowEnd = end == length ? max(0, source.trailingPlainSpaceStart - start) : range.length
                    let advance = flowEnd < range.length ? CTLineGetOffsetForStringIndex(piece.line, flowEnd, nil) : piece.naturalWidth
                    let extent = fragment.originX + max(advance, ink.isNull ? 0 : ink.maxX)
                    if extent <= width || end == next {
                        chosen = iTermMalayalamDisplayFragment(row: row, first: firstColumn, end: endColumn,
                            display: leadingRows + result.count, range: range, layout: piece, oversized: extent > width,
                            retainedPadding: end == length && source.trailingPlainSpaceStart < length)
                        break
                    }
                    let limit = end == length && source.trailingPlainSpaceStart < length ? source.trailingPlainSpaceStart : end
                    end = legal.last(where: { $0 < limit && $0 > start }) ?? next
                }
                guard let chosen else { return nil }
                result.append(chosen)
                start = end
            } while start < length
        }
        proseFacts = currentFacts
        sourceLayouts = rows
        self.tableSources = tableSources; self.tableRows = tableRows; self.tableCellWidth = cellWidth
        tableNeedsWiderViewport = tableRows.values.contains { $0.oversized }
        self.columns = columns
        self.width = width
        sourceRowCount = rowCount
        self.leadingRows = leadingRows
        displayRowCount = leadingRows + result.count
        fragments = result
        starts = rowStarts
        paragraphRanges = ranges
        hasSourceRows = sourceRows != nil
        paragraphFlowEnabled = sourceRows != nil && clientProse
        super.init()
    }

    func firstDisplayRow(forSourceRow row: Int) -> Int {
        if row >= sourceRowCount { return displayRowCount }
        if row < leadingRows { return max(0, row) }
        return leadingRows + starts[row - leadingRows]
    }

    func sourceRow(atDisplayRow row: Int) -> Int {
        if row < leadingRows { return max(0, row) }
        return fragments[min(fragments.count - 1, row - leadingRows)].sourceRow
    }

    func fragments(forSourceRow row: Int) -> [iTermMalayalamDisplayFragment] {
        guard row >= 0, row < sourceRowCount else { return [] }
        if row < leadingRows { return [plainFragment(row: row)] }
        if let range = paragraphRanges[row] { return Array(fragments[range]) }
        let start = starts[row - leadingRows]
        let end = row + 1 < sourceRowCount ? starts[row + 1 - leadingRows] : fragments.count
        return Array(fragments[start..<end])
    }

    // Downstream affinity at a visual break; the final row endpoint stays on its final fragment.
    func fragment(forColumn column: Int, sourceRow row: Int) -> iTermMalayalamDisplayFragment? {
        let pieces = fragments(forSourceRow: row)
        if let table = pieces.first?.tableRow {
            if let cell = table.fragment(forColumn: column) { return cell }
            // The row endpoint includes every wrapped visual row; the prefix keeps upstream affinity.
            return column > table.source.columns.last!.intValue ? pieces.last : pieces.first
        }
        let flat = pieces.first?.paragraph?.flatColumn(column, sourceRow: row) ?? column
        return pieces.first(where: { flat >= $0.firstColumn && flat < $0.endColumn }) ?? pieces.last
    }
}

/// A map snapshot binds derived facts to a strongly retained, immutable source layout.
final class iTermMalayalamProseFacts {
    let layout: iTermMalayalamRowLayout
    let indent: Int
    let usedColumns: Int
    let firstWordCellWidth: Int
    let isPlainProse: Bool
    let background: [NSNumber]?

    init(layout: iTermMalayalamRowLayout) {
        self.layout = layout
        let source = iTermMalayalamProseSourceRow(row: 0, layout: layout, eol: Int32(EOL_HARD))
        indent = source.indent
        usedColumns = source.usedColumns
        firstWordCellWidth = source.firstWordCellWidth
        isPlainProse = source.isPlainProse
        background = source.background
    }
}

/// Source ownership for the explicit client-prose policy.
struct iTermMalayalamProseSourceRow {
    let row: Int
    let layout: iTermMalayalamRowLayout?
    let eol: Int32
    var rawText: String = ""
    var cachedFacts: iTermMalayalamProseFacts? = nil

    var paintedText: String { layout?.attributedString.string ?? rawText.replacingOccurrences(of: "\0", with: " ") }

    private func cellRange(_ column: Int) -> NSRange {
        guard let layout else { return NSRange(location: 0, length: 0) }
        let start = layout.cellUTF16Boundaries[column].intValue
        return NSRange(location: start, length: layout.cellUTF16Boundaries[column + 1].intValue - start)
    }

    private func cellContainsOnlySpaces(_ column: Int) -> Bool {
        guard let layout else { return false }
        let range = cellRange(column)
        let text = layout.attributedString.string as NSString
        // Empty slices alias another cell's edge, not a source space or invented indentation.
        return range.length > 0 && (range.location..<NSMaxRange(range)).allSatisfy { text.character(at: $0) == 0x20 }
    }

    private func cellIsPadding(_ column: Int) -> Bool {
        guard let layout, cellContainsOnlySpaces(column) else { return false }
        var decorated = false
        layout.attributedString.enumerateAttribute(NSAttributedString.Key("iTermMalayalamUnderlineAttribute"),
            in: cellRange(column)) { value, _, _ in
            if (value as? NSNumber)?.boolValue == true { decorated = true }
        }
        return !decorated
    }

    var indent: Int {
        if let cachedFacts, cachedFacts.layout === layout { return cachedFacts.indent }
        guard let layout else { return 0 }
        return (0..<(layout.cellUTF16Boundaries.count - 1)).prefix { cellIsPadding($0) }.count
    }

    var usedColumns: Int {
        if let cachedFacts, cachedFacts.layout === layout { return cachedFacts.usedColumns }
        guard let layout else { return 0 }
        return (0..<(layout.cellUTF16Boundaries.count - 1)).last {
            cellRange($0).length > 0 && !cellIsPadding($0)
        }.map { $0 + 1 } ?? 0
    }

    /// Only a repeated client quote prefix may collapse into the preceding quoted paragraph.
    var quotePrefixColumns: Int? {
        guard let layout else { return nil }
        let first = indent
        let columns = layout.cellUTF16Boundaries.count - 1
        guard first + 1 < columns,
              (layout.attributedString.string as NSString).substring(with: cellRange(first)) == "▎",
              cellContainsOnlySpaces(first + 1) else { return nil }
        var end = first + 2
        while end < columns && cellContainsOnlySpaces(end) { end += 1 }
        return end < usedColumns ? end : nil
    }

    var hasQuotedLeadingIcon: Bool {
        guard let layout, let column = quotePrefixColumns else { return false }
        let cell = (layout.attributedString.string as NSString).substring(with: cellRange(column))
        return cell.unicodeScalars.first?.properties.isEmojiPresentation == true
    }

    private var proseStartColumn: Int {
        guard var column = quotePrefixColumns else { return indent }
        if hasQuotedLeadingIcon {
            column += 1
            while column < usedColumns && (cellRange(column).length == 0 || cellContainsOnlySpaces(column)) {
                column += 1
            }
        }
        return column
    }

    var proseText: String {
        // ASCII code fences have no natural layout, but still delimit quoted prose.
        let text = paintedText
        let body = text.drop(while: { $0 == " " })
        guard body.first == "▎", body.dropFirst().first == " " else { return text }
        return String(body.dropFirst().drop(while: { $0 == " " }))
    }

    var firstWordCellWidth: Int {
        if let cachedFacts, cachedFacts.layout === layout { return cachedFacts.firstWordCellWidth }
        let firstColumn = proseStartColumn
        let endColumn = usedColumns
        guard firstColumn < endColumn else { return 0 }
        for column in firstColumn..<endColumn {
            if cellContainsOnlySpaces(column) { return column - firstColumn }
        }
        return endColumn - firstColumn
    }

    var isPlainProse: Bool {
        if let cachedFacts, cachedFacts.layout === layout { return cachedFacts.isPlainProse }
        guard let layout else { return false }
        let firstColumn = proseStartColumn
        let endColumn = usedColumns
        guard firstColumn < endColumn else { return false }
        let start = layout.cellUTF16Boundaries[firstColumn].intValue
        let text = layout.attributedString.string as NSString
        let first = text.character(at: start)
        // Preserve client headings, list starts, prompts, code/table markers and status rows.
        let malayalamEnabled = iTermAdvancedSettingsModel.malayalamNaturalRows()
        let hindiEnabled = iTermAdvancedSettingsModel.hindiNaturalRows()
        let startsNaturalScript = iTermIsNaturalRowCodePoint(UInt32(first), malayalamEnabled, hindiEnabled)
        let startsLatin = (first >= 0x41 && first <= 0x5a) || (first >= 0x61 && first <= 0x7a)
        guard startsNaturalScript || (startsLatin && layout.attributedString.string.unicodeScalars.contains {
            iTermIsNaturalRowCodePoint($0.value, malayalamEnabled, hindiEnabled)
        }) else { return false }
        var allDecorated = true
        let end = layout.cellUTF16Boundaries[endColumn].intValue
        layout.attributedString.enumerateAttributes(in: NSRange(location: start, length: end - start)) { attrs, range, _ in
            guard text.substring(with: range).rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else { return }
            if (attrs[NSAttributedString.Key("iTermBoldAttribute")] as? NSNumber)?.boolValue != true &&
                (attrs[NSAttributedString.Key("iTermMalayalamUnderlineAttribute")] as? NSNumber)?.boolValue != true {
                allDecorated = false
            }
        }
        return !allDecorated
    }

    var background: [NSNumber]? {
        if let cachedFacts, cachedFacts.layout === layout { return cachedFacts.background }
        guard let layout, layout.attributedString.length > 0,
              let spans = layout.attributedString.attribute(NSAttributedString.Key("iTermMalayalamSourceBackgroundsAttribute"),
                at: 0, effectiveRange: nil) as? [[NSNumber]], spans.count == 1, spans[0].count == 6 else { return nil }
        return Array(spans[0].dropFirst(2))
    }
}

struct iTermMalayalamProseCell: Equatable {
    let row: Int
    let column: Int
}

struct iTermMalayalamProseSpan {
    let sourceRow: Int
    let columns: NSRange
}

/// A presentation paragraph retains every source-cell address, including collapsed client padding.
@objcMembers final class iTermMalayalamProseParagraph: NSObject {
    let rows: [iTermMalayalamProseSourceRow]
    let columns: Int
    let indentWidth: CGFloat
    let layout: iTermMalayalamRowLayout
    let map: iTermMalayalamDisplayMap
    private let viewportWidth: CGFloat
    /// Rows joined only because the terminal soft-wrapped them: no client indent, every cell kept in place.
    let softOnly: Bool

    // Only immutable geometry is shared. Each wrapper below keeps the current source row IDs.
    func matchesGeometryInputs(_ source: [iTermMalayalamProseSourceRow], columns: Int, width: CGFloat,
                               softOnly: Bool = false) -> Bool {
        self.softOnly == softOnly && self.columns == columns && viewportWidth == width && rows.count == source.count &&
            zip(rows, source).allSatisfy { old, current in old.layout === current.layout && old.eol == current.eol }
    }

    init?(rows: [iTermMalayalamProseSourceRow], columns: Int, width: CGFloat,
          previous: iTermMalayalamProseParagraph? = nil, softOnly: Bool = false) {
        guard rows.count > 1, columns > 0, let first = rows.first,
              let firstLayout = first.layout else { return nil }
        let firstIndent = softOnly ? 0 : first.indent
        guard softOnly || firstIndent > 0, let background = first.background,
              rows.allSatisfy({ $0.background == background }) else { return nil }
        self.rows = rows
        self.columns = columns
        viewportWidth = width
        self.softOnly = softOnly
        if let previous, previous.matchesGeometryInputs(rows, columns: columns, width: width, softOnly: softOnly) {
            indentWidth = previous.indentWidth
            layout = previous.layout
            map = previous.map
            super.init()
            return
        }
        let indentIndex = firstLayout.cellUTF16Boundaries[firstIndent].intValue
        let indent = CTLineGetOffsetForStringIndex(firstLayout.line, indentIndex, nil)
        indentWidth = indent
        let text = NSMutableAttributedString(string: "")
        var boundaries: [NSNumber] = [0]
        for (index, row) in rows.enumerated() {
            guard let source = row.layout, source.cellUTF16Boundaries.count == columns + 1 else { return nil }
            let nativeContinuation = index > 0 && rows[index - 1].eol != Int32(EOL_HARD)
            let nextIsNative = index + 1 < rows.count && row.eol != Int32(EOL_HARD)
            let prefixColumns = nativeContinuation || softOnly ? 0 :
                (index == 0 ? row.indent : (row.quotePrefixColumns ?? row.indent))
            let endColumn = nextIsNative ? columns : row.usedColumns
            for column in 0..<columns {
                let start = source.cellUTF16Boundaries[column].intValue
                let end = source.cellUTF16Boundaries[column + 1].intValue
                if column < prefixColumns {
                    // One existing client-indent cell owns the semantic word separator.
                    if index > 0 && column == prefixColumns - 1 {
                        text.append(NSAttributedString(string: " ", attributes: source.attributedString.attributes(at: start, effectiveRange: nil)))
                    }
                } else if column < endColumn {
                    text.append(source.attributedString.attributedSubstring(from: NSRange(location: start, length: end - start)))
                }
                boundaries.append(NSNumber(value: text.length))
            }
        }
        let backgroundKey = NSAttributedString.Key("iTermMalayalamSourceBackgroundsAttribute")
        text.removeAttribute(backgroundKey, range: NSRange(location: 0, length: text.length))
        text.addAttribute(backgroundKey, value: [[NSNumber(value: 0), NSNumber(value: rows.count * columns)] + background],
                          range: NSRange(location: 0, length: text.length))
        guard let combined = iTermMalayalamRowLayout(attributedString: text, cellUTF16Boundaries: boundaries),
              let map = iTermMalayalamDisplayMap(rows: [0: combined], rowCount: 1,
                  columns: rows.count * columns, width: width - indent) else { return nil }
        layout = combined
        self.map = map
        super.init()
    }

    var firstSourceRow: Int { rows[0].row }
    var lastSourceRow: Int { rows[rows.count - 1].row }

    func flatColumn(_ column: Int, sourceRow: Int) -> Int {
        guard let index = rows.firstIndex(where: { $0.row == sourceRow }), column >= 0, column <= columns else { return -1 }
        return index * columns + column
    }

    func sourceCell(forFlatColumn flat: Int) -> NSValue {
        let value = min(rows.count * columns, max(0, flat))
        if value == rows.count * columns { return NSValue(point: NSPoint(x: CGFloat(columns), y: CGFloat(lastSourceRow))) }
        return NSValue(point: NSPoint(x: CGFloat(value % columns), y: CGFloat(rows[value / columns].row)))
    }

    // Paint is reconstructed from current per-source attributes, never a cached selection snapshot.
    func paintLayout(rows current: [NSNumber: iTermMalayalamRowLayout]) -> iTermMalayalamRowLayout? {
        var changed: [(Int, iTermMalayalamRowLayout)] = []
        for (index, row) in rows.enumerated() {
            guard let source = current[NSNumber(value: row.row)],
                  source.attributedString.string == row.layout?.attributedString.string,
                  source.cellUTF16Boundaries.count == columns + 1 else { return nil }
            if source !== row.layout { changed.append((index, source)) }
        }
        if changed.isEmpty { return layout }
        let text = layout.attributedString.mutableCopy() as! NSMutableAttributedString
        let background = NSAttributedString.Key("iTermMalayalamSourceBackgroundsAttribute")
        for (index, source) in changed {
            for column in 0..<columns {
                let flat = index * columns + column
                let start = layout.cellUTF16Boundaries[flat].intValue
                let end = layout.cellUTF16Boundaries[flat + 1].intValue
                if end == start { continue }
                let sourceStart = source.cellUTF16Boundaries[column].intValue
                guard sourceStart < source.attributedString.length else { return nil }
                var attrs = source.attributedString.attributes(at: sourceStart, effectiveRange: nil)
                attrs[background] = layout.attributedString.attribute(background, at: start, effectiveRange: nil)
                text.setAttributes(attrs, range: NSRange(location: start, length: end - start))
            }
        }
        if text.isEqual(to: layout.attributedString) { return layout }
        return iTermMalayalamRowLayout(attributedString: text, cellUTF16Boundaries: layout.cellUTF16Boundaries)
    }

    func selectionRects(columns: NSRange, sourceRow: Int, lineHeight: CGFloat, displayStart: Int) -> [NSValue] {
        selectionRects(iTermMalayalamProseSpan(sourceRow: sourceRow, columns: columns), lineHeight: lineHeight).map {
            NSValue(rect: $0.offsetBy(dx: 0, dy: CGFloat(displayStart) * lineHeight))
        }
    }

    func spans(in fragment: iTermMalayalamDisplayFragment) -> [iTermMalayalamProseSpan] {
        rows.enumerated().compactMap { index, row in
            let start = max(fragment.firstColumn, index * columns)
            let end = min(fragment.endColumn, (index + 1) * columns)
            return start < end ? iTermMalayalamProseSpan(sourceRow: row.row,
                columns: NSRange(location: start - index * columns, length: end - start)) : nil
        }
    }

    func projection(_ cell: iTermMalayalamProseCell) -> (fragment: iTermMalayalamDisplayFragment, caret: iTermMalayalamCellProjection)? {
        guard let index = rows.firstIndex(where: { $0.row == cell.row }), cell.column >= 0, cell.column <= columns,
              let fragment = map.fragment(forColumn: index * columns + cell.column, sourceRow: 0),
              let caret = fragment.layout?.projection(atColumn: index * columns + cell.column - fragment.firstColumn) else { return nil }
        return (fragment, caret)
    }

    func selectionRects(_ span: iTermMalayalamProseSpan, lineHeight: CGFloat) -> [CGRect] {
        guard let row = rows.firstIndex(where: { $0.row == span.sourceRow }),
              span.columns.location >= 0, NSMaxRange(span.columns) <= columns,
              let selected = layout.selection(forColumns: NSRange(location: row * columns + span.columns.location,
                  length: span.columns.length)) else { return [] }
        let range = layout.displayEnclosure(forUTF16Range: selected.utf16Range)
        guard range.location != NSNotFound else { return [] }
        return map.fragments.compactMap { piece in
            let local = NSIntersectionRange(range, piece.sourceRange)
            guard local.length > 0, let geometry = piece.layout,
                  let start = geometry.cellUTF16Boundaries.firstIndex(of: NSNumber(value: local.location - piece.sourceRange.location)),
                  let end = geometry.cellUTF16Boundaries.firstIndex(of: NSNumber(value: NSMaxRange(local) - piece.sourceRange.location)),
                  let left = geometry.projection(atColumn: start)?.nativeEdge,
                  let right = geometry.projection(atColumn: end)?.nativeEdge else { return nil }
            return CGRect(x: indentWidth + piece.originX + min(left.x, right.x), y: CGFloat(piece.displayRow) * lineHeight,
                          width: abs(right.x - left.x), height: lineHeight)
        }
    }

    func hit(x: CGFloat, displayRow: Int) -> [iTermMalayalamProseCell] {
        guard map.fragments.indices.contains(displayRow) else { return [] }
        let piece = map.fragments[displayRow]
        return piece.layout?.hitTest(nativeX: x - indentWidth - piece.originX)?.logicalColumns.flatMap { local in
            let flat = piece.firstColumn + local.intValue
            if flat == rows.count * columns { return [iTermMalayalamProseCell(row: rows.last!.row, column: columns)] }
            var result = [iTermMalayalamProseCell(row: rows[flat / columns].row, column: flat % columns)]
            if flat > 0 && flat % columns == 0 { result.append(iTermMalayalamProseCell(row: rows[flat / columns - 1].row, column: columns)) }
            return result
        } ?? []
    }
}

struct iTermMalayalamProseGroup {
    let rows: [iTermMalayalamProseSourceRow]
    let paragraph: iTermMalayalamProseParagraph?
}

/// Conservative opt-in client prose, never a generic reinterpretation of HARD rows.
enum iTermMalayalamProseFlow {
    /// `clientProse` enables the guessed joins of client-painted rows. `softWraps` joins consecutive rows that the
    /// terminal itself wrapped (SOFT or DWC): that is an explicit continuation, so it needs no indent or guess.
    /// A run is either all guessed joins or all soft wraps, never both, so each keeps its own meaning.
    static func groups(_ rows: [iTermMalayalamProseSourceRow], columns: Int, width: CGFloat,
                       clientProse: Bool = false, softWraps: Bool = false,
                       previousParagraphs: [iTermMalayalamProseParagraph] = []) -> [iTermMalayalamProseGroup] {
        func softJoins(_ previous: iTermMalayalamProseSourceRow, _ next: iTermMalayalamProseSourceRow) -> Bool {
            // A row without a layout (plain ASCII, unlayable, a table) ends the run.
            softWraps && next.row == previous.row + 1 &&
                previous.eol != Int32(EOL_HARD) && previous.layout != nil && next.layout != nil
        }
        func joins(_ first: iTermMalayalamProseSourceRow, _ previous: iTermMalayalamProseSourceRow,
                   _ next: iTermMalayalamProseSourceRow) -> Bool {
            guard clientProse, previous.row + 1 == next.row else { return false }
            let indent = previous.indent
            guard indent > 0, indent == next.indent,
                  previous.quotePrefixColumns == next.quotePrefixColumns,
                  !next.hasQuotedLeadingIcon,
                  previous.isPlainProse, next.isPlainProse,
                  let background = previous.background, background == next.background else { return false }
            // A leading quote icon marks one readaloud paragraph, even when logical cells underestimate wrapping.
            // Unmarked HARD rows still need positive cell-width evidence of client word wrapping.
            return previous.eol != Int32(EOL_HARD) || first.hasQuotedLeadingIcon ||
                columns - previous.usedColumns < 1 + next.firstWordCellWidth
        }
        var runs: [[iTermMalayalamProseSourceRow]] = []
        var softRun: [Bool] = []  // Parallel to runs: the run joined by terminal soft wraps, not by guesses.
        var fence: (marker: Character, length: Int)?
        for row in rows {
            let text = clientProse ? row.proseText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if clientProse, let marker = text.first, marker == "`" || marker == "~" {
                let length = text.prefix { $0 == marker }.count
                if let open = fence {
                    if marker == open.marker && length >= open.length &&
                        text.dropFirst(length).allSatisfy({ $0.isWhitespace }) { fence = nil }
                } else if length >= 3 {
                    fence = (marker, length)
                }
                runs.append([row]); softRun.append(false)
                continue
            }
            if fence != nil { runs.append([row]); softRun.append(false); continue }
            if let previous = runs.last?.last {
                let index = runs.count - 1
                if !softRun[index], joins(runs[index][0], previous, row) {
                    runs[index].append(row)
                    continue
                }
                if (softRun[index] || runs[index].count == 1), softJoins(previous, row) {
                    runs[index].append(row)
                    softRun[index] = true
                    continue
                }
            }
            runs.append([row]); softRun.append(false)
        }
        var reusable: [ObjectIdentifier: [iTermMalayalamProseParagraph]] = [:]
        for paragraph in previousParagraphs {
            if let first = paragraph.rows.first?.layout { reusable[ObjectIdentifier(first), default: []].append(paragraph) }
        }
        return zip(runs, softRun).map { source, soft in
            let firstLayout = source.first?.layout
            let candidates = firstLayout.flatMap { reusable[ObjectIdentifier($0)] } ?? []
            let previous = candidates.first { $0.matchesGeometryInputs(source, columns: columns, width: width, softOnly: soft) }
            return iTermMalayalamProseGroup(rows: source,
                paragraph: iTermMalayalamProseParagraph(rows: source, columns: columns, width: width,
                                                         previous: previous, softOnly: soft))
        }
    }
}

/// Canonical prepared input only. A candidate does not opt an ASCII row into natural drawing.
@objcMembers final class iTermMalayalamTableSource: NSObject {
    let layout: iTermMalayalamRowLayout
    let columns: [NSNumber]
    let horizontal: Bool
    let cells: [String]
    let hasNaturalScript: Bool
    let paddingColumns: IndexSet

    init?(layout: iTermMalayalamRowLayout, paddingColumns: IndexSet) {
        let text = layout.attributedString.string as NSString
        let cells = zip(layout.cellUTF16Boundaries, layout.cellUTF16Boundaries.dropFirst()).map { pair in
            text.substring(with: NSRange(location: pair.0.intValue, length: pair.1.intValue - pair.0.intValue))
        }
        guard let first = cells.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let last = cells.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), first < last else { return nil }
        let horizontal = cells[first] != "│"
        let joints: Set<String> = horizontal ? ["┌", "┬", "┐", "├", "┼", "┤", "└", "┴", "┘"] : ["│"]
        let columns = (first...last).filter { joints.contains(cells[$0]) }
        guard columns.count >= 3, columns.first == first, columns.last == last,
              horizontal ? ["┌", "├", "└"].contains(cells[first]) : cells[last] == "│" else { return nil }
        if horizontal && !(first...last).allSatisfy({ joints.contains(cells[$0]) || cells[$0] == "─" }) { return nil }
        self.layout = layout; self.columns = columns.map { NSNumber(value: $0) }; self.horizontal = horizontal
        self.cells = cells; self.paddingColumns = paddingColumns
        let malayalamEnabled = iTermAdvancedSettingsModel.malayalamNaturalRows()
        let hindiEnabled = iTermAdvancedSettingsModel.hindiNaturalRows()
        hasNaturalScript = (text as String).unicodeScalars.contains {
            iTermIsNaturalRowCodePoint($0.value, malayalamEnabled, hindiEnabled)
        }
    }

    func content(_ index: Int, preserveDecoration: Bool = true) -> (first: Int, end: Int, layout: iTermMalayalamRowLayout)? {
        var first = columns[index].intValue + 1, end = columns[index + 1].intValue
        func padding(_ column: Int) -> Bool {
            paddingColumns.contains(column) || (!preserveDecoration && cells[column] == " ")
        }
        while first < end && padding(first) { first += 1 }
        while end > first && padding(end - 1) { end -= 1 }
        guard first < end else { return nil }
        let start = layout.cellUTF16Boundaries[first].intValue
        let finish = layout.cellUTF16Boundaries[end].intValue
        let boundaries = layout.cellUTF16Boundaries[first...end].map { NSNumber(value: $0.intValue - start) }
        guard let piece = iTermMalayalamRowLayout(attributedString: layout.attributedString.attributedSubstring(
            from: NSRange(location: start, length: finish - start)), cellUTF16Boundaries: boundaries) else { return nil }
        return (first, end, piece)
    }
}

/// One source row, potentially several visual rows, with side-by-side native cell fragments.
@objcMembers final class iTermMalayalamTableRow: NSObject {
    let source: iTermMalayalamTableSource
    let sourceRow: Int
    let anchors: [NSNumber]
    let cellWidth: CGFloat
    let height: Int
    let oversized: Bool
    var displayStart = 0
    private let pieces: [[iTermMalayalamDisplayFragment]]

    init?(source: iTermMalayalamTableSource, row: Int, anchors: [CGFloat], cellWidth: CGFloat, tooNarrow: Bool = false) {
        self.source = source; sourceRow = row; self.anchors = anchors.map { NSNumber(value: Double($0)) }
        self.cellWidth = cellWidth
        var cells: [[iTermMalayalamDisplayFragment]] = [], height = 1, oversized = tooNarrow
        for index in 0..<(anchors.count - 1) {
            guard !source.horizontal, let content = source.content(index) else { cells.append([]); continue }
            let leadingInset = content.first > source.columns[index].intValue + 1 ? cellWidth : 0
            let trailingInset = content.end < source.columns[index + 1].intValue ? cellWidth : 0
            let width = max(1, anchors[index + 1] - anchors[index] - cellWidth - leadingInset - trailingInset)
            guard let map = iTermMalayalamDisplayMap(rows: [0: content.layout], rowCount: 1,
                columns: content.end - content.first, width: width) else { return nil }
            height = max(height, map.displayRowCount)
            let offset = source.layout.cellUTF16Boundaries[content.first].intValue
            cells.append(map.fragments.map { piece in
                oversized = oversized || piece.oversizedCluster
                return iTermMalayalamDisplayFragment(row: row, first: content.first + piece.firstColumn,
                    end: content.first + piece.endColumn, display: piece.displayRow,
                    range: NSRange(location: offset + piece.sourceRange.location, length: piece.sourceRange.length),
                    layout: piece.layout, oversized: piece.oversizedCluster,
                    indent: anchors[index] + cellWidth + leadingInset, tableCellWidth: width)
            })
        }
        pieces = cells; self.height = height; self.oversized = oversized
    }

    func fragments(atDisplayRow display: Int) -> [iTermMalayalamDisplayFragment] {
        pieces.flatMap { $0 }.filter { $0.displayRow + displayStart == display }.map { absolute($0) }
    }

    private func absolute(_ piece: iTermMalayalamDisplayFragment) -> iTermMalayalamDisplayFragment {
        iTermMalayalamDisplayFragment(row: sourceRow, first: piece.firstColumn, end: piece.endColumn,
            display: piece.displayRow + displayStart, range: piece.sourceRange, layout: piece.layout,
            oversized: piece.oversizedCluster, indent: piece.originX, tableCellWidth: piece.tableCellWidth,
            exactOrigin: true)
    }

    func fragment(forColumn column: Int) -> iTermMalayalamDisplayFragment? {
        guard let index = (0..<pieces.count).first(where: {
            column > source.columns[$0].intValue && column < source.columns[$0 + 1].intValue
        }), !pieces[index].isEmpty else { return nil }
        let candidates = pieces[index]
        return absolute(candidates.first(where: { column >= $0.firstColumn && column < $0.endColumn }) ??
                        (column < candidates[0].firstColumn ? candidates[0] : candidates.last!))
    }

    func x(forColumn column: Int) -> NSNumber? {
        guard source.layout.cellUTF16Boundaries.indices.contains(column) else { return nil }
        if let index = source.columns.firstIndex(of: NSNumber(value: column)) { return anchors[index] }
        if let index = (0..<pieces.count).first(where: { column > source.columns[$0].intValue && column < source.columns[$0 + 1].intValue }),
           let first = pieces[index].first, let last = pieces[index].last {
            let bandStart = source.columns[index].intValue + 1
            if column < first.firstColumn {
                let fraction = CGFloat(column - bandStart) / CGFloat(max(1, first.firstColumn - bandStart))
                return NSNumber(value: anchors[index].doubleValue + Double(cellWidth * (1 + fraction)))
            }
            if column >= last.endColumn {
                let end = last.originX + (last.layout?.naturalWidth ?? 0)
                let fraction = CGFloat(column - last.endColumn) / CGFloat(max(1, source.columns[index + 1].intValue - last.endColumn))
                return NSNumber(value: Double(end) + Double(fraction) * (anchors[index + 1].doubleValue - Double(end)))
            }
        }
        if let piece = fragment(forColumn: column), let layout = piece.layout {
            let local = max(0, min(column - piece.firstColumn, piece.endColumn - piece.firstColumn))
            if let edge = layout.projection(atColumn: local)?.nativeEdge {
                return NSNumber(value: Double(piece.originX + edge.x))
            }
            return nil
        }
        // Structural border cells and outside-table blanks retain explicit logical ownership.
        if column <= source.columns[0].intValue { return NSNumber(value: Double(CGFloat(column) * cellWidth)) }
        for index in 0..<(anchors.count - 1) {
            let first = source.columns[index].intValue, end = source.columns[index + 1].intValue
            if column < end {
                let start = anchors[index].doubleValue + Double(cellWidth)
                let fraction = CGFloat(column - first - 1) / CGFloat(max(1, end - first - 1))
                return NSNumber(value: start + Double(fraction) * (anchors[index + 1].doubleValue - start))
            }
        }
        return NSNumber(value: anchors.last!.doubleValue + Double(cellWidth))
    }

    func hit(x: CGFloat, displayRow: Int, preferredColumn: Int) -> NSValue? {
        hit(x: x, displayRow: displayRow, preferredColumn: preferredColumn, reportingASCII: false)
    }

    @objc(hitWithX:displayRow:preferredColumn:reportingASCII:)
    func hit(x: CGFloat, displayRow: Int, preferredColumn: Int, reportingASCII: Bool) -> NSValue? {
        for piece in fragments(atDisplayRow: displayRow) where x >= piece.originX && x <= piece.originX + min(piece.tableCellWidth, piece.layout?.naturalWidth ?? 0) {
            if let hit = piece.layout?.hitTest(nativeX: x - piece.originX, reportingASCII: reportingASCII), let column = hit.logicalColumns.first {
                let preferred = NSNumber(value: preferredColumn - piece.firstColumn)
                let local = hit.logicalColumns.contains(preferred) ? preferred.intValue : column.intValue
                return NSValue(point: NSPoint(x: CGFloat(piece.firstColumn + local), y: CGFloat(sourceRow)))
            }
        }
        let candidates = 0..<source.layout.cellUTF16Boundaries.count
        let column = candidates.min { abs((self.x(forColumn: $0)?.doubleValue ?? .infinity) - Double(x)) <
                                      abs((self.x(forColumn: $1)?.doubleValue ?? .infinity) - Double(x)) }
        return column.map {
            let best = self.x(forColumn: $0)?.doubleValue
            let preferred = self.x(forColumn: preferredColumn)?.doubleValue
            let chosen = preferredColumn >= 0 && best == preferred ? preferredColumn : $0
            return NSValue(point: NSPoint(x: CGFloat(chosen), y: CGFloat(sourceRow)))
        }
    }

    func clipRect(forColumn column: Int, displayRow: Int, lineHeight: CGFloat) -> NSValue? {
        guard let index = (0..<(anchors.count - 1)).first(where: {
            column > source.columns[$0].intValue && column < source.columns[$0 + 1].intValue
        }) else { return nil }
        let left = CGFloat(anchors[index].doubleValue) + cellWidth
        return NSValue(rect: NSRect(x: left, y: CGFloat(displayRow) * lineHeight,
            width: max(0, CGFloat(anchors[index + 1].doubleValue) - left), height: lineHeight))
    }

    func rects(columns: NSRange, lineHeight: CGFloat, expandClusters: Bool) -> [NSValue] {
        var result: [NSValue] = []
        let indent = NSIntersectionRange(columns, NSRange(location: 0, length: source.columns[0].intValue))
        if indent.length > 0, let left = x(forColumn: indent.location), let right = x(forColumn: NSMaxRange(indent)) {
            result.append(NSValue(rect: NSRect(x: CGFloat(left.doubleValue), y: CGFloat(displayStart) * lineHeight,
                width: max(0, CGFloat(right.doubleValue - left.doubleValue)), height: lineHeight)))
        }
        for index in 0..<pieces.count {
            let band = NSRange(location: source.columns[index].intValue + 1,
                               length: source.columns[index + 1].intValue - source.columns[index].intValue - 1)
            let selected = NSIntersectionRange(band, columns)
            guard selected.length > 0 else { continue }
            let left = CGFloat(anchors[index].doubleValue) + cellWidth
            let right = CGFloat(anchors[index + 1].doubleValue)
            if selected == band {
                result.append(NSValue(rect: NSRect(x: left, y: CGFloat(displayStart) * lineHeight,
                    width: max(0, right - left), height: CGFloat(height) * lineHeight)))
                continue
            }
            let padding = pieces[index].first.map { first in
                [NSRange(location: band.location, length: first.firstColumn - band.location),
                 NSRange(location: pieces[index].last!.endColumn, length: NSMaxRange(band) - pieces[index].last!.endColumn)]
            } ?? [band]
            for empty in padding {
                let part = NSIntersectionRange(selected, empty)
                guard part.length > 0, let a = x(forColumn: part.location), let b = x(forColumn: NSMaxRange(part)) else { continue }
                let display = part.location < (pieces[index].first?.firstColumn ?? NSMaxRange(band)) ?
                    pieces[index].first?.displayRow ?? 0 : pieces[index].last?.displayRow ?? 0
                result.append(NSValue(rect: NSRect(x: CGFloat(a.doubleValue), y: CGFloat(displayStart + display) * lineHeight,
                    width: max(0, CGFloat(b.doubleValue - a.doubleValue)), height: lineHeight)))
            }
            for local in pieces[index] {
                let part = NSIntersectionRange(selected, NSRange(location: local.firstColumn, length: local.endColumn - local.firstColumn))
                guard part.length > 0, let layout = local.layout,
                      let selection = layout.selection(forColumns: NSRange(location: part.location - local.firstColumn, length: part.length)) else { continue }
                let range = expandClusters ? layout.displayEnclosure(forUTF16Range: selection.utf16Range) : selection.utf16Range
                guard range.location != NSNotFound else { continue }
                guard let first = layout.cellUTF16Boundaries.firstIndex(of: NSNumber(value: range.location)),
                      let end = layout.cellUTF16Boundaries.firstIndex(of: NSNumber(value: NSMaxRange(range))),
                      let a = layout.projection(atColumn: first)?.nativeEdge,
                      let b = layout.projection(atColumn: end)?.nativeEdge,
                      expandClusters || (layout.projection(atColumn: first)?.kind == .nativeEdge &&
                                         layout.projection(atColumn: end)?.kind == .nativeEdge) else { continue }
                let x = max(left, local.originX + min(a.x, b.x))
                result.append(NSValue(rect: NSRect(x: x, y: CGFloat(displayStart + local.displayRow) * lineHeight,
                    width: max(0, min(right, local.originX + max(a.x, b.x)) - x), height: lineHeight)))
            }
        }
        for (index, column) in source.columns.enumerated() where NSLocationInRange(column.intValue, columns) {
            result.append(NSValue(rect: NSRect(x: CGFloat(anchors[index].doubleValue), y: CGFloat(displayStart) * lineHeight,
                width: cellWidth, height: CGFloat(height) * lineHeight)))
        }
        return result
    }

    static func groups(_ inputs: [NSNumber: iTermMalayalamTableSource], width: CGFloat, cellWidth: CGFloat) -> [Int: iTermMalayalamTableRow] {
        guard cellWidth > 0 else { return [:] }
        var result: [Int: iTermMalayalamTableRow] = [:], run: [(Int, iTermMalayalamTableSource)] = []
        func finish() {
            defer { run.removeAll() }
            guard run.count >= 2, run.contains(where: { $0.1.horizontal }),
                  run.contains(where: { $0.1.hasNaturalScript }), let first = run.first?.1 else { return }
            let count = first.columns.count - 1
            let data = run.filter { !$0.1.horizontal }
            guard !data.isEmpty else { return }
            // The initial boxed header can label a compact value column without becoming content demand.
            let firstData = run.firstIndex(where: { !$0.1.horizontal })!
            let header = data.count > 2 && !data[0].1.hasNaturalScript && firstData > 0 &&
                firstData + 1 < run.count && run[firstData - 1].1.horizontal && run[firstData + 1].1.horizontal
            let body = header ? Array(data.dropFirst()) : data
            var minimum = [CGFloat](repeating: 1, count: count), preferred = minimum
            var flexible = [Bool](repeating: false, count: count)
            for (_, source) in data {
                for index in 0..<count {
                    guard let content = source.content(index, preserveDecoration: false) else { continue }
                    var last: CGFloat = 0
                    for column in content.layout.cellUTF16Boundaries.indices {
                        if let edge = content.layout.projection(atColumn: column)?.nativeEdge {
                            minimum[index] = max(minimum[index], edge.x - last); last = edge.x
                        }
                    }
                    if body.contains(where: { $0.1 === source }) {
                        preferred[index] = max(preferred[index], content.layout.naturalWidth)
                        let text = content.layout.attributedString.string
                        let numeric = text.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) &&
                            !text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
                        flexible[index] = flexible[index] || (!numeric && text.contains(where: { !$0.isWhitespace }) &&
                            text.contains(where: { $0.isWhitespace }))
                    }
                }
            }
            if !flexible.contains(true) { flexible[0] = true }
            let left = CGFloat(first.columns[0].intValue) * cellWidth
            let available = width - left - 2 * cellWidth - CGFloat(count + 1 + count * 2) * cellWidth
            var sizes = minimum
            var spare = max(0, available - sizes.reduce(0, +))
            for index in 0..<count where !flexible[index] {
                let extra = min(spare, max(0, preferred[index] - sizes[index])); sizes[index] += extra; spare -= extra
            }
            let flexibleCount = flexible.filter { $0 }.count
            for index in 0..<count where flexible[index] { sizes[index] += spare / CGFloat(flexibleCount) }
            var anchors = [left]
            for size in sizes { anchors.append(anchors.last! + size + 3 * cellWidth) }
            for (row, source) in run {
                if let layout = iTermMalayalamTableRow(source: source, row: row, anchors: anchors, cellWidth: cellWidth, tooNarrow: available < minimum.reduce(0, +)) { result[row] = layout }
            }
        }
        for key in inputs.keys.sorted(by: { $0.intValue < $1.intValue }) {
            let row = key.intValue, source = inputs[key]!
            if let last = run.last, last.0 + 1 != row || last.1.columns != source.columns ||
                source.cells[source.columns[0].intValue] == "┌" { finish() }
            run.append((row, source))
            if source.cells[source.columns[0].intValue] == "└" { finish() }
        }
        finish()
        return result
    }
}
