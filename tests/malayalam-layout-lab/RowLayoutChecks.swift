import CoreText
import Foundation
import AppKit
import Darwin

private func require(_ value: Bool, _ name: String) throws {
    if !value { throw NSError(domain: "RowLayoutChecks", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: name]) }
}

@main
struct RowLayoutChecks {
    static func main() {
        do { try checks() } catch {
            FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func checks() throws {
        let font = CTFontCreateWithName("Monaco" as CFString, 12, nil)
        let text = NSAttributedString(string: "ABC", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font])
        let layout = iTermMalayalamRowLayout(attributedString: text,
                                            cellUTF16Boundaries: [0, 1, 2, 3])!
        var chars: [UniChar] = [65, 66, 67]
        var glyphs = [CGGlyph](repeating: 0, count: 3)
        try require(CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 3), "ASCII font glyphs")
        var advances = [CGSize](repeating: .zero, count: 3)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, 3)
        let expected = advances.reduce(CGFloat(0)) { $0 + $1.width }
        try require(abs(layout.naturalWidth - expected) < 0.000001,
                    "ASCII width equals independent font advances")
        print("PASS ASCII width equals independent font advances")

        for boundaries: [NSNumber] in [[], [1, 3], [0, 2], [0, 2, 1, 3],
                                        [0, -1, 3], [0, 0.5, 3], [0, .init(value: Double.nan), 3]] {
            try require(iTermMalayalamRowLayout(attributedString: text,
                                               cellUTF16Boundaries: boundaries) == nil,
                        "invalid cell boundaries rejected: \(boundaries)")
        }
        let astral = NSAttributedString(string: "😀")
        try require(iTermMalayalamRowLayout(attributedString: astral,
                                           cellUTF16Boundaries: [0, 1, 2]) == nil,
                    "surrogate-splitting cell boundary rejected")
        try require(iTermMalayalamRowLayout(attributedString: text,
                                           cellUTF16Boundaries: [0, 1, 1, 3]) != nil,
                    "duplicate continuation boundary retained")
        try require(iTermMalayalamRowLayout(attributedString: NSAttributedString(string: ""),
                                           cellUTF16Boundaries: [0]) != nil,
                    "empty row has an explicit zero boundary")
        print("PASS boundary validation and duplicate continuations")

        try require(CommandLine.arguments.count <= 2, "Usage: RowLayoutChecks [font-file-path]")
        let fontURL = (CommandLine.arguments.count == 2
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Fonts/NotoSansMalayalam-VariableFont_wdth,wght.ttf")).standardizedFileURL
        let fontPath = fontURL.path
        var error: Unmanaged<CFError>?
        try require(CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error),
                    "process-only Noto registration")
        let noto = CTFontCreateWithName("NotoSansMalayalam-Regular" as CFString, 12, nil)
        try require((CTFontCopyAttribute(noto, kCTFontURLAttribute) as? URL)?.path == fontPath,
                    "actual Noto file")
        let conjunct = NSAttributedString(string: "ക്ഷ", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): noto])
        let row = iTermMalayalamRowLayout(attributedString: conjunct,
                                         cellUTF16Boundaries: [0, 2, 3])!
        let interior = row.projection(atColumn: 1)!
        try require(interior.logicalColumn == 1 && interior.utf16Index == 2 &&
                    interior.anchorUTF16Index == 0 && interior.kind == .provisionalClusterStart &&
                    interior.nativeEdge != nil,
                    "conjunct interior preserves exact column with provisional real start edge")
        let endpoint = row.projection(atColumn: 2)!
        try require(endpoint.kind == .nativeEdge && endpoint.anchorUTF16Index == 3 &&
                    abs(endpoint.nativeEdge!.x - row.naturalWidth) < 0.000001,
                    "conjunct endpoint is validated natural endpoint")
        try require(row.nativeEdges.contains { $0 === interior.nativeEdge },
                    "projection retains enumerated native edge evidence")
        let hit = row.hitTest(nativeX: row.naturalWidth * 0.25)!
        try require(hit.utf16Index == 0 && hit.logicalColumns == [0],
                    "native click never invents interior logical caret")
        try require(row.hitTest(nativeX: .nan) == nil && row.projection(atColumn: -1) == nil &&
                    row.projection(atColumn: 3) == nil, "invalid query bounds")
        for column in 0...3 {
            let p = layout.projection(atColumn: column)!
            let x = advances.prefix(column).reduce(CGFloat(0)) { $0 + $1.width }
            try require(p.kind == .nativeEdge && abs(p.nativeEdge!.x - x) < 0.000001,
                        "ASCII column matches independent prefix advances")
        }
        print("PASS native caret projection and hit testing")

        let selected = row.selection(forColumns: NSRange(location: 1, length: 1))
        try require(selected?.sourceText == "ഷ" && selected?.utf16Range == NSRange(location: 2, length: 1) &&
                    selected?.startsInsideCluster == true && selected?.endsInsideCluster == false,
                    "partial cluster selection preserves exact source, never expands")
        let full = row.selection(forColumns: NSRange(location: 0, length: 2))!
        try require(full.sourceText == "ക്ഷ" && !full.startsInsideCluster && !full.endsInsideCluster,
                    "whole cluster source selection")
        let prefix = row.selection(forColumns: NSRange(location: 0, length: 1))!
        try require(prefix.sourceText == "ക്" && !prefix.startsInsideCluster && prefix.endsInsideCluster,
                    "partial cluster prefix preserves virama and reports partial end")
        let duplicate = iTermMalayalamRowLayout(attributedString: text,
                                               cellUTF16Boundaries: [0, 1, 1, 3])!
        let continuation = duplicate.selection(forColumns: NSRange(location: 1, length: 1))!
        try require(continuation.sourceText.isEmpty && continuation.logicalColumns.length == 1,
                    "continuation cell keeps logical ownership without inventing text")
        try require(duplicate.hitTest(nativeX: advances[0].width)!.logicalColumns == [1, 2],
                    "native hit exposes duplicate-boundary columns without choosing one")
        let unrepresented = duplicate.hitTest(nativeX: advances[0].width + advances[1].width)!
        try require(unrepresented.utf16Index == 2 && unrepresented.logicalColumns.isEmpty,
                    "nearest unrepresented native edge is retained with no logical columns")
        try require(row.selection(forColumns: NSRange(location: Int.max, length: Int.max)) == nil,
                    "selection overflow rejected without range arithmetic overflow")
        try require(row.selection(forColumns: NSRange(location: -1, length: 1)) == nil &&
                    row.selection(forColumns: NSRange(location: 0, length: -1)) == nil,
                    "negative selection rejected")
        let mutable = NSMutableAttributedString(attributedString: text)
        let snapshot = iTermMalayalamRowLayout(attributedString: mutable,
                                              cellUTF16Boundaries: [0, 1, 2, 3])!
        mutable.replaceCharacters(in: NSRange(location: 0, length: 3), with: "Z")
        try require(snapshot.attributedString.string == "ABC", "row owns immutable text snapshot")
        let empty = iTermMalayalamRowLayout(attributedString: NSAttributedString(string: ""),
                                           cellUTF16Boundaries: [0])!
        try require(empty.projection(atColumn: 0)!.kind == .unresolved && empty.hitTest(nativeX: 0) == nil,
                    "no native evidence means unresolved, not invented empty-row edge")
        print("PASS exact source and partial cluster selection")

        let pan = iTermMalayalamRowLayout.panOffset
        try require(pan(100, 30, 80, 0) == 50, "pan follows caret beyond viewport")
        try require(pan(100, 30, 10, 50) == 10, "pan follows caret back left")
        try require(pan(100, 30, 70, 50) == 50, "pan preserves visible caret offset")
        try require(pan(100, 30, 100, 0) == 70 && pan(20, 30, 20, 50) == 0,
                    "pan clamps content endpoint and short rows")
        try require(pan(100, 0, 80, 0) == 0 && pan(100, 30, .nan, 0) == 0,
                    "invalid pan geometry returns safe origin")
        for width in [CGFloat(0), 20, 50, 100] {
            for viewport in [CGFloat(1), 30, 100] {
                for caret in stride(from: CGFloat(0), through: width, by: 1) {
                    for previous in [CGFloat(-20), 0, 50, 200] {
                        let offset = pan(width, viewport, caret, previous)
                        try require(offset >= 0 && offset <= max(0, width - viewport) &&
                                    caret >= offset && caret <= offset + viewport,
                                    "stateless pan bounds and active caret visibility")
                    }
                }
            }
        }
        print("PASS stateless caret-following pan boundaries")

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 26),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let strip = iTermMalayalamCellStrip(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
        window.contentView = strip
        strip.columnCount = 81
        strip.cursorColumn = 79
        strip.focusColumn = 79
        var selectedColumn: Int?
        strip.didSelectColumn = { column in selectedColumn = column; strip.selectedColumns = IndexSet(integer: column) }
        let point = strip.convert(NSPoint(x: 390, y: 13), to: nil)
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        strip.mouseDown(with: click)
        try require(selectedColumn != nil && selectedColumn! > 70 && strip.cursorColumn == 79,
                    "strip click selects translated exact column without moving protocol cursor")
        try require(NSMaxRange(strip.visibleColumns) <= 81 &&
                    strip.visibleColumns.location <= 79 && NSMaxRange(strip.visibleColumns) > 79,
                    "logical strip keeps active column visible")
        let cursorRect = strip.rect(forColumn: 79)
        try require(!cursorRect.isEmpty && strip.bounds.contains(cursorRect), "strip marker bounds")
        let bitmap = strip.bitmapImageRepForCachingDisplay(in: strip.bounds)!
        strip.cacheDisplay(in: strip.bounds, to: bitmap)
        try require(strip.drawCount > 0, "actual production strip draw dispatched")
        // All short resize/focus/click prefixes exercise the actual view, not a second hit mapper.
        func sequence(_ events: [Int]) throws {
            strip.frame.size.width = 400
            strip.focusColumn = 79
            strip.cursorColumn = 79
            strip.selectedColumns = []
            selectedColumn = nil
            for event in events {
                switch event {
                case 0: strip.frame.size.width = strip.frame.width == 400 ? 208 : 400
                case 1: strip.focusColumn = strip.focusColumn == 79 ? 0 : 79
                default:
                    let visible = strip.visibleColumns
                    let last = NSMaxRange(visible) - 1
                    let hitRect = strip.rect(forColumn: last)
                    let location = strip.convert(NSPoint(x: hitRect.midX, y: hitRect.midY), to: nil)
                    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
                    strip.mouseDown(with: event)
                    try require(selectedColumn == last, "sequence exact strip hit after resize or focus")
                }
                let visible = strip.visibleColumns
                let expectedSlots = Int((strip.frame.width - 160) / 24)
                try require(visible.length == expectedSlots &&
                            visible.location == max(0, strip.focusColumn + 1 - expectedSlots),
                            "sequence viewport follows explicit focus")
                try require(strip.cursorColumn == 79, "sequence never mutates protocol cursor")
            }
        }
        func prefixes(_ prefix: [Int], remaining: Int) throws {
            try sequence(prefix)
            if remaining > 0 {
                for event in 0..<3 { try prefixes(prefix + [event], remaining: remaining - 1) }
            }
        }
        try prefixes([], remaining: 3)
        strip.cursorColumn = strip.columnCount
        strip.focusColumn = strip.columnCount
        try require(NSMaxRange(strip.visibleColumns) == strip.columnCount &&
                    strip.bounds.contains(strip.rect(forColumn: strip.columnCount - 1)),
                    "pending-wrap endpoint stays visible without inventing another source cell")
        strip.frame.size.width = 100
        try require(strip.visibleColumns.length == 0 && strip.rect(forColumn: 0).isEmpty,
                    "narrow footer has no offscreen hit targets")
        window.close()
        print("PASS production AppKit strip dispatch, hit translation and cursor distinction")
    }
}
