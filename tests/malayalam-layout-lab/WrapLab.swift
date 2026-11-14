import AppKit
import CoreText
import Foundation

private func requireWrap(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "WrapLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct WrapLab {
    static func main() {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            if let fontIndex = args.firstIndex(of: "--font"), args.indices.contains(fontIndex + 1) {
                var error: Unmanaged<CFError>?
                guard CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[fontIndex + 1]) as CFURL,
                                                       .process, &error) else {
                    if let error { throw error.takeRetainedValue() as Error }
                    throw WrapFailure.invalidRow
                }
                args.removeSubrange(fontIndex...(fontIndex + 1))
            }
            let singleRow = args.contains("--single-row")
            args.removeAll { $0 == "--single-row" }
            if args.count == 4, args[0] == "--replay", let width = Double(args[3]) {
                try replay(input: args[1], output: args[2], width: CGFloat(width), singleRow: singleRow)
            } else {
                try requireWrap(args.isEmpty, "usage: [--font path] [--single-row] [--replay input.json output-prefix width]")
                try checks(singleRow: singleRow)
                print("PASS saved-output wrapping, exact source spans and source hit consistency (not native caret or live REPL proof)")
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func checks(singleRow: Bool) throws {
        let ascii = "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789"
        let rows = [
            WrapSourceRow(sourceRow: 0, cells: ascii.map(String.init), hardBreak: true),
            WrapSourceRow(sourceRow: 1, cells: String(repeating: "കേരനിരകളാടും ഹരിത ", count: 4).map(String.init), hardBreak: true),
            WrapSourceRow(sourceRow: 2, cells: ["ക്", "ഷ", " ", "👩‍💻", " ", "a", "\u{301}"], hardBreak: true),
            WrapSourceRow(sourceRow: 3, cells: [], hardBreak: true),
            WrapSourceRow(sourceRow: 4, cells: ["A", "\0", "മ", "", "Z"], hardBreak: false)
        ]
        let expected = ascii + "\n" + String(repeating: "കേരനിരകളാടും ഹരിത ", count: 4) +
            "\nക്ഷ 👩‍💻 a\u{301}\n\nA\0മZ"
        let originalCells = rows.map(\.cells)
        for widths in [[CGFloat(700), 130, 700], [130, 90, 360], [360, 130, 90]] {
            var firstSignature: [String]?
            for (position, width) in widths.enumerated() {
                let wrapped = try WrappedRows(rows: rows, width: width, singleRow: singleRow)
                try requireWrap(wrapped.extractedText == expected && wrapped.rows.map(\.cells) == originalCells,
                                "visual wrapping must not change source, cell ownership or hard breaks")
                var recovered = Array(repeating: "", count: rows.count)
                var offsets = Array(repeating: 0, count: rows.count)
                for (i, fragment) in wrapped.fragments.enumerated() {
                    try requireWrap(fragment.occupiedWidth <= width + 0.001 || fragment.oversizedCluster,
                                    "fragment exceeds viewport without a single oversized-cluster status")
                    let row = rows[fragment.rowIndex]
                    try requireWrap(fragment.sourceRange.location == offsets[fragment.rowIndex], "source gap or overlap")
                    let legal = wrapped.legalBoundaries(for: fragment.rowIndex)
                    if fragment.oversizedCluster {
                        try requireWrap(fragment.occupiedWidth > width &&
                            legal.first(where: { $0 > fragment.sourceRange.location }) == NSMaxRange(fragment.sourceRange),
                            "oversized status is only for one genuinely too-wide grapheme")
                    }
                    try requireWrap(legal.contains(fragment.sourceRange.location) && legal.contains(NSMaxRange(fragment.sourceRange)),
                                    "visual break splits a grapheme")
                    recovered[fragment.rowIndex] += (row.sourceText as NSString).substring(with: fragment.sourceRange)
                    offsets[fragment.rowIndex] = NSMaxRange(fragment.sourceRange)
                    try requireWrap(wrapped.cellSlices(in: fragment).reduce(0) { $0 + $1.utf16Length } == fragment.sourceRange.length,
                                    "fragment must retain exact source-cell UTF-16 slices")
                    for index in legal where index >= fragment.sourceRange.location && index <= NSMaxRange(fragment.sourceRange) {
                        guard let x = wrapped.x(forSourceIndex: index, in: fragment),
                              let hit = wrapped.hit(x: x, fragmentIndex: i),
                              let hitX = wrapped.x(forSourceIndex: hit.utf16Index, in: fragment) else {
                            throw WrapFailure.invalidRow
                        }
                        try requireWrap(hit.sourceRow == row.sourceRow && !hit.cellColumns.isEmpty && abs(hitX - x) < 0.001,
                                        "source hit mapping must preserve row and an equivalent grapheme boundary")
                    }
                    if fragment.rowIndex == 0 {
                        let font = CTFontCreateWithName("Monaco" as CFString, 20, nil)
                        var character: UniChar = 65, glyph: CGGlyph = 0, advance = CGSize.zero
                        try requireWrap(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), "Monaco A glyph")
                        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
                        try requireWrap(abs(fragment.advance - CGFloat(fragment.sourceRange.length) * advance.width) < 0.01,
                                        "fixed Monaco advance arithmetic must remain unchanged")
                        for index in fragment.sourceRange.location...NSMaxRange(fragment.sourceRange) {
                            guard let x = wrapped.x(forSourceIndex: index, in: fragment) else {
                                throw WrapFailure.invalidRow
                            }
                            try requireWrap(abs(x - CGFloat(index - fragment.sourceRange.location) * advance.width) < 0.01,
                                            "ASCII projection must match fixed-font arithmetic")
                            try requireWrap(wrapped.hit(x: x, fragmentIndex: i)?.utf16Index == index,
                                            "ASCII reverse hit must recover its exact source index")
                        }
                    }
                }
                try requireWrap(recovered == rows.map(\.sourceText), "visual fragments must reassemble exact source without extra newlines")
                let signature = wrapped.fragments.map { "\($0.rowIndex):\($0.sourceRange):\($0.advance):\($0.oversizedCluster)" }
                if position == 0 { firstSignature = signature }
                if position == widths.count - 1 && widths.first == widths.last {
                    try requireWrap(signature == firstSignature, "wide/narrow/wide must restore identical fragments")
                }
            }
        }
        let oversized = try WrappedRows(rows: [WrapSourceRow(sourceRow: 9, cells: ["ക്ഷ"], hardBreak: true)], width: 1,
                                        singleRow: singleRow)
        try requireWrap(oversized.fragments.count == 1 && oversized.fragments[0].oversizedCluster,
                        "single cluster wider than viewport must be explicit, never squeezed")
    }

    private struct ReplayInput: Decodable { let rows: [WrapSourceRow] }

    static func replay(input: String, output: String, width: CGFloat, singleRow: Bool) throws {
        let source = try JSONDecoder().decode(ReplayInput.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        try requireWrap(source.rows.count <= 128 && source.rows.reduce(0) { $0 + $1.sourceText.utf16.count } <= 100_000,
                        "saved-output replay must remain bounded")
        let wrapped = try WrappedRows(rows: source.rows, width: width, singleRow: singleRow)
        let fragments: [[String: Any]] = wrapped.fragments.enumerated().map { index, fragment in
            let row = wrapped.rows[fragment.rowIndex]
            return ["displayLine": index, "sourceRow": row.sourceRow,
                    "utf16Start": fragment.sourceRange.location, "utf16Length": fragment.sourceRange.length,
                    "advance": fragment.advance, "originX": fragment.originX, "occupiedWidth": fragment.occupiedWidth,
                    "inkMinX": fragment.inkBounds.minX, "inkMaxX": fragment.inkBounds.maxX,
                    "oversizedCluster": fragment.oversizedCluster,
                    "endsStoredHardRow": row.hardBreak && NSMaxRange(fragment.sourceRange) == row.sourceText.utf16.count,
                    "cellSlices": wrapped.cellSlices(in: fragment).map {
                        ["column": $0.column, "utf16Start": $0.utf16Start, "utf16Length": $0.utf16Length]
                    }]
        }
        let report: [String: Any] = [
            "layoutWidthPoints": width, "pointSize": wrapped.fontSize,
            "fontPolicy": "Plain Monaco and Noto Sans Malayalam, not original terminal style replication",
            "normalization": "NUL gaps become spaces for layout only, preserving UTF-16 lengths; extraction retains raw NULs",
            "breakPolicy": "Each stored row remains separate; no paragraph inference or soft-row joining",
            "proofLimit": "Read-only native offscreen saved-output rendering, not live REPL, native caret acceptance or framebuffer proof",
            "extractedText": wrapped.extractedText,
            "sourceRows": wrapped.rows.map {
                ["sourceRow": $0.sourceRow, "cellUTF16Boundaries": $0.cellBoundaries, "hardBreak": $0.hardBreak] as [String: Any]
            }, "fragments": fragments]
        let png = try render(wrapped)
        try png.write(to: URL(fileURLWithPath: output + ".png"), options: .withoutOverwriting)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output + ".json"), options: .withoutOverwriting)
        print("REPLAY rows=\(wrapped.rows.count) fragments=\(wrapped.fragments.count) width=\(width) points, plain native fonts")
    }

    static func render(_ wrapped: WrappedRows) throws -> Data {
        let margin: CGFloat = 12
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        for fragment in wrapped.fragments {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            _ = CTLineGetTypographicBounds(fragment.line, &a, &d, &l)
            ascent = max(ascent, max(a, fragment.inkBounds.maxY))
            descent = max(descent, max(d, -fragment.inkBounds.minY))
            leading = max(leading, l)
        }
        let heightPerLine = ceil(max(wrapped.fontSize + 4, ascent + descent + leading + 4))
        let pixelWidth = Int(ceil(wrapped.width + 2 * margin))
        let pixelHeight = Int(ceil(CGFloat(wrapped.fragments.count) * heightPerLine + 2 * margin))
        try requireWrap(pixelWidth > 0 && pixelWidth <= 8192 && pixelHeight > 0 && pixelHeight <= 32768,
                        "offscreen bitmap size must remain bounded")
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WrapFailure.invalidRow }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        context.textMatrix = .identity
        context.setShouldAntialias(false)
        for (index, fragment) in wrapped.fragments.enumerated() {
            let y = CGFloat(pixelHeight) - margin - ascent - CGFloat(index) * heightPerLine
            context.setFillColor(NSColor.black.cgColor)
            context.textPosition = CGPoint(x: margin + fragment.originX, y: y)
            CTLineDraw(fragment.line, context)
        }
        // Explicit content-width guide, not extra width silently granted to the text.
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.move(to: CGPoint(x: margin + wrapped.width, y: margin))
        context.addLine(to: CGPoint(x: margin + wrapped.width, y: CGFloat(pixelHeight) - margin))
        context.strokePath()
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw WrapFailure.invalidRow
        }
        return png
    }

}
