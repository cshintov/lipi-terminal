import XCTest
import CoreText
@testable import iTerm2SharedARC

final class SessionViewTests: XCTestCase {
    private let dismemberScrollViewKey = "DismemberScrollView"
    private var savedDismemberScrollView: Any?

    override func setUp() {
        super.setUp()
        savedDismemberScrollView = iTermUserDefaults.userDefaults().object(forKey: dismemberScrollViewKey)
    }

    override func tearDown() {
        let defaults = iTermUserDefaults.userDefaults()
        if let savedDismemberScrollView {
            defaults.set(savedDismemberScrollView, forKey: dismemberScrollViewKey)
        } else {
            defaults.removeObject(forKey: dismemberScrollViewKey)
        }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        super.tearDown()
    }

    func testScrollerRemainsContainedWithoutLegacyPreference() throws {
        iTermUserDefaults.userDefaults().removeObject(forKey: dismemberScrollViewKey)
        try assertScrollerRemainsContained()
    }

    func testScrollerRemainsContainedWithLegacyPreferenceEnabled() throws {
        iTermUserDefaults.userDefaults().set(true, forKey: dismemberScrollViewKey)
        try assertScrollerRemainsContained()
    }

    private func assertScrollerRemainsContained(file: StaticString = #filePath,
                                                line: UInt = #line) throws {
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let sessionView = SessionView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let scrollView = try XCTUnwrap(sessionView.scrollview, file: file, line: line)
        let scroller = try XCTUnwrap(scrollView.verticalScroller, file: file, line: line)
        XCTAssertTrue(scroller.isDescendant(of: scrollView), file: file, line: line)

        for style: NSScroller.Style in [.legacy, .overlay, .legacy] {
            scrollView.scrollerStyle = style
            scrollView.tile()
            XCTAssertTrue(scrollView.verticalScroller === scroller, file: file, line: line)
            XCTAssertTrue(scroller.isDescendant(of: scrollView), file: file, line: line)
            XCTAssertEqual(scroller.scrollerStyle, style, file: file, line: line)
        }
    }
}

private final class FooterWriteCapturingSession: PTYSession {
    var writes = [String]()
    var executedBytes = 0
    var didExecuteBytes: ((Int) -> Void)?
    override func writeTask(_ string: String) { writes.append(string) }
    override func writeTaskNoBroadcast(_ string: String, encoding: UInt,
                                       forceEncoding: Bool, reporting: Bool) { writes.append(string) }
    override func screenExecutorDidUpdate(_ update: VT100ScreenTokenExecutorUpdate) {
        super.screenExecutorDidUpdate(update)
        executedBytes += update.numberOfBytesExecutedTotal
        didExecuteBytes?(executedBytes)
    }
}

@MainActor
final class MalayalamFooterIntegrationTests: XCTestCase {
    private var savedMode: Any?
    private var parents = [iTermHeadlessWindowController]()
    private var sessions = [FooterWriteCapturingSession]()
    private var windows = [NSWindow]()

    override func setUp() {
        super.setUp()
        // Keep unrelated provider discovery out of this real terminal/view fixture.
        let fetcher = OllamaModelCache.shared.fetcher
        OllamaModelCache.shared.fetcher = { _, _, _, completion in completion([]) }
        addTeardownBlock { OllamaModelCache.shared.fetcher = fetcher }
        let defaults = iTermUserDefaults.userDefaults()
        savedMode = defaults.object(forKey: "MalayalamNaturalRows")
        defaults.set(true, forKey: "MalayalamNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
    }

    override func tearDown() {
        windows.forEach { $0.close(); $0.contentView = nil }
        windows.removeAll()
        parents.removeAll()
        sessions.removeAll()
        let defaults = iTermUserDefaults.userDefaults()
        if let savedMode { defaults.set(savedMode, forKey: "MalayalamNaturalRows") }
        else { defaults.removeObject(forKey: "MalayalamNaturalRows") }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        super.tearDown()
    }

    private func fixture(initialText: String = "Qക്ഷR") throws -> (FooterWriteCapturingSession, SessionView, PTYTextView, iTermMalayalamCellStrip) {
        var profile = try XCTUnwrap(ProfileModel.sharedInstance().defaultBookmark())
        profile[KEY_NORMAL_FONT] = "Monaco 20"
        profile[KEY_NON_ASCII_FONT] = "NotoSansMalayalam-Regular 20"
        profile[KEY_USE_NONASCII_FONT] = true
        profile[KEY_USE_BOLD_FONT] = true
        profile[KEY_USE_ITALIC_FONT] = true
        profile[KEY_UNLIMITED_SCROLLBACK] = false
        profile[KEY_SCROLLBACK_LINES] = 1
        let session = try XCTUnwrap(FooterWriteCapturingSession(synthetic: true))
        sessions.append(session)
        session.profile = profile
        let parent = iTermHeadlessWindowController(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        parents.append(parent)
        session.setScreenSize(NSSize(width: 640, height: 300), parent: parent)
        session.setPreferencesFromAddressBookEntry(profile)
        session.setSize(VT100GridSizeMake(40, 6))
        let view = try XCTUnwrap(session.genericView as? SessionView)
        let text = try XCTUnwrap(session.textview)
        let footer = try XCTUnwrap(view.subviews.compactMap { $0 as? iTermMalayalamCellStrip }.first)
        let document = try XCTUnwrap(view.scrollview.documentView)
        XCTAssertEqual(NSStringFromClass(type(of: document)), "TextViewWrapper")
        XCTAssertTrue(text.superview === document, "keep the real production wrapper")
        if !initialText.isEmpty { feed(initialText, to: session) }
        return (session, view, text, footer)
    }

    private func feed(_ string: String, to session: PTYSession) {
        let bytes = Array(string.utf8)
        session.screen.performBlock(joinedThreads: { _, state, _ in
            state.terminalEnabled = true
            let parser = VT100Parser()
            parser.encoding = String.Encoding.utf8.rawValue
            bytes.withUnsafeBufferPointer { parser.putStreamData($0.baseAddress, length: Int32($0.count)) }
            var tokens = CVector()
            CVectorCreate(&tokens, 32)
            _ = parser.addParsedTokens(to: &tokens)
            for index in 0..<CVectorCount(&tokens) {
                state.terminal?.execute(CVectorGetObject(&tokens, index) as! VT100Token)
            }
            CVectorDestroy(&tokens)
        })
    }

    private func drawNotification(_ text: PTYTextView) {
        _ = text.drawingHelper
        NotificationCenter.default.post(name: NSNotification.Name("iTermMalayalamRowDidDraw"), object: text)
    }

    private func feedBytes(_ bytes: [UInt8], to session: FooterWriteCapturingSession,
                           expectingExecutedBytes target: Int?) async {
        let executed = target.map { _ in expectation(description: "raw read executed") }
        var fulfilled = false
        if let target, let executed {
            session.didExecuteBytes = { total in
                if total >= target && !fulfilled {
                    fulfilled = true
                    executed.fulfill()
                }
            }
        }
        // A joined-thread snapshot can pause queued tokens before execution; fence execution first.
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            let chars = UnsafeMutablePointer<CChar>(mutating:
                UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self))
            session.screen.threadedReadTask(chars, length: Int32(buffer.count))
        }
        if let executed { await fulfillment(of: [executed], timeout: 5) }
        session.didExecuteBytes = nil
        session.screen.performBlock(joinedThreads: { _, _, _ in })
    }

    private func renderedBitmap(_ text: PTYTextView, row: Int32,
                                includeSelection: Bool = false, name: String) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(text.renderImage(withLines: NSRange(location: Int(row), length: 1),
            includeMargins: false, backgroundColor: .black, showCursor: false, includeSelection: includeSelection))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return bitmap
    }

    private func foregroundColor(_ layout: iTermMalayalamRowLayout, at index: Int) throws -> NSColor {
        let foreground = try XCTUnwrap(layout.attributedString.attribute(
            NSAttributedString.Key(kCTForegroundColorAttributeName as String), at: index, effectiveRange: nil)) as! CGColor
        return try XCTUnwrap(NSColor(cgColor: foreground)?.usingColorSpace(.sRGB))
    }

    func testMalayalamUTF8ByteChunksPreserveSourceCells() async throws {
        let source = "കേരനിരകളാടും ഹരിത"
        let expectedCells = ["കേ", "ര", "നി", "ര", "ക", "ളാ", "ടും", " ", "ഹ", "രി", "ത"]
        let bytes = Array(source.utf8)
        let schedules = [[bytes]] + (0...bytes.count).map {
            [Array(bytes.prefix($0)), Array(bytes.dropFirst($0))]
        } + [bytes.map { [$0] }]
        var expectedBoundaries = [0]
        for cell in expectedCells { expectedBoundaries.append(expectedBoundaries.last! + cell.utf16.count) }
        var wholeLayout: iTermMalayalamRowLayout?
        for (scheduleIndex, chunks) in schedules.enumerated() {
            let (session, _, text, _) = try fixture(initialText: "")
            session.screen.performBlock(joinedThreads: { _, state, _ in
                state.terminalEnabled = true
                state.terminal?.encoding = String.Encoding.utf8.rawValue
            })
            var consumed = 0
            var previousCompleteBytes = 0
            var chargedBytes = 0
            for chunk in chunks {
                consumed += chunk.count
                // The oracle uses original scalar byte lengths, never lossy decoding of a cut.
                var completePrefix = ""
                var completeBytes = 0
                for scalar in source.unicodeScalars {
                    let scalarBytes = String(scalar).utf8.count
                    if completeBytes + scalarBytes > consumed { break }
                    completePrefix.unicodeScalars.append(scalar)
                    completeBytes += scalarBytes
                }
                // No-token reads charge only the consumption ledger, not the executor update.
                let advances = completeBytes > previousCompleteBytes
                if advances { chargedBytes += chunk.count }
                await feedBytes(chunk, to: session, expectingExecutedBytes: advances ? chargedBytes : nil)
                previousCompleteBytes = completeBytes
                let row = try XCTUnwrap(session.screen.screenCharArray(forLine: session.screen.numberOfScrollbackLines()))
                let columns = Int(session.screen.cursorX() - 1)
                let actual = (0..<columns).map { ScreenCharToStr(row.line.advanced(by: $0)) ?? "" }.joined()
                XCTAssertEqual(Array(actual.utf8), Array(completePrefix.utf8),
                               "schedule \(scheduleIndex), after \(consumed) bytes: incomplete scalars must stay pending")
            }
            let row = try XCTUnwrap(session.screen.screenCharArray(forLine: session.screen.numberOfScrollbackLines()))
            let cells = (0..<expectedCells.count).map { ScreenCharToStr(row.line.advanced(by: $0)) ?? "" }
            XCTAssertEqual(cells.map { Array($0.utf8) }, expectedCells.map { Array($0.utf8) }, "schedule \(scheduleIndex)")
            XCTAssertEqual(session.screen.cursorX(), Int32(expectedCells.count + 1))
            XCTAssertEqual(session.screen.cursorY(), 1)
            let helper = try XCTUnwrap(text.drawingHelper)
            let layout = try XCTUnwrap(helper.malayalamLayout(atLine: session.screen.numberOfScrollbackLines()))
            XCTAssertEqual(Array(layout.attributedString.string.utf8), bytes)
            let fullBoundaries = expectedBoundaries + Array(repeating: source.utf16.count,
                count: Int(session.screen.width()) + 1 - expectedBoundaries.count)
            XCTAssertEqual(layout.cellUTF16Boundaries.map(\.intValue), fullBoundaries)
            if let wholeLayout {
                XCTAssertEqual(layout.naturalWidth, wholeLayout.naturalWidth, accuracy: 0.001)
                XCTAssertEqual(layout.cellUTF16Boundaries, wholeLayout.cellUTF16Boundaries)
            } else {
                wholeLayout = layout
            }
            XCTAssertTrue(session.writes.isEmpty)
        }
    }

    func testStaleRowWidthReturnsNoNaturalLayout() throws {
        let (_, _, text, _) = try fixture()
        let helper = try XCTUnwrap(text.drawingHelper)
        let original = helper.gridSize
        for delta: Int32 in [12, -1] {
            helper.gridSize = VT100GridSizeMake(original.width + delta, original.height)
            XCTAssertNil(helper.malayalamLayout(atLine: 0), "stale geometry must not read or truncate a current row")
        }
    }

    func testOffscreenVisibleRowsKeepFirstAndLastRequestedRows() throws {
        let (_, _, text, _) = try fixture()
        let helper = try XCTUnwrap(text.drawingHelper)
        let height = helper.cellSize.height
        XCTAssertGreaterThan(height, 0)
        for first in [0, 49] {
            for margin: CGFloat in [0, 2] {
                let rows = NSRange(location: first, length: 22)
                let frame = NSRect(x: 0, y: 0, width: 640, height: CGFloat(rows.length) * height + 2 * margin)
                let clip = NSRect(x: 0, y: CGFloat(first) * height - margin,
                                  width: frame.width, height: frame.height)
                helper.configureForOffscreenRendering(withFrame: frame, visibleRect: clip, renderedRows: rows)
                XCTAssertEqual(helper.rangeOfVisibleRows(), rows, "offscreen row coverage, first \(first), margin \(margin)")
            }
        }
    }

    func testMalayalamAddressedOverwriteMatchesTmux() throws {
        let (session, _, _, _) = try fixture()
        feed("\u{1b}[2J\u{1b}[Hമലയാളം|END|\r\nABCD|END|\r\nക്ഷന്റെ", to: session)
        func row(_ index: Int32) throws -> ScreenCharArray {
            try XCTUnwrap(session.screen.screenCharArray(forLine: session.screen.numberOfScrollbackLines() + index))
        }
        XCTAssertEqual(try row(0).stringValue.trimmingCharacters(in: .whitespaces), "മലയാളം|END|")
        XCTAssertEqual(try row(1).stringValue.trimmingCharacters(in: .whitespaces), "ABCD|END|")
        // Expected cells come from the retained real tmux measurement, not Core Text.
        let word = try row(0)
        let conjuncts = try row(2)
        XCTAssertEqual((0..<4).map { ScreenCharToStr(word.line.advanced(by: $0)) ?? "" },
                       ["മ", "ല", "യാ", "ളം"])
        XCTAssertEqual((0..<4).map { ScreenCharToStr(conjuncts.line.advanced(by: $0)) ?? "" },
                       ["ക്", "ഷ", "ന്", "റെ"])
        // Exact captured tmux wire delta, including its acknowledgement row.
        feed("\u{1b}[1;5HX\u{1b}[2;5HX\u{1b}[4;1HPHASE=1 CUP-X\u{1b}[K", to: session)
        XCTAssertEqual(try row(0).stringValue.trimmingCharacters(in: .whitespaces), "മലയാളംXEND|")
        XCTAssertEqual(try row(1).stringValue.trimmingCharacters(in: .whitespaces), "ABCDXEND|")
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testCommonPromptAndNBSPKeepNaturalMalayalamRow() throws {
        let (session, _, text, _) = try fixture()
        // Match the composer: a common prompt, NBSP, and an unprinted blank cell between words.
        feed("\u{1b}[2J\u{1b}[H❯\u{00a0}കേരനിരകളാടും\u{1b}[1Cഹരിത ", to: session)
        let row = session.screen.numberOfScrollbackLines()
        let stored = try XCTUnwrap(session.screen.screenCharArray(forLine: row))
        let expected = ["❯", "\u{00a0}", "കേ", "ര", "നി", "ര", "ക", "ളാ", "ടും", " ", "ഹ", "രി", "ത", " "]
        let sourceCells = (0..<expected.count).map { index -> String in
            let cell = stored.line.advanced(by: index)
            return cell.pointee.code == 0 && cell.pointee.complexChar == 0 ? " " : ScreenCharToStr(cell) ?? ""
        }
        XCTAssertEqual(sourceCells, expected)
        XCTAssertEqual(stored.line[9].code, 0, "the composer gap remains an actual empty source cell")
        let helper = try XCTUnwrap(text.drawingHelper)
        let layout = try XCTUnwrap(helper.malayalamLayout(atLine: row), "common prompt and NBSP must not force grid fallback")
        XCTAssertEqual(layout.attributedString.string, expected.joined())
        var boundaries = [0]
        for cell in expected { boundaries.append(boundaries.last! + cell.utf16.count) }
        XCTAssertEqual(layout.cellUTF16Boundaries.prefix(boundaries.count).map(\.intValue), boundaries)
        // The client paints its cursor with SGR 7, first on a typing blank, then inside the word.
        for (column, character) in [(13, " "), (10, "ഹ")] {
            feed("\u{1b}[1;\(column + 1)H\u{1b}[7m\(character)\u{1b}[0m", to: session)
            let reversed = try XCTUnwrap(session.screen.screenCharArray(forLine: row))
            XCTAssertEqual(reversed.line[column].backgroundColorMode, UInt32(ColorModeAlternate.rawValue))
            XCTAssertEqual(reversed.line[column].backgroundColor, UInt32(ALTSEM_REVERSED_DEFAULT))
            let cursorLayout = try XCTUnwrap(helper.malayalamLayout(atLine: row), "client reverse-default cursor must retain natural shaping")
            XCTAssertEqual(cursorLayout.attributedString.string, expected.joined())
            XCTAssertEqual(cursorLayout.cellUTF16Boundaries.prefix(boundaries.count).map(\.intValue), boundaries)
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testUniformIndexedPromptBackgroundKeepsNaturalRowsAndPaint() throws {
        let (session, _, text, _) = try fixture(initialText: "")
        let song = "കേരനിരകളാടും ഹരിത"
        let expected = Array("❯ Reply exactly: ").map(String.init) +
            ["കേ", "ര", "നി", "ര", "ക", "ളാ", "ടും", " ", "ഹ", "രി", "ത"] +
            Array(repeating: " ", count: 12)
        func replay(background: String) {
            // Reduce the saved 110-cell prompt to 40 cells, keeping its text and style boundaries.
            // Overwrite the row in place: CSI2J would preserve the old row in scrollback.
            feed("\u{1b}[0m\u{1b}[H\u{1b}[\(background)m\u{1b}[38;5;246m❯ " +
                 "\u{1b}[38;5;231mReply exactly: " + song + "\u{1b}[39m" +
                 String(repeating: " ", count: 12) + "\u{1b}[0m", to: session)
        }
        replay(background: "49")
        let row = session.screen.numberOfScrollbackLines()
        let helper = try XCTUnwrap(text.drawingHelper)
        let map = try XCTUnwrap(helper.colorMap as? iTermColorMap)
        let gray = NSColor(srgbRed: 58.0 / 255, green: 58.0 / 255, blue: 58.0 / 255, alpha: 1)
        map.setColor(gray, forKey: Int32(kColorMap8bitBase + 237))
        map.setColor(.white, forKey: Int32(kColorMap8bitBase + 231))
        map.setColor(NSColor(srgbRed: 148.0 / 255, green: 148.0 / 255, blue: 148.0 / 255, alpha: 1),
                     forKey: Int32(kColorMap8bitBase + 246))
        map.setColor(.black, forKey: Int32(kColorMapBackground))
        map.minimumContrast = 0
        map.dimmingAmount = 0
        map.mutingAmount = 0
        helper.minimumContrast = 0
        helper.didFinishSetup()
        let ordinary = try XCTUnwrap(helper.malayalamLayout(atLine: row))
        for background in ["48;5;237", "49"] {
            replay(background: background)
            let stored = try XCTUnwrap(session.screen.screenCharArray(forLine: row))
            let cells = (0..<40).map { ScreenCharToStr(stored.line.advanced(by: $0)) ?? "" }
            XCTAssertEqual(cells.map { Array($0.utf8) }, expected.map { Array($0.utf8) })
            if background == "48;5;237" {
                for column in 0..<40 {
                    guard stored.line[column].backgroundColorMode == UInt32(ColorModeNormal.rawValue),
                          stored.line[column].backgroundColor == 237 else {
                        return XCTFail("captured indexed background missing at source column \(column)")
                    }
                }
                XCTAssertEqual(stored.line[0].foregroundColor, 246)
                XCTAssertEqual(stored.line[2].foregroundColor, 231)
                XCTAssertEqual(stored.line[28].foregroundColorMode, UInt32(ColorModeAlternate.rawValue))
            }
            let layout = try XCTUnwrap(helper.malayalamLayout(atLine: row), "uniform indexed background must not force grid spacing")
            XCTAssertEqual(Array(layout.attributedString.string.utf8), Array(expected.joined().utf8))
            XCTAssertEqual(layout.cellUTF16Boundaries, ordinary.cellUTF16Boundaries)
            XCTAssertEqual(layout.naturalWidth, ordinary.naturalWidth, accuracy: 0.001)
            let bitmap = try renderedBitmap(text, row: row, name: "Malayalam-background-\(background)")
            let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 2,
                y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            let level = background == "49" ? 0 : 58.0 / 255
            XCTAssertEqual(pixel.redComponent, level, accuracy: 0.01)
            XCTAssertEqual(pixel.greenComponent, level, accuracy: 0.01)
            XCTAssertEqual(pixel.blueComponent, level, accuracy: 0.01)
        }
        replay(background: "48;5;237")
        feed("\u{1b}[H\u{1b}[49m❯\u{1b}[0m", to: session)
        XCTAssertNil(helper.malayalamLayout(atLine: row), "mixed indexed/default backgrounds remain outside this slice")
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testBoldAndItalicMalayalamKeepNaturalRows() throws {
        let (session, _, text, _) = try fixture()
        let source = "A മലയാളം Z"
        let styles = ["0", "1", "3", "1;3"]
        feed("\u{1b}[2J\u{1b}[H" + styles.map { "\u{1b}[\($0)m\(source)\u{1b}[0m" }.joined(separator: "\r\n"), to: session)
        let helper = try XCTUnwrap(text.drawingHelper)
        for index in styles.indices {
            let row = session.screen.numberOfScrollbackLines() + Int32(index)
            guard let layout = helper.malayalamLayout(atLine: row) else {
                XCTFail("style \(styles[index]) must retain natural Malayalam shaping")
                continue
            }
            XCTAssertEqual(layout.attributedString.string, source)
            XCTAssertEqual(layout.cellUTF16Boundaries.prefix(9).map(\.intValue), [0, 1, 2, 3, 4, 6, 8, 9, 10])
            for run in CTLineGetGlyphRuns(layout.line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = try XCTUnwrap(attributes[kCTFontAttributeName]) as! CTFont
                let traits = CTFontGetSymbolicTraits(font)
                if index == 2 || index == 3 {
                    XCTAssertTrue(traits.contains(.traitItalic) || abs(CTFontGetMatrix(font).c - 0.2) < 0.001)
                }
            }
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testNaturalWholeClusterSelectionUsesConfiguredTextColor() throws {
        let (session, _, text, _) = try fixture()
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_USE_SELECTED_TEXT_COLOR] = true
        profile[KEY_USE_SEPARATE_COLORS_FOR_LIGHT_AND_DARK_MODE] = false
        session.profile = profile
        let row = session.screen.numberOfScrollbackLines()
        let helper = try XCTUnwrap(text.drawingHelper)
        let map = try XCTUnwrap(helper.colorMap as? iTermColorMap)
        map.setColor(.black, forKey: Int32(kColorMapForeground))
        map.setColor(.black, forKey: Int32(kColorMapBackground))
        map.setColor(.black, forKey: Int32(kColorMapSelection))
        map.setColor(.white, forKey: Int32(kColorMapSelectedText))
        helper.useSelectedTextColor = true
        helper.isFrontTextView = true
        let before = try XCTUnwrap(helper.malayalamLayout(atLine: row))
        let absolute = Int64(row) + session.screen.totalScrollbackOverflow()
        text.selection.begin(at: VT100GridAbsCoordMake(1, absolute),
            mode: iTermSelectionMode.kiTermSelectionModeCharacter, resume: false, append: false)
        text.selection.moveEndpoint(to: VT100GridAbsCoordMake(3, absolute))
        text.selection.endLive()
        XCTAssertEqual(text.selection.selectedIndexes(onAbsoluteLine: absolute), IndexSet(integersIn: 1..<3))
        let selected = try XCTUnwrap(helper.malayalamLayout(atLine: row))
        XCTAssertEqual(selected.attributedString.string, before.attributedString.string)
        XCTAssertEqual(selected.cellUTF16Boundaries, before.cellUTF16Boundaries)
        XCTAssertEqual(selected.naturalWidth, before.naturalWidth, accuracy: 0.001)
        let rgb = try foregroundColor(selected, at: 1)
        XCTAssertEqual(rgb.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.blueComponent, 1, accuracy: 0.001)
        XCTAssertEqual(text.selectedText, "ക്ഷ")
        func whitePixels(includeSelection: Bool, name: String) throws -> Int {
            let bitmap = try renderedBitmap(text, row: row, includeSelection: includeSelection, name: name)
            var white = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.5 { white += 1 }
                }
            }
            print("\(name): \(white) white pixels in \(bitmap.pixelsWide) by \(bitmap.pixelsHigh)")
            return white
        }
        XCTAssertEqual(try whitePixels(includeSelection: false, name: "Malayalam-unselected-black"), 0)
        XCTAssertGreaterThan(try whitePixels(includeSelection: true, name: "Malayalam-selected-white"), 20)
        text.selection.clear()
        text.selection.begin(at: VT100GridAbsCoordMake(1, absolute),
            mode: iTermSelectionMode.kiTermSelectionModeCharacter, resume: false, append: false)
        text.selection.moveEndpoint(to: VT100GridAbsCoordMake(2, absolute))
        text.selection.endLive()
        let partial = try XCTUnwrap(helper.malayalamLayout(atLine: row))
        let partialRGB = try foregroundColor(partial, at: 1)
        XCTAssertEqual(partialRGB.redComponent, 0, accuracy: 0.001, "outline-only selection keeps ordinary foreground")
        XCTAssertEqual(partialRGB.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(partialRGB.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(partial.cellUTF16Boundaries, before.cellUTF16Boundaries)
        XCTAssertEqual(partial.naturalWidth, before.naturalWidth, accuracy: 0.001)
        XCTAssertEqual(text.selectedText, "ക്", "partial source ownership must not expand for painting")
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testNaturalColorCacheRespectsBlockContrastEligibility() throws {
        let (session, _, text, _) = try fixture()
        feed("\u{1b}[2J\u{1b}[H█A █ മലയാളം", to: session)
        let helper = try XCTUnwrap(text.drawingHelper)
        let map = try XCTUnwrap(helper.colorMap as? iTermColorMap)
        map.setColor(.black, forKey: Int32(kColorMapForeground))
        map.setColor(.black, forKey: Int32(kColorMapBackground))
        map.minimumContrast = 0.5
        map.dimmingAmount = 0
        map.mutingAmount = 0
        helper.minimumContrast = 0.5
        helper.didFinishSetup()
        let layout = try XCTUnwrap(helper.malayalamLayout(atLine: session.screen.numberOfScrollbackLines()))
        XCTAssertEqual(layout.attributedString.string, "█A █ മലയാളം")
        for index in [0, 1, 3] {
            let rgb = try foregroundColor(layout, at: index)
            let brightest = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
            if index == 1 {
                XCTAssertGreaterThan(brightest, 0.1, "ordinary text must receive minimum contrast after a block")
            } else {
                XCTAssertLessThan(brightest, 0.001, "blocks must keep their original black foreground")
            }
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    private func click(_ footer: iTermMalayalamCellStrip, column: Int) throws {
        let rect = footer.rect(forColumn: column)
        let point = footer.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: footer.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        footer.mouseDown(with: event)
    }

    func testNaturalTextHitUsesClusterEdgesWhileStripSelectsInteriorCell() throws {
        let (session, _, text, footer) = try fixture()
        drawNotification(text)
        // Keep the tested row off the cursor row so horizontal pan is zero, without using Y geometry.
        feed("\r\n", to: session)
        let row = session.screen.numberOfScrollbackLines()
        let absolute = Int64(row) + session.screen.totalScrollbackOverflow()
        let cells = try XCTUnwrap(session.screen.screenCharArray(forLine: row))
        XCTAssertEqual((0..<4).map { ScreenCharToStr(cells.line.advanced(by: $0)) ?? "" },
                       ["Q", "ക്", "ഷ", "R"])
        let helper = try XCTUnwrap(text.drawingHelper)
        let layout = try XCTUnwrap(helper.malayalamLayout(atLine: row))
        XCTAssertEqual(layout.attributedString.string, "Qക്ഷR")
        let independentLine = CTLineCreateWithAttributedString(layout.attributedString)
        let start = CTLineGetOffsetForStringIndex(independentLine, 1, nil)
        let end = CTLineGetOffsetForStringIndex(independentLine, 4, nil)
        XCTAssertGreaterThan(end, start)
        let margin = CGFloat(iTermPreferences.sideMargins())
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        for (fraction, expectedColumn) in [(CGFloat(0.1), 1), (CGFloat(0.9), 3)] {
            let x = margin + start + fraction * (end - start)
            let column = try XCTUnwrap(helper.malayalamColumnFor(x: x, line: row))
            XCTAssertEqual(column.intValue, expectedColumn, "natural text chooses the nearest real cluster edge")
            XCTAssertNotEqual(column.intValue, 2, "the interior source cell has no invented text caret")
        }
        XCTAssertGreaterThan(helper.cellSize.width, 0)
        let interiorGridX = margin + 2 * helper.cellSize.width
        let interiorHit = try XCTUnwrap(helper.malayalamColumnFor(x: interiorGridX, line: row))
        XCTAssertNotEqual(interiorHit.intValue, 2, "a grid-interior coordinate cannot invent a grapheme-interior stop")
        try click(footer, column: 2)
        XCTAssertEqual(text.selection.selectedIndexes(onAbsoluteLine: absolute), IndexSet(integer: 2))
        XCTAssertEqual(text.selectedText, "ഷ", "the strip still selects the exact interior source cell")
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testVisibleFooterClickRestoresKeyboardFocusWithoutClientInput() throws {
        let (session, view, text, footer) = try fixture()
        feed("\u{1b}[?1004l", to: session)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        drawNotification(text)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(window.firstResponder === text)
        let rect = footer.rect(forColumn: 1)
        let point = footer.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let content = try XCTUnwrap(window.contentView)
        let superview = try XCTUnwrap(content.superview)
        guard window.isVisible, !rect.isEmpty, !footer.isHiddenOrHasHiddenAncestor,
              content.hitTest(superview.convert(point, from: nil)) === footer else {
            XCTFail("visible sized window must hit the real wrapped session's footer")
            return
        }
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
        guard text.selection.hasSelection else {
            XCTFail("local window event must reach footer selection before testing focus")
            return
        }
        XCTAssertTrue(window.firstResponder === text, "footer selection must restore terminal keyboard focus")
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testAwaitingDrawCannotSelectSource() throws {
        let (session, _, text, footer) = try fixture()
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        try click(footer, column: 0)
        XCTAssertFalse(text.selection.hasSelection, "awaiting footer must not select row zero")
        XCTAssertEqual(footer.columnCount, 0, "no hit targets before accepted state")
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testFooterScrollReachesLaterCellsWithoutClientInput() throws {
        let (session, view, text, footer) = try fixture()
        view.setFrameSize(NSSize(width: 640, height: view.frame.height))
        feed("\u{1b}[2J\u{1b}[HQക്ഷR" + String(repeating: "a", count: 16) + "Z" +
             String(repeating: "b", count: 19) + "\u{1b}[H", to: session)
        drawNotification(text)
        XCTAssertEqual(footer.visibleColumns, NSRange(location: 0, length: 20))
        XCTAssertTrue(footer.rect(forColumn: 20).isEmpty)
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let horizontal = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: -240, wheel3: 0))
        footer.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: horizontal)))
        XCTAssertFalse(footer.rect(forColumn: 20).isEmpty, "horizontal scrolling must expose later source cells")
        XCTAssertFalse(text.selection.hasSelection, "navigation alone must not select source")
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
        guard !footer.rect(forColumn: 20).isEmpty else { return }
        drawNotification(text) // An unchanged client cursor must not undo independent navigation.
        XCTAssertFalse(footer.rect(forColumn: 20).isEmpty)
        try click(footer, column: 20)
        XCTAssertEqual(text.selectedText, "Z", "the revealed hit target must select the exact stored cell")
        let selected = text.selectedText
        let vertical = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0))
        footer.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: vertical)))
        XCTAssertEqual(footer.visibleColumns.location, 0, "mouse wheel must navigate independently too")
        XCTAssertEqual(text.selectedText, selected)
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testWrappedDrawClickCopiesActualCellWithoutClientInput() throws {
        let (session, view, text, footer) = try fixture()
        drawNotification(text)
        guard footer.columnCount == Int(session.screen.width()) else {
            XCTFail("actual wrapped child must populate footer")
            return
        }
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let row = session.screen.numberOfScrollbackLines() + cursor.1 - 1
        let absolute = Int64(row) + session.screen.totalScrollbackOverflow()
        let source = try XCTUnwrap(session.screen.screenCharArray(forLine: row))
        let expected = ScreenCharToStr(source.line.advanced(by: 1)) ?? ""
        XCTAssertFalse(expected.isEmpty)
        try click(footer, column: 1)
        XCTAssertEqual(text.selection.selectedIndexes(onAbsoluteLine: absolute), IndexSet(integer: 1))
        XCTAssertEqual(text.selectedText, expected, "copy uses the exact stored source cell, not a whole-cluster expansion")
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
        XCTAssertLessThanOrEqual(footer.frame.maxY, view.scrollview.frame.minY)

        let other = try fixture()
        let beforeOtherDraw = footer.selectedColumns
        drawNotification(other.2)
        XCTAssertEqual(footer.selectedColumns, beforeOtherDraw, "another session's draw cannot change this footer")
        drawNotification(text)
        XCTAssertEqual(footer.selectedColumns, IndexSet(integer: 1))
        session.screen.performBlock(joinedThreads: { _, state, _ in state.maxScrollbackLines = 1 })
        feed(String(repeating: "filler\r\n", count: 12), to: session)
        guard session.screen.totalScrollbackOverflow() > absolute else {
            XCTFail("fixture must evict the displayed absolute row before its next draw")
            return
        }
        let before = text.selectedText
        let afterOutputCursor = (session.screen.cursorX(), session.screen.cursorY())
        try click(footer, column: 1) // The displayed absolute row has expired before its next draw.
        XCTAssertEqual(text.selectedText, before)
        XCTAssertEqual(session.screen.cursorX(), afterOutputCursor.0)
        XCTAssertEqual(session.screen.cursorY(), afterOutputCursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testShortSelectionResizeAndCursorPrefixes() throws {
        func check(_ events: [Int]) throws {
            let (session, view, text, footer) = try fixture()
            var selected = false
            drawNotification(text)
            for event in events {
                switch event {
                case 0: text.selection.clear(); selected = false
                case 1:
                    let cursor = (session.screen.cursorX(), session.screen.cursorY())
                    try click(footer, column: 1)
                    selected = true
                    XCTAssertEqual(session.screen.cursorX(), cursor.0)
                    XCTAssertEqual(session.screen.cursorY(), cursor.1)
                case 2:
                    view.setFrameSize(NSSize(width: view.frame.width == 640 ? 400 : 640,
                                             height: view.frame.height))
                default: feed("x", to: session)
                }
                drawNotification(text)
                XCTAssertEqual(footer.columnCount, Int(session.screen.width()))
                XCTAssertEqual(footer.selectedColumns, selected ? IndexSet(integer: 1) : IndexSet())
                XCTAssertLessThanOrEqual(footer.frame.maxY, view.scrollview.frame.minY)
                XCTAssertTrue(session.writes.isEmpty, "footer-only transitions never send client input")
            }
        }
        func prefixes(_ prefix: [Int], depth: Int) throws {
            try check(prefix)
            if depth > 0 { for event in 0..<4 { try prefixes(prefix + [event], depth: depth - 1) } }
        }
        try prefixes([], depth: 2)
    }
}
