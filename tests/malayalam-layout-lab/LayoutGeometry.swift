import CoreText
import Foundation

struct CaretStop: Codable {
    let utf16Index: Int
    let x: Double
}

struct RawCaretProbe: Codable {
    let utf16Index: Int
    let primaryX: Double
    let secondaryX: Double
    let coreTextHitAtPrimary: Int
    let isCandidateBoundary: Bool
}

struct CaretEdgeProbe: Codable {
    let offset: Double
    let utf16Index: Int
    let leadingEdge: Bool
}

struct LineMeasurement: Codable {
    let text: String
    let width: Double
    let asciiFontName: String
    let malayalamFontName: String
    let candidateStops: [CaretStop]
    let scalarBoundaryProbes: [RawCaretProbe]
    let caretEdges: [CaretEdgeProbe]
    let cfComposedRanges: [TextRange]
    let runs: [RunProbe]
}

struct TextRange: Codable {
    let start: Int
    let end: Int
}

struct GlyphProbe: Codable {
    let glyph: Int
    let stringIndex: Int
    let x: Double
    let advance: Double
}

struct RunProbe: Codable {
    let fontName: String
    let fontURL: String?
    let range: TextRange
    let glyphs: [GlyphProbe]
}

enum GeometryFailure: Error {
    case requestedFontUnavailable(String)
}

struct LineGeometry {
    let text: String
    let stops: [CaretStop]
    let width: Double
    let asciiFontName: String
    let malayalamFontName: String
    let line: CTLine

    init(text: String, fontSize: CGFloat = 12) throws {
        let asciiFont = CTFontCreateWithName("Monaco" as CFString, fontSize, nil)
        let malayalamFont = CTFontCreateWithName("NotoSansMalayalam-Regular" as CFString, fontSize, nil)
        for (font, name) in [(asciiFont, "Monaco"), (malayalamFont, "NotoSansMalayalam-Regular")] {
            if CTFontCopyPostScriptName(font) as String != name {
                throw GeometryFailure.requestedFontUnavailable(name)
            }
        }
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let attributed = NSMutableAttributedString(string: text, attributes: [fontKey: asciiFont])
        for index in text.indices {
            let next = text.index(after: index)
            if text[index].unicodeScalars.contains(where: { !$0.isASCII }) {
                attributed.addAttribute(fontKey, value: malayalamFont, range: NSRange(index..<next, in: text))
            }
        }
        let shapedLine = CTLineCreateWithAttributedString(attributed)
        let boundaries = text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
        self.text = text
        self.line = shapedLine
        self.width = CTLineGetTypographicBounds(shapedLine, nil, nil, nil)
        self.asciiFontName = CTFontCopyPostScriptName(asciiFont) as String
        self.malayalamFontName = CTFontCopyPostScriptName(malayalamFont) as String
        self.stops = boundaries.map {
            CaretStop(utf16Index: $0, x: Double(CTLineGetOffsetForStringIndex(shapedLine, $0, nil)))
        }
    }

    func nearestStops(to x: Double) -> [CaretStop] {
        guard x.isFinite, let distance = stops.map({ abs($0.x - x) }).min() else { return [] }
        return stops.filter { abs(abs($0.x - x) - distance) < 0.000001 }
    }

    func measurement() -> LineMeasurement {
        let indices = text.unicodeScalars.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count]
        let probes = indices.map { index -> RawCaretProbe in
            var secondary: CGFloat = 0
            let primary = CTLineGetOffsetForStringIndex(line, index, &secondary)
            return RawCaretProbe(utf16Index: index, primaryX: primary, secondaryX: secondary,
                                 coreTextHitAtPrimary: CTLineGetStringIndexForPosition(line, CGPoint(x: primary, y: 0)),
                                 isCandidateBoundary: stops.contains { $0.utf16Index == index })
        }
        var composed: [TextRange] = []
        var index = 0
        while index < text.utf16.count {
            let range = CFStringGetRangeOfComposedCharactersAtIndex(text as CFString, index)
            composed.append(TextRange(start: range.location, end: range.location + range.length))
            index = range.location + range.length
        }
        let runs = (CTLineGetGlyphRuns(line) as! [CTRun]).map { run -> RunProbe in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            if count > 0 {
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            }
            let range = CTRunGetStringRange(run)
            return RunProbe(fontName: CTFontCopyPostScriptName(font) as String, fontURL: url?.path,
                            range: TextRange(start: range.location, end: range.location + range.length),
                            glyphs: (0..<count).map {
                                GlyphProbe(glyph: Int(glyphs[$0]), stringIndex: indices[$0],
                                           x: positions[$0].x, advance: advances[$0].width)
                            })
        }
        var edges: [CaretEdgeProbe] = []
        CTLineEnumerateCaretOffsets(line) { offset, index, leading, _ in
            edges.append(CaretEdgeProbe(offset: offset, utf16Index: index, leadingEdge: leading))
        }
        return LineMeasurement(text: text, width: width, asciiFontName: asciiFontName,
                               malayalamFontName: malayalamFontName, candidateStops: stops,
                               scalarBoundaryProbes: probes, caretEdges: edges,
                               cfComposedRanges: composed, runs: runs)
    }
}
