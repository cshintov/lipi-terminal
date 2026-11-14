import CoreText
import Foundation

enum CellPositionKind: String, Codable {
    case graphemeBoundary
    case insideGrapheme
}

struct CellPosition: Codable {
    let column: Int
    let utf16Index: Int
    let kind: CellPositionKind
    let enclosingStart: Int
    let enclosingEnd: Int
    let rawPrimaryX: Double
    let rawSecondaryX: Double
}

struct CellDisplayPosition: Codable {
    let exactColumn: Int
    let anchorUTF16Index: Int
    let nativeCaretX: Double?
    let isProvisionalAnchor: Bool

    init(position: CellPosition, text: String, nativeEdges: [CaretEdgeProbe]) {
        exactColumn = position.column
        let anchorIndex = position.enclosingStart
        anchorUTF16Index = anchorIndex
        isProvisionalAnchor = position.kind == .insideGrapheme
        let endIndex = text.utf16.count
        let lastScalarIndex = text.unicodeScalars.indices.last?.utf16Offset(in: text)
        let candidates = nativeEdges.filter { edge in
            guard edge.offset.isFinite else { return false }
            if anchorIndex < endIndex {
                return edge.leadingEdge && edge.utf16Index == anchorIndex
            }
            // Only the line endpoint uses a trailing edge; retain its raw index as evidence.
            return anchorIndex == endIndex && !edge.leadingEdge &&
                edge.utf16Index == lastScalarIndex && abs(edge.offset - position.rawPrimaryX) < 0.000001
        }
        var offsets: [Double] = []
        for edge in candidates where !offsets.contains(where: { abs($0 - edge.offset) < 0.000001 }) {
            offsets.append(edge.offset)
        }
        let nativeX = offsets.count == 1 ? offsets[0] : nil
        nativeCaretX = nativeX
    }
}

struct CellMeasurement: Codable {
    let provenance: String
    let cells: [String]
    let geometry: LineMeasurement
    let cellPositions: [CellPosition]
}

struct CellFixture {
    let title: String
    let cells: [String]

    static let examples = [
        CellFixture(title: "Conjunct", cells: ["ക്", "ഷ"]),
        CellFixture(title: "Pre-base vowel", cells: ["ക", "െ"]),
        CellFixture(title: "Two-part vowel", cells: ["ക", "ൊ"]),
        CellFixture(title: "Decomposed two-part vowel", cells: ["ക", "െ", "ാ"]),
        CellFixture(title: "Conjunct and pre-base vowel", cells: ["ന്", "റ", "െ"]),
        CellFixture(title: "Atomic chillu", cells: ["ൻ"]),
        CellFixture(title: "Legacy chillu", cells: ["ന്\u{200D}"]),
        CellFixture(title: "Explicit non-joiner", cells: ["ക്\u{200C}", "ഷ"]),
        CellFixture(title: "Mixed cluster sizes", cells: ["മ", "ല", "യ", "ാ", "ള", "ം"])
    ]
}

struct CellLayout {
    let cells: [String]
    let geometry: LineGeometry
    let positions: [CellPosition]

    init(cells: [String], fontSize: CGFloat = 12) throws {
        self.cells = cells
        let geometry = try LineGeometry(text: cells.joined(), fontSize: fontSize)
        self.geometry = geometry
        var offsets = [0]
        for cell in cells { offsets.append((offsets.last ?? 0) + cell.utf16.count) }
        let boundaries = geometry.stops.map(\.utf16Index)
        self.positions = offsets.enumerated().map { column, offset in
            let lower = boundaries.last(where: { $0 <= offset }) ?? 0
            let upper = boundaries.first(where: { $0 >= offset }) ?? geometry.text.utf16.count
            var secondary: CGFloat = 0
            let primary = CTLineGetOffsetForStringIndex(geometry.line, offset, &secondary)
            return CellPosition(column: column, utf16Index: offset,
                                kind: boundaries.contains(offset) ? .graphemeBoundary : .insideGrapheme,
                                enclosingStart: lower, enclosingEnd: upper,
                                rawPrimaryX: primary, rawSecondaryX: secondary)
        }
    }

    func measurement() -> CellMeasurement {
        return CellMeasurement(provenance: "Explicit source-derived fixture, not an observed terminal trace",
                               cells: cells, geometry: geometry.measurement(), cellPositions: positions)
    }

    func displayPosition(at column: Int) -> CellDisplayPosition {
        var edges: [CaretEdgeProbe] = []
        CTLineEnumerateCaretOffsets(geometry.line) { offset, index, leading, _ in
            edges.append(CaretEdgeProbe(offset: offset, utf16Index: index, leadingEdge: leading))
        }
        return CellDisplayPosition(position: positions[column], text: geometry.text, nativeEdges: edges)
    }
}

enum CellEvent {
    case write(String)
    case combinePrevious(String)
    case left
    case right
    case eraseToEnd
    case deleteCell
}

struct CellBuffer {
    private(set) var cells: [String] = []
    private(set) var cursor = 0

    @discardableResult
    mutating func apply(_ event: CellEvent) -> Bool {
        switch event {
        case .write(let text):
            guard !text.isEmpty else { return false }
            if cursor == cells.count { cells.append(text) } else { cells[cursor] = text }
            cursor += 1
        case .combinePrevious(let text):
            guard cursor > 0, !text.isEmpty else { return false }
            cells[cursor - 1] += text
        case .left:
            cursor = max(0, cursor - 1)
        case .right:
            cursor = min(cells.count, cursor + 1)
        case .eraseToEnd:
            cells.removeSubrange(cursor..<cells.count)
        case .deleteCell:
            if cursor < cells.count { cells.remove(at: cursor) }
        }
        return true
    }
}
