import CoreText
import Foundation

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}

@main
struct LabChecks {
    static func main() {
        if CommandLine.arguments.contains("--measure") || CommandLine.arguments.contains("--measure-lines") {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data: Data
                if CommandLine.arguments.contains("--measure-lines") {
                    let corpus = ["Test-യിലേക്ക്", "കൊണ്ടുപോകും ഒരു ആഴ്ച ക്ഷമ സ്ത്രീ",
                                  "Demo-2 പുസ്തകത്തിലെ തലക്കെട്ടാണ്, Test-ലേക്ക് പുതിയ sample text rows ചേർത്തിട്ടുണ്ട്."]
                    data = try encoder.encode(corpus.map { try LineGeometry(text: $0).measurement() })
                } else {
                    data = try encoder.encode(CellFixture.examples.map { try CellLayout(cells: $0.cells).measurement() })
                }
                print(String(decoding: data, as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data("Measurement failed: \(error)\n".utf8))
                exit(1)
            }
            return
        }
        var failures = 0
        func check(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        check("ASCII caret boundaries") {
            let ascii = try LineGeometry(text: "ABC")
            try require(ascii.stops.map(\.utf16Index) == [0, 1, 2, 3],
                        "boundaries must include beginning, every character and end")
        }
        check("empty line") {
            let empty = try LineGeometry(text: "")
            try require(empty.stops.map(\.utf16Index) == [0] && empty.width == 0,
                        "empty text has one caret stop and no advance")
        }
        check("Malayalam conjunct stays whole") {
            let conjunct = try LineGeometry(text: "ക്ഷ")
            try require(conjunct.stops.map(\.utf16Index) == [0, 3],
                        "the conjunct must not expose an interior code-point caret stop")
        }
        check("emoji keeps surrogate pairs and joiners together") {
            let emoji = try LineGeometry(text: "A🧑🏽‍💻B")
            try require(emoji.stops.map(\.utf16Index) == [0, 1, 8, 9],
                        "the joined emoji is one candidate caret unit")
        }
        check("mixed-font attribution matches a directly constructed CTLine") {
            let text = "A ക്ഷ B"
            let geometry = try LineGeometry(text: text)
            let reference = NSMutableAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Monaco" as CFString, 12, nil)
            ])
            reference.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String),
                                   value: CTFontCreateWithName("NotoSansMalayalam-Regular" as CFString, 12, nil),
                                   range: NSRange(location: 2, length: 3))
            let line = CTLineCreateWithAttributedString(reference)
            let expectedWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            try require(geometry.text == text, "source text changed")
            try require(geometry.asciiFontName == "Monaco" && geometry.malayalamFontName == "NotoSansMalayalam-Regular",
                        "requested fonts must resolve, not silently fall back")
            try require(expectedWidth > 0 && abs(geometry.width - expectedWidth) < 0.000001,
                        "natural advance must match directly reconstructed CTLine, got \(geometry.width), expected \(expectedWidth)")
            for stop in geometry.stops {
                let expectedX = CTLineGetOffsetForStringIndex(line, stop.utf16Index, nil)
                try require(abs(stop.x - expectedX) < 0.000001,
                            "caret offset differs from direct reference at UTF-16 index \(stop.utf16Index)")
            }
        }
        check("equidistant hits stay explicit") {
            let geometry = try LineGeometry(text: "AB")
            let midpoint = (geometry.stops[0].x + geometry.stops[1].x) / 2
            try require(geometry.nearestStops(to: midpoint).map(\.utf16Index) == [0, 1],
                        "an exact tie must not silently choose a caret policy")
            try require(geometry.nearestStops(to: .nan).isEmpty && geometry.nearestStops(to: .infinity).isEmpty,
                        "non-finite input must not resolve to an arbitrary caret")
        }
        check("ASCII caret offsets match font-advance arithmetic") {
            let font = CTFontCreateWithName("Monaco" as CFString, 12, nil)
            var character: UniChar = 65
            var glyph: CGGlyph = 0
            var advance = CGSize.zero
            try require(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), "Monaco must contain A")
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            let geometry = try LineGeometry(text: "AAA")
            for stop in geometry.stops {
                try require(abs(stop.x - Double(stop.utf16Index) * advance.width) < 0.000001,
                            "caret x violates independent fixed-font advance arithmetic")
            }
            let edges = geometry.measurement().caretEdges
            try require(edges.count == 6, "three ASCII characters must expose six leading/trailing caret edges")
            for (ordinal, edge) in edges.enumerated() {
                let index = ordinal / 2
                let leading = ordinal % 2 == 0
                let expectedX = Double(index + (leading ? 0 : 1)) * advance.width
                try require(edge.utf16Index == index && edge.leadingEdge == leading &&
                            abs(edge.offset - expectedX) < 0.000001,
                            "enumerated caret edge violates independent ASCII index/advance arithmetic")
            }
            let cells = try CellLayout(cells: ["A", "A"])
            for position in cells.positions {
                let expected = Double(position.column) * advance.width
                try require(abs(position.rawPrimaryX - expected) < 0.000001 && abs(position.rawSecondaryX - expected) < 0.000001,
                            "raw cell x violates independent fixed-font advance arithmetic")
            }
        }
        check("terminal cell boundaries inside a conjunct are classified, not snapped") {
            let layout = try CellLayout(cells: ["ക്", "ഷ"])
            try require(layout.positions.map(\.utf16Index) == [0, 2, 3], "must retain both cell positions and the endpoint")
            try require(layout.positions.map(\.kind) == [.graphemeBoundary, .insideGrapheme, .graphemeBoundary],
                        "the second terminal cell is inside the shaped conjunct")
            let interior = layout.positions[1]
            try require(interior.enclosingStart == 0 && interior.enclosingEnd == 3,
                        "interior position must identify its enclosing grapheme")
            try require(abs(layout.positions[2].rawPrimaryX - layout.geometry.width) < 0.000001,
                        "the raw endpoint must equal the measured natural line advance")
            let prebase = try CellLayout(cells: ["ന്", "റ", "െ"])
            for (column, index) in [(1, 2), (2, 3)] {
                var secondary: CGFloat = 0
                let primary = CTLineGetOffsetForStringIndex(prebase.geometry.line, index, &secondary)
                let actual = prebase.positions[column]
                try require(abs(actual.rawPrimaryX - primary) < 0.000001 && abs(actual.rawSecondaryX - secondary) < 0.000001,
                            "raw interior probe must query its stated source index, not choose a new caret policy")
            }
        }
        check("native cluster-edge display anchor stays separate from exact logical column") {
            for cells in [["ക്", "ഷ"], ["ന്", "റ", "െ"], ["A", "ക്", "ഷ"]] {
                let layout = try CellLayout(cells: cells)
                let bytes = Array(cells.joined().utf8)
                for position in layout.positions where position.kind == .insideGrapheme {
                    let display = layout.displayPosition(at: position.column)
                    try require(display.anchorUTF16Index == position.enclosingStart && display.isProvisionalAnchor,
                                "interior caret must use an explicitly provisional cluster-start anchor")
                    let expectedX = position.enclosingStart == 0 ? 0 : try LineGeometry(text: "A").width
                    try require(display.nativeCaretX.map { abs($0 - expectedX) < 0.000001 } == true,
                                "native display caret must not invent or interpolate interior geometry")
                    try require(display.exactColumn == position.column && layout.geometry.text.utf8.elementsEqual(bytes),
                                "display anchoring must preserve exact logical column and source bytes")
                }
            }
            let ascii = try CellLayout(cells: ["A", "B"])
            for position in ascii.positions {
                let display = ascii.displayPosition(at: position.column)
                try require(display.anchorUTF16Index == position.utf16Index && !display.isProvisionalAnchor &&
                            display.nativeCaretX.map { abs($0 - position.rawPrimaryX) < 0.000001 } == true,
                            "ordinary ASCII boundaries must retain their real native edges")
            }
        }
        check("missing or ambiguous native evidence leaves the display caret unresolved") {
            let layout = try CellLayout(cells: ["ക്", "ഷ"])
            let position = layout.positions[1]
            for edges in [[], [CaretEdgeProbe(offset: 0, utf16Index: 2, leadingEdge: true)],
                          [CaretEdgeProbe(offset: .nan, utf16Index: 0, leadingEdge: true)],
                          [CaretEdgeProbe(offset: 0, utf16Index: 0, leadingEdge: true),
                              CaretEdgeProbe(offset: 1, utf16Index: 0, leadingEdge: true)]] {
                let display = CellDisplayPosition(position: position, text: layout.geometry.text, nativeEdges: edges)
                try require(display.nativeCaretX == nil && display.exactColumn == 1,
                            "unsupported native anchor must remain unresolved, never fall back to a raw probe")
            }
            let empty = try CellLayout(cells: [])
            try require(empty.displayPosition(at: 0).nativeCaretX == nil,
                        "empty text without native edge evidence must not manufacture a caret")
        }
        check("canonical spellings preserve bytes and different cell partitions") {
            let composed = try CellLayout(cells: ["ക", "ൊ"])
            let decomposed = try CellLayout(cells: ["ക", "െ", "ാ"])
            try require(composed.positions.count == 3 && decomposed.positions.count == 4,
                        "equivalent-looking spellings do not have equivalent terminal cells")
            try require(!composed.geometry.text.utf8.elementsEqual(decomposed.geometry.text.utf8),
                        "the lab must not normalize away different source bytes")
            try require(abs(composed.geometry.width - decomposed.geometry.width) < 0.000001,
                        "canonical forms should have equal natural advance with this font")
        }
        check("cell operations keep the logical grid as the source of text") {
            var buffer = CellBuffer()
            buffer.apply(.write("ക"))
            buffer.apply(.combinePrevious("്"))
            buffer.apply(.write("ഷ"))
            try require(buffer.cells == ["ക്", "ഷ"] && buffer.cursor == 2,
                        "the conjunct consists of two logical cells")
            buffer.apply(.left)
            buffer.apply(.write("A"))
            try require(buffer.cells.joined() == "ക്A" && buffer.cursor == 2,
                        "overwriting a cell must reshape surviving source text, not truncate old glyphs")
            buffer.apply(.left)
            buffer.apply(.eraseToEnd)
            try require(buffer.cells == ["ക്"] && buffer.cursor == 1,
                        "erase preserves the preceding cell's explicit virama")
        }
        check("delete shifts the suffix, preserves cursor and permits later combining input") {
            var buffer = CellBuffer()
            buffer.apply(.write("ക"))
            buffer.apply(.write("ഷ"))
            buffer.apply(.left)
            buffer.apply(.deleteCell)
            try require(buffer.cells == ["ക"] && buffer.cursor == 1,
                        "write, write, left, delete must remove the second cell without moving the cursor")
            buffer.apply(.deleteCell)
            try require(buffer.cells == ["ക"] && buffer.cursor == 1, "delete at the endpoint must be a no-op")
            buffer.apply(.combinePrevious("്"))
            try require(buffer.cells == ["ക്"] && buffer.cursor == 1, "combining input must attach to the surviving cell")
        }
        check("all short cell-event sequences preserve and classify cursor positions") {
            let events: [CellEvent] = [.write("ക"), .combinePrevious("്"), .write("ഷ"),
                                       .write("െ"), .write("ാ"), .left, .right, .eraseToEnd, .deleteCell]
            var states = 0
            var interiorCursorStates = 0
            var refusedCombiningEvents = 0
            func explore(_ buffer: CellBuffer, depth: Int) throws {
                states += 1
                try require((0...buffer.cells.count).contains(buffer.cursor), "cursor escaped the occupied-cell model")
                let layout = try CellLayout(cells: buffer.cells)
                try require(layout.positions.count == buffer.cells.count + 1, "cell position disappeared")
                try require(layout.geometry.text.utf8.elementsEqual(buffer.cells.joined().utf8), "source bytes changed")
                var expectedIndex = 0
                for (column, position) in layout.positions.enumerated() {
                    try require(position.column == column && position.utf16Index == expectedIndex,
                                "cell prefix index must equal the sum of preceding cell lengths")
                    try require(position.rawPrimaryX.isFinite && position.rawSecondaryX.isFinite,
                                "Core Text returned non-finite geometry")
                    if position.kind == .insideGrapheme {
                        try require(position.enclosingStart < position.utf16Index && position.utf16Index < position.enclosingEnd,
                                    "interior cell must retain its enclosing grapheme")
                    }
                    if column < buffer.cells.count { expectedIndex += buffer.cells[column].utf16.count }
                }
                if layout.positions[buffer.cursor].kind == .insideGrapheme { interiorCursorStates += 1 }
                guard depth < 4 else { return }
                for event in events {
                    var next = buffer
                    if !next.apply(event) {
                        refusedCombiningEvents += 1
                        try require(next.cursor == buffer.cursor && next.cells.map { Array($0.utf8) } == buffer.cells.map { Array($0.utf8) },
                                    "refused orphan combining input must not mutate the grid")
                    }
                    try explore(next, depth: depth + 1)
                }
            }
            try explore(CellBuffer(), depth: 0)
            try require(states == 7381 && interiorCursorStates > 0 && refusedCombiningEvents > 0,
                        "the bounded domain must include internal-cell cursor positions and explicit refusals")
            print("SEQUENCES: \(states) event-sequence prefixes (not distinct states), depth 4, 9 events, \(interiorCursorStates) interior-cursor occurrences, \(refusedCombiningEvents) explicit orphan-combining refusals")
        }
        if failures > 0 { exit(1) }
        print("PASS: all geometry checks")
    }
}
