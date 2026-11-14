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
    var forwardWritesToPTY = false
    var wheelWritableTTY: Bool?
    override func textViewCanWriteToTTY() -> Bool { wheelWritableTTY ?? super.textViewCanWriteToTTY() }
    var executedBytes = 0
    var didExecuteBytes: ((Int) -> Void)?
    var redrawRects = [NSRect]()
    override func textViewNeedsDisplay(in rect: NSRect) {
        redrawRects.append(rect)
        super.textViewNeedsDisplay(in: rect)
    }
    override func writeTask(_ string: String) {
        if forwardWritesToPTY { super.writeTask(string) }
        else { writes.append(string) }
    }
    override func writeTaskNoBroadcast(_ string: String, encoding: UInt,
                                       forceEncoding: Bool, reporting: Bool) {
        writes.append(string)
        if forwardWritesToPTY {
            super.writeTaskNoBroadcast(string, encoding: encoding, forceEncoding: forceEncoding, reporting: reporting)
        }
    }
    override func screenExecutorDidUpdate(_ update: VT100ScreenTokenExecutorUpdate) {
        super.screenExecutorDidUpdate(update)
        executedBytes += update.numberOfBytesExecutedTotal
        didExecuteBytes?(executedBytes)
    }
}

@MainActor
final class MalayalamFooterIntegrationTests: XCTestCase {
    private var savedMode: Any?
    private var savedHindiMode: Any?
    private var savedCellStrip: Any?
    private var parents = [iTermHeadlessWindowController]()
    private var sessions = [FooterWriteCapturingSession]()
    private var windows = [NSWindow]()
    private var mouseTerminal: PseudoTerminal?

    override func setUp() {
        super.setUp()
        // Keep unrelated provider discovery out of this real terminal/view fixture.
        let fetcher = OllamaModelCache.shared.fetcher
        OllamaModelCache.shared.fetcher = { _, _, _, completion in completion([]) }
        addTeardownBlock { OllamaModelCache.shared.fetcher = fetcher }
        let defaults = iTermUserDefaults.userDefaults()
        savedMode = defaults.object(forKey: "MalayalamNaturalRows")
        savedHindiMode = defaults.object(forKey: "HindiNaturalRows")
        savedCellStrip = defaults.object(forKey: "MalayalamCellStrip")
        defaults.set(true, forKey: "MalayalamCellStrip")
        defaults.set(true, forKey: "MalayalamNaturalRows")
        defaults.set(false, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
    }

    override func tearDown() {
        mouseTerminal?.window?.close()
        mouseTerminal = nil
        windows.forEach { $0.close(); $0.contentView = nil }
        windows.removeAll()
        parents.removeAll()
        sessions.removeAll()
        let defaults = iTermUserDefaults.userDefaults()
        if let savedMode { defaults.set(savedMode, forKey: "MalayalamNaturalRows") }
        else { defaults.removeObject(forKey: "MalayalamNaturalRows") }
        if let savedHindiMode { defaults.set(savedHindiMode, forKey: "HindiNaturalRows") }
        else { defaults.removeObject(forKey: "HindiNaturalRows") }
        if let savedCellStrip { defaults.set(savedCellStrip, forKey: "MalayalamCellStrip") }
        else { defaults.removeObject(forKey: "MalayalamCellStrip") }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        super.tearDown()
    }

    private func fixture(initialText: String = "Qക്ഷR", scrollbackLines: Int = 1) throws -> (FooterWriteCapturingSession, SessionView, PTYTextView, iTermMalayalamCellStrip) {
        var profile = try XCTUnwrap(ProfileModel.sharedInstance().defaultBookmark())
        profile[KEY_NORMAL_FONT] = "Monaco 20"
        profile[KEY_NON_ASCII_FONT] = "NotoSansMalayalam-Regular 20"
        profile[KEY_USE_NONASCII_FONT] = true
        profile[KEY_USE_BOLD_FONT] = true
        profile[KEY_USE_ITALIC_FONT] = true
        profile[KEY_UNLIMITED_SCROLLBACK] = false
        profile[KEY_SCROLLBACK_LINES] = scrollbackLines
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
        XCTAssertNotNil(helper.malayalamLayout(atLine: row), "background changes at native edges retain shaping")
        feed("\u{1b}[H\u{1b}[2K\u{1b}[48;5;237mക്\u{1b}[49mഷ\u{1b}[0m", to: session)
        XCTAssertNil(helper.malayalamLayout(atLine: row), "a real background boundary inside a conjunct remains unsupported")
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testTmuxTruecolorHeaderKeepsNaturalMalayalamAndPaint() throws {
        defer {
            let drained = expectation(description: "header fixture refresh callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        let defaults = iTermUserDefaults.userDefaults()
        let saved = defaults.object(forKey: "MalayalamVisualWrap")
        defaults.set(true, forKey: "MalayalamVisualWrap")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        defer {
            if let saved { defaults.set(saved, forKey: "MalayalamVisualWrap") }
            else { defaults.removeObject(forKey: "MalayalamVisualWrap") }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        let (session, view, text, _) = try fixture(initialText: "")
        session.setSize(VT100GridSizeMake(110, 6))
        session.screen.performBlock(joinedThreads: { _, state, _ in
            state.mutateColorMap { colors in
                colors.setColor(.white, forKey: Int32(kColorMapForeground))
                colors.setColor(.black, forKey: Int32(kColorMapBackground))
                colors.setColor(NSColor(srgbRed: 58.0 / 255, green: 58.0 / 255, blue: 58.0 / 255, alpha: 1),
                                forKey: Int32(kColorMap8bitBase + 237))
                colors.minimumContrast = 0
            }
        })
        session.sync()
        let helper = try XCTUnwrap(text.drawingHelper)
        helper.minimumContrast = 0
        helper.didFinishSetup()
        let prefix = "HISTORY 031 കേരനിരകളാടും ഹരിത"
        let header = "06:55 [10/82]"
        let backgrounds = ["49", "48;5;237", "48;2;184;134;11", "48;2;70;100;130"]
        func replay(_ style: Int, uniform: Bool = false) {
            feed("\u{1b}[0m\u{1b}[H" + (uniform ? "\u{1b}[\(backgrounds[style])m" : "") + "\u{1b}[2K" + prefix +
                 "\u{1b}[1;98H\u{1b}[38;2;13;13;13m\u{1b}[\(backgrounds[style])m" + header + "\u{1b}[0m", to: session)
            _ = text.refresh()
        }
        feed("\u{1b}[?1049h", to: session)
        replay(0)
        XCTAssertNotNil(helper.malayalamDisplayMap, "the ordinary tmux alternate-screen baseline must enable the map")
        let row = session.screen.numberOfScrollbackLines()
        let ordinary = try XCTUnwrap(helper.malayalamLayout(atLine: row))
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let ordinarySource = session.screen.screenCharArray(forLine: row)
        let expectedCells = (0..<110).map { ScreenCharToStr(ordinarySource.line.advanced(by: $0)) ?? "" }
        XCTAssertEqual(expectedCells.prefix(23).joined(), prefix)
        XCTAssertEqual(expectedCells.suffix(13).joined(), header)
        // Every short pair covers default, indexed, truecolor and truecolor-component changes.
        for first in backgrounds.indices {
            for second in backgrounds.indices {
                for style in [first, second] {
                    replay(style)
                    let stored = session.screen.screenCharArray(forLine: row)
                    XCTAssertEqual((0..<110).map { ScreenCharToStr(stored.line.advanced(by: $0)) ?? "" }, expectedCells)
                    for column in 23..<97 { XCTAssertEqual(stored.line[column].code, 0) }
                    if style >= 2 {
                        XCTAssertEqual(stored.line[97].backgroundColorMode, UInt32(ColorMode24bit.rawValue))
                        XCTAssertEqual(stored.line[97].backgroundColor, style == 2 ? 184 : 70)
                        XCTAssertEqual(stored.line[97].bgGreen, style == 2 ? 134 : 100)
                        XCTAssertEqual(stored.line[97].bgBlue, style == 2 ? 11 : 130)
                    }
                    let layout = try XCTUnwrap(helper.malayalamLayout(atLine: row), "truecolor header must not squeeze the Malayalam prefix into grid cells")
                    XCTAssertEqual(layout.attributedString.string, ordinary.attributedString.string)
                    XCTAssertEqual(layout.cellUTF16Boundaries, ordinary.cellUTF16Boundaries)
                    XCTAssertEqual(layout.naturalWidth, ordinary.naturalWidth, accuracy: 0.001)
                    for column in 0...23 {
                        XCTAssertEqual(layout.projection(atColumn: column)?.nativeEdge?.x,
                                       ordinary.projection(atColumn: column)?.nativeEdge?.x)
                    }
                    XCTAssertEqual(session.screen.cursorX(), cursor.0)
                    XCTAssertEqual(session.screen.cursorY(), cursor.1)
                    let map = try XCTUnwrap(helper.malayalamDisplayMap)
                    XCTAssertFalse(map.fragments(forSourceRow: Int(row)).isEmpty)
                }
            }
        }
        for uniform in [false, true] {
            replay(2, uniform: uniform)
            let layout = try XCTUnwrap(helper.malayalamLayout(atLine: row))
            let map = try XCTUnwrap(helper.malayalamDisplayMap)
            let pieces = map.fragments(forSourceRow: Int(row))
            // Probe the actual header space (source column102), never a bitmap margin or glyph.
            let piece = try XCTUnwrap(pieces.first { $0.firstColumn <= 102 && $0.endColumn >= 103 })
            let fragmentLayout = try XCTUnwrap(piece.layout)
            let spaceStart = layout.cellUTF16Boundaries[102].intValue - piece.sourceRange.location
            let a = try XCTUnwrap(fragmentLayout.cellUTF16Boundaries.firstIndex(of: NSNumber(value: spaceStart)))
            let b = try XCTUnwrap(fragmentLayout.cellUTF16Boundaries.firstIndex(of: NSNumber(value: spaceStart + 1)))
            let left = try XCTUnwrap(fragmentLayout.projection(atColumn: a)?.nativeEdge)
            let right = try XCTUnwrap(fragmentLayout.projection(atColumn: b)?.nativeEdge)
            let image = try renderedBitmap(text, row: row, name: "tmux-truecolor-header-uniform-\(uniform)")
            let scale = CGFloat(image.pixelsWide) / image.size.width
            let x = (CGFloat(iTermPreferences.sideMargins()) + piece.originX + (left.x + right.x) / 2) * scale
            let y = (CGFloat(piece.displayRow - pieces[0].displayRow) + 0.5) * text.lineHeight * scale
            let pixel = try XCTUnwrap(image.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB))
            // Truecolor bytes use the configured native color space, not necessarily sRGB.
            let sourceColor = iTermAdvancedSettingsModel.p3() ?
                NSColor(displayP3Red: 184.0 / 255, green: 134.0 / 255, blue: 11.0 / 255, alpha: 1) :
                NSColor(srgbRed: 184.0 / 255, green: 134.0 / 255, blue: 11.0 / 255, alpha: 1)
            let expectedColor = try XCTUnwrap(sourceColor.usingColorSpace(.sRGB))
            XCTAssertEqual(pixel.redComponent, expectedColor.redComponent, accuracy: 0.01)
            XCTAssertEqual(pixel.greenComponent, expectedColor.greenComponent, accuracy: 0.01)
            XCTAssertEqual(pixel.blueComponent, expectedColor.blueComponent, accuracy: 0.01)
        }
        // Actual tmux copy repaint: four NUL cells, then real padding spaces through column109.
        func paddedReplay(_ padded: Bool, header shown: Bool, caret: Bool) {
            feed("\u{1b}[0m\u{1b}[H\u{1b}[2K" + prefix +
                 (padded ? "\u{1b}[4C" + String(repeating: " ", count: 83) : "") +
                 (shown ? "\u{1b}[1;98H\u{1b}[38;2;13;13;13m\u{1b}[48;2;184;134;11m" + header : "") +
                 "\u{1b}[0m\u{1b}[1;\(caret ? 109 : 24)H", to: session)
            _ = text.refresh()
        }
        // Every short pair includes repaint padding, header, caret, viewport and exact-strip inspection.
        for first in 0..<5 {
            for second in 0..<5 {
                var padded = false, shown = false, caret = false, narrow = false, inspected = false
                text.selection.clear()
                view.setFrameSize(NSSize(width: 640, height: view.frame.height))
                paddedReplay(false, header: false, caret: false)
                for event in [first, second] {
                    switch event {
                    case 0: padded.toggle()
                    case 1: shown.toggle()
                    case 2: caret.toggle()
                    case 3:
                        narrow.toggle()
                        view.setFrameSize(NSSize(width: narrow ? 560 : 640, height: view.frame.height))
                    default: inspected.toggle()
                    }
                    paddedReplay(padded, header: shown, caret: caret)
                    if inspected { text.selectMalayalamColumn(108, absoluteRow: Int64(row) + Int64(session.screen.totalScrollbackOverflow())) }
                    else { text.selection.clear() }
                    _ = text.refresh()
                    let stored = session.screen.screenCharArray(forLine: row)
                    XCTAssertEqual((0..<23).map { ScreenCharToStr(stored.line.advanced(by: $0)) ?? "" }.joined(), prefix)
                    for column in 23..<27 { XCTAssertEqual(stored.line[column].code, 0) }
                    for column in 27..<(shown ? 97 : 110) { XCTAssertEqual(stored.line[column].code, padded ? 32 : 0) }
                    if shown {
                        XCTAssertEqual((97..<110).map { ScreenCharToStr(stored.line.advanced(by: $0)) ?? "" }.joined(), header)
                    }
                    XCTAssertEqual(session.screen.cursorX(), caret ? 109 : 24)
                    let layout = try XCTUnwrap(helper.malayalamLayout(atLine: row))
                    let map = try XCTUnwrap(helper.malayalamDisplayMap)
                    let pieces = map.fragments(forSourceRow: Int(row))
                    if !shown { XCTAssertEqual(pieces.count, 1, "plain blank suffix must not manufacture empty display rows") }
                    let width = view.scrollview.documentVisibleRect.width - 2 * CGFloat(iTermPreferences.sideMargins()) - 2
                    let cold = try XCTUnwrap(iTermMalayalamDisplayMap(rows: [NSNumber(value: row): layout],
                        rowCount: map.sourceRowCount, columns: 110, width: width))
                    XCTAssertEqual(pieces.map(\.sourceRange), cold.fragments(forSourceRow: Int(row)).map(\.sourceRange))
                    let focus = inspected || caret ? 108 : 23
                    let x = try XCTUnwrap(helper.malayalamX(forColumn: Int32(focus), line: row)).doubleValue
                    let piece = try XCTUnwrap(map.fragment(forColumn: focus, sourceRow: Int(row)))
                    let hit = try XCTUnwrap(helper.malayalamColumnFor(x: CGFloat(x), displayRow: Int32(piece.displayRow))).intValue
                    XCTAssertEqual(layout.cellUTF16Boundaries[hit], layout.cellUTF16Boundaries[focus], "inverse hit keeps the same native boundary; empty cells may share it")
                    if padded || shown { XCTAssertEqual(hit, focus) }
                    if !inspected && !caret {
                        let native = try XCTUnwrap(piece.layout?.projection(atColumn: focus - piece.firstColumn)?.nativeEdge)
                        XCTAssertEqual(x, Double(CGFloat(iTermPreferences.sideMargins()) + piece.originX + native.x), accuracy: 0.001,
                                       "clearing inspection restores unpanned text geometry")
                    }
                    XCTAssertGreaterThanOrEqual(x, Double(iTermPreferences.sideMargins()))
                    XCTAssertLessThanOrEqual(x, Double(view.scrollview.documentVisibleRect.width - CGFloat(iTermPreferences.sideMargins())))
                    if inspected {
                        let stripState = try XCTUnwrap(text.malayalamCellStripState())
                        XCTAssertEqual((stripState["focus"] as? NSNumber)?.intValue, 108)
                    }
                }
            }
        }
        text.selection.clear()
        view.setFrameSize(NSSize(width: 640, height: view.frame.height))
        // Uniform color still covers the retained suffix even when it no longer creates blank rows.
        feed("\u{1b}[0m\u{1b}[H\u{1b}[48;2;184;134;11m\u{1b}[2K" + prefix +
             "\u{1b}[4C" + String(repeating: " ", count: 83) + "\u{1b}[0m\u{1b}[1;24H", to: session)
        _ = text.refresh()
        XCTAssertEqual(helper.malayalamDisplayMap?.fragments(forSourceRow: Int(row)).count, 1)
        let paddingImage = try renderedBitmap(text, row: row, name: "tmux-plain-padding-uniform-color")
        let paddingScale = CGFloat(paddingImage.pixelsWide) / paddingImage.size.width
        let paddingX = try XCTUnwrap(helper.malayalamX(forColumn: 30, line: row)).doubleValue + 2
        let paddingPixel = try XCTUnwrap(paddingImage.colorAt(x: Int(paddingX * paddingScale),
            y: paddingImage.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let paddingColor = iTermAdvancedSettingsModel.p3() ?
            NSColor(displayP3Red: 184.0 / 255, green: 134.0 / 255, blue: 11.0 / 255, alpha: 1) :
            NSColor(srgbRed: 184.0 / 255, green: 134.0 / 255, blue: 11.0 / 255, alpha: 1)
        let expectedPaddingColor = try XCTUnwrap(paddingColor.usingColorSpace(.sRGB))
        XCTAssertEqual(paddingPixel.redComponent, expectedPaddingColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(paddingPixel.greenComponent, expectedPaddingColor.greenComponent, accuracy: 0.01)
        XCTAssertEqual(paddingPixel.blueComponent, expectedPaddingColor.blueComponent, accuracy: 0.01)
        for decoration in ["4", "48;2;184;134;11"] {
            feed("\u{1b}[0m\u{1b}[H\u{1b}[2K" + prefix + "\u{1b}[4C\u{1b}[\(decoration)m" +
                 String(repeating: " ", count: 83) + "\u{1b}[0m\u{1b}[1;24H", to: session)
            _ = text.refresh()
            XCTAssertGreaterThan(try XCTUnwrap(helper.malayalamDisplayMap).fragments(forSourceRow: Int(row)).count, 1,
                                 "visible underline or a distinct colored suffix stays flowing")
        }
        // A genuine background change inside a conjunct is still rejected.
        feed("\u{1b}[0m\u{1b}[H\u{1b}[2K\u{1b}[48;2;184;134;11mക്\u{1b}[49mഷ\u{1b}[0m", to: session)
        XCTAssertNil(helper.malayalamLayout(atLine: row))
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testReflowedIndexedPromptHistoryKeepsVisualWrap() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let saved = defaults.object(forKey: "MalayalamVisualWrap")
        defer {
            if let saved { defaults.set(saved, forKey: "MalayalamVisualWrap") }
            else { defaults.removeObject(forKey: "MalayalamVisualWrap") }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        defer {
            let drained = expectation(description: "history fixture refresh callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        defaults.set(true, forKey: "MalayalamVisualWrap")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 120)
        session.setSize(VT100GridSizeMake(211, 6))
        // Resize synchronizes the model color map into the view; initialize the model, not a stale helper map.
        session.screen.performBlock(joinedThreads: { _, state, _ in
            state.mutateColorMap { colors in
                colors.setColor(.white, forKey: Int32(kColorMapForeground))
                colors.setColor(.black, forKey: Int32(kColorMapSelection))
                colors.setColor(.green, forKey: Int32(kColorMapSelectedText))
                colors.setColor(.yellow, forKey: Int32(kColorMapMatch))
                colors.setColor(.black, forKey: Int32(kColorMapBackground))
                colors.setColor(.white, forKey: Int32(kColorMap8bitBase + 231))
                colors.setColor(.gray, forKey: Int32(kColorMap8bitBase + 246))
                colors.setColor(NSColor(srgbRed: 58.0 / 255, green: 58.0 / 255, blue: 58.0 / 255, alpha: 1),
                                forKey: Int32(kColorMap8bitBase + 237))
                colors.minimumContrast = 0
            }
        })
        session.sync()
        let helper = try XCTUnwrap(text.drawingHelper)
        helper.minimumContrast = 0
        helper.didFinishSetup()
        // Captured wide prompt row: 2 marker cells, 202 indexed-text cells, 7 blank cells.
        let prompt = "Without using tools, output exactly a Markdown H1 heading കേരളപ്പിറവി, then a blank line, then the phrase കേരനിരകളാടും ഹരിത repeated sixteen times separated by single spaces, then a new line WRAP-END. Do not add "
        feed("\u{1b}[48;5;237m\u{1b}[38;5;246m❯ \u{1b}[38;5;231m" + prompt +
             "\u{1b}[39m" + String(repeating: " ", count: 7) + "\u{1b}[0m", to: session)
        // The real client's erase saves the old grid into primary history before its repaint.
        feed("\u{1b}[2J\u{1b}[H\u{1b}[?1049h", to: session)
        session.setSize(VT100GridSizeMake(110, 6))
        let history = session.screen.numberOfScrollbackLines()
        XCTAssertGreaterThanOrEqual(history, 2)
        let row = try XCTUnwrap(session.screen.screenCharArray(forLine: 1))
        let suffix = "ടും ഹരിത repeated sixteen times separated by single spaces, then a new line WRAP-END. Do not add        "
        let prefix = (0..<101).map { ScreenCharToStr(row.line.advanced(by: $0)) ?? "" }.joined()
        XCTAssertEqual(Array(prefix.utf8), Array(suffix.utf8), "pin the captured historical row6 prefix")
        for column in 0..<101 {
            XCTAssertEqual(row.line[column].backgroundColorMode, UInt32(ColorModeNormal.rawValue))
            XCTAssertEqual(row.line[column].backgroundColor, 237)
        }
        for column in 101..<110 {
            XCTAssertEqual(row.line[column].code, 0)
        }
        let padding = (101..<110).map { column in
            "\(column):code=\(row.line[column].code),bgMode=\(row.line[column].backgroundColorMode),bg=\(row.line[column].backgroundColor)"
        }.joined(separator: "\n")
        let diagnostic = XCTAttachment(string: padding)
        diagnostic.name = "historical-prompt-padding"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        print("ML_HISTORY_PADDING " + padding.replacingOccurrences(of: "\n", with: ";"))
        feed("\u{1b}[H" + String(repeating: "കേ", count: 100), to: session)
        _ = text.refresh()
        XCTAssertEqual(session.screen.width(), 110)
        let afterRefresh = session.screen.screenCharArray(forLine: 1)
        XCTAssertEqual((0..<101).map { ScreenCharToStr(afterRefresh.line.advanced(by: $0)) ?? "" }.joined(), suffix)
        for column in 101..<110 {
            XCTAssertEqual(afterRefresh.line[column].code, 0)
            XCTAssertEqual(afterRefresh.line[column].backgroundColorMode, UInt32(ColorModeAlternate.rawValue))
            XCTAssertEqual(afterRefresh.line[column].backgroundColor, 0)
        }
        let prepared = helper.malayalamRowLayoutPreparationCount
        _ = text.refresh()
        XCTAssertEqual(helper.malayalamRowLayoutPreparationCount, prepared, "unchanged document refresh must skip attributed-row preparation")
        XCTAssertNotNil(helper.malayalamLayout(atLine: 1), "historical indexed content plus blank padding must retain shaping")
        let map = try XCTUnwrap(helper.malayalamDisplayMap, "a retained prompt must not disable live body wrapping")
        let fragments = map.fragments(forSourceRow: Int(history))
        XCTAssertGreaterThan(fragments.count, 1)
        for fragment in fragments {
            XCTAssertLessThanOrEqual(fragment.originX + (fragment.layout?.naturalWidth ?? 0),
                                     view.scrollview.documentVisibleRect.width, "each visible body piece must fit the viewport")
        }
        let historical = try XCTUnwrap(helper.malayalamLayout(atLine: 1))
        let historicalPieces = map.fragments(forSourceRow: 1)
        XCTAssertGreaterThan(historicalPieces.count, 1)
        let image = try renderedBitmap(text, row: 1, name: "reflowed-prompt-native-backgrounds")
        let pixelScale = CGFloat(image.pixelsWide) / image.size.width
        let contentX = Int(ceil((CGFloat(iTermPreferences.sideMargins()) + 4) * pixelScale))
        let gray = try XCTUnwrap(image.colorAt(x: contentX, y: 2)?.usingColorSpace(.sRGB))
        let black = try XCTUnwrap(image.colorAt(x: image.pixelsWide - 2, y: image.pixelsHigh - 2)?.usingColorSpace(.sRGB))
        for component in [gray.redComponent, gray.greenComponent, gray.blueComponent] {
            XCTAssertEqual(component, 58.0 / 255, accuracy: 0.01)
        }
        for component in [black.redComponent, black.greenComponent, black.blueComponent] {
            XCTAssertEqual(component, 0, accuracy: 0.01, "history padding keeps its default background")
        }
        XCTAssertEqual(historical.attributedString.string, suffix)
        let highlights = try XCTUnwrap(text.findOnPageHelper.value(forKey: "highlightMap") as? NSMutableDictionary)
        func checkCold(_ row: Int32) throws {
            let cold = try XCTUnwrap(text.perform(NSSelectorFromString("newDrawingHelperForOffscreenRendering"))?
                .takeRetainedValue() as? iTermTextDrawingHelper)
            cold.selection = helper.selection
            cold.useSelectedTextColor = helper.useSelectedTextColor
            cold.isFrontTextView = helper.isFrontTextView
            cold.unfocusedSelectionColor = helper.unfocusedSelectionColor
            cold.underlinedRange = helper.underlinedRange
            cold.minimumContrast = helper.minimumContrast
            cold.didFinishSetup()
            let expected = try XCTUnwrap(cold.malayalamLayout(atLine: row))
            let actual = try XCTUnwrap(helper.malayalamLayout(atLine: row))
            XCTAssertEqual(actual.attributedString, expected.attributedString, "warm and cold presentation agree")
            XCTAssertEqual(actual.cellUTF16Boundaries, expected.cellUTF16Boundaries)
        }
        func sourceRows(_ map: iTermMalayalamDisplayMap, shift: Int = 0) -> [NSNumber: iTermMalayalamRowLayout] {
            var rows = [NSNumber: iTermMalayalamRowLayout]()
            for row in 0..<map.sourceRowCount {
                if let layout = map.sourceLayout(forRow: row) { rows[NSNumber(value: row + shift)] = layout }
            }
            return rows
        }
        func checkGeometry(_ warm: iTermMalayalamDisplayMap, _ cold: iTermMalayalamDisplayMap) throws {
            XCTAssertEqual(warm.sourceRowCount, cold.sourceRowCount)
            XCTAssertEqual(warm.displayRowCount, cold.displayRowCount)
            XCTAssertEqual(warm.fragments.count, cold.fragments.count)
            for (a, b) in zip(warm.fragments, cold.fragments) {
                XCTAssertEqual(a.sourceRow, b.sourceRow)
                XCTAssertEqual(a.displayRow, b.displayRow)
                XCTAssertEqual(a.firstColumn, b.firstColumn)
                XCTAssertEqual(a.endColumn, b.endColumn)
                XCTAssertEqual(a.sourceRange, b.sourceRange)
                XCTAssertEqual(a.originX, b.originX, accuracy: 0.00001)
                XCTAssertEqual(a.oversizedCluster, b.oversizedCluster)
                XCTAssertEqual(a.layout?.cellUTF16Boundaries, b.layout?.cellUTF16Boundaries)
                if let left = a.layout, let right = b.layout {
                    XCTAssertEqual(left.attributedString, right.attributedString)
                    XCTAssertEqual(left.naturalWidth, right.naturalWidth, accuracy: 0.00001)
                    XCTAssertEqual(left.nativeEdges.map(\.x), right.nativeEdges.map(\.x))
                }
            }
        }
        // Model source-row movement without editing, clearing or identity-mapping the actual history.
        let width = max(1, view.scrollview.documentVisibleRect.width - 2 * CGFloat(iTermPreferences.sideMargins()) - 2)
        let shifted = try XCTUnwrap(iTermMalayalamDisplayMap(rows: sourceRows(map, shift: 1),
            rowCount: map.sourceRowCount + 1, columns: 110, width: width, previousMap: map))
        let shiftedCold = try XCTUnwrap(iTermMalayalamDisplayMap(rows: sourceRows(map, shift: 1),
            rowCount: map.sourceRowCount + 1, columns: 110, width: width))
        try checkGeometry(shifted, shiftedCold)
        for row in 0..<map.sourceRowCount where map.sourceLayout(forRow: row) != nil {
            for (old, moved) in zip(map.fragments(forSourceRow: row), shifted.fragments(forSourceRow: row + 1)) {
                XCTAssertTrue(old.layout === moved.layout, "moving history reuses immutable fragment geometry")
                XCTAssertFalse(old === moved, "coordinate-bearing fragment wrappers must be fresh")
                XCTAssertEqual(moved.sourceRow, old.sourceRow + 1)
                XCTAssertEqual(moved.displayRow, old.displayRow + 1)
            }
        }
        // Every short pair includes viewport/style and selection/find/hover apply-clear transitions.
        for first in 0..<5 {
            for second in 0..<5 {
                var narrow = false
                var indexed = false
                var selected = false
                var found = false
                var hovered = false
                for event in [first, second] {
                    let before = helper.malayalamRowLayoutPreparationCount
                    let beforeMap = try XCTUnwrap(helper.malayalamDisplayMap)
                    let absolute = Int64(session.screen.totalScrollbackOverflow()) + Int64(session.screen.numberOfScrollbackLines())
                    if event == 0 {
                        narrow.toggle()
                        view.setFrameSize(NSSize(width: narrow ? 360 : 640, height: view.frame.height))
                    } else if event == 1 {
                        indexed.toggle()
                        feed("\u{1b}[1;1H\u{1b}[" + (indexed ? "48;5;237" : "49") + "mകേ\u{1b}[0m", to: session)
                    } else if event == 2 {
                        selected.toggle()
                        if selected {
                            text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                                VT100GridAbsCoordRangeMake(0, absolute, 1, absolute), 0, 0), mode: .kiTermSelectionModeCharacter)
                        } else { text.selection.clear() }
                    } else if event == 3 {
                        found.toggle()
                        if found { highlights[NSNumber(value: absolute)] = Data([1]) }
                        else { highlights.removeAllObjects() }
                    } else {
                        hovered.toggle()
                        helper.underlinedRange = VT100GridAbsWindowedRangeMake(
                            VT100GridAbsCoordRangeMake(hovered ? 0 : -1, absolute, hovered ? 1 : -1, absolute), 0, 0)
                    }
                    _ = text.refresh()
                    XCTAssertEqual(helper.underlinedRange.coordRange.start.x, hovered ? 0 : -1,
                                   "refresh must preserve the deliberately configured hover state")
                    let activeOverlay = text.selection.hasSelection || highlights[NSNumber(value: absolute)] != nil || hovered
                    if event == 0 && !activeOverlay {
                        XCTAssertEqual(helper.malayalamRowLayoutPreparationCount, before, "viewport wrapping alone reuses source preparation")
                    }
                    if activeOverlay {
                        let count = helper.malayalamRowLayoutPreparationCount
                        _ = helper.malayalamLayout(atLine: session.screen.numberOfScrollbackLines())
                        XCTAssertGreaterThan(helper.malayalamRowLayoutPreparationCount, count, "active overlay bypasses the clean source cache")
                    }
                    try checkCold(session.screen.numberOfScrollbackLines())
                    XCTAssertEqual(session.screen.width(), 110, "viewport projection must not silently change this source-grid fixture")
                    let retained = session.screen.numberOfScrollbackLines()
                    let current = session.screen.screenCharArray(forLine: retained)
                    XCTAssertEqual(current.stringValueIncludingEmbeddedNulls, String(repeating: "കേ", count: 100))
                    XCTAssertEqual(current.line[0].backgroundColorMode,
                        UInt32(indexed ? ColorModeNormal.rawValue : ColorModeAlternate.rawValue))
                    let currentMap = try XCTUnwrap(helper.malayalamDisplayMap)
                    let wrapWidth = max(1, view.scrollview.documentVisibleRect.width - 2 * CGFloat(iTermPreferences.sideMargins()) - 2)
                    let coldMap = try XCTUnwrap(iTermMalayalamDisplayMap(rows: sourceRows(currentMap),
                        rowCount: currentMap.sourceRowCount, columns: 110, width: wrapWidth))
                    try checkGeometry(currentMap, coldMap)
                    if event != 0 && beforeMap !== currentMap {
                        let old = beforeMap.fragments(forSourceRow: 1)
                        let current = currentMap.fragments(forSourceRow: 1)
                        XCTAssertEqual(old.count, current.count)
                        for (a, b) in zip(old, current) {
                            XCTAssertTrue(a.layout === b.layout, "changed active rows must not rewrap unchanged history")
                        }
                    }
                    let pieces = currentMap.fragments(forSourceRow: Int(retained))
                    XCTAssertGreaterThan(pieces.count, 1)
                    for piece in pieces {
                        let shaped = try XCTUnwrap(piece.layout)
                        XCTAssertLessThanOrEqual(piece.originX + shaped.naturalWidth, view.scrollview.documentVisibleRect.width)
                    }
                    XCTAssertEqual(session.screen.screenCharArray(forLine: 1).stringValueIncludingEmbeddedNulls, suffix)
                }
                // Restore the starting state before the next two-event trace.
                text.selection.clear()
                highlights.removeAllObjects()
                helper.underlinedRange = VT100GridAbsWindowedRangeMake(VT100GridAbsCoordRangeMake(-1, 0, -1, 0), 0, 0)
                feed("\u{1b}[1;1H\u{1b}[49mകേ\u{1b}[0m", to: session)
                view.setFrameSize(NSSize(width: 640, height: view.frame.height))
                _ = text.refresh()
            }
        }
        for contrast in [0.5, 0.0] {
            let count = helper.malayalamRowLayoutPreparationCount
            helper.minimumContrast = contrast
            helper.didFinishSetup()
            _ = helper.malayalamLayout(atLine: session.screen.numberOfScrollbackLines())
            XCTAssertGreaterThan(helper.malayalamRowLayoutPreparationCount, count, "helper contrast is an independent build input")
            try checkCold(session.screen.numberOfScrollbackLines())
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testBoldAndItalicMalayalamKeepNaturalRows() async throws {
        let (session, view, text, _) = try fixture()
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
        // A terminal supplementary glyph must keep the same native endpoint contract as an internal one.
        for bold in [false, true] {
            for suffix in ["😄", "😄 END"] {
                let literal = "⏺ പിന്നെ, മറ്റൊരു കഥ! " + suffix
                let styled = "⏺ \u{1b}[\(bold ? 1 : 0)mപിന്നെ, മറ്റൊരു കഥ!\u{1b}[0m " + suffix
                feed("\u{1b}[0m\u{1b}[2J\u{1b}[H" + styled, to: session)
                let row = session.screen.numberOfScrollbackLines()
                let endColumn = Int(session.screen.cursorX() - 1)
                guard let layout = helper.malayalamLayout(atLine: row) else {
                    XCTFail("terminal emoji must remain natural: bold=\(bold), suffix UTF16=\(suffix.utf16.count)")
                    continue
                }
                XCTAssertEqual(layout.attributedString.string, literal)
                XCTAssertEqual(layout.cellUTF16Boundaries[endColumn].intValue, literal.utf16.count)
                let end = try XCTUnwrap(layout.projection(atColumn: endColumn))
                XCTAssertEqual(end.kind, .nativeEdge)
                XCTAssertNotNil(end.nativeEdge)
                XCTAssertEqual(session.screen.cursorY(), 1)
            }
        }
        // A dim quote marker must not disable wrapping for the other source rows.
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["MalayalamVisualWrap", "MalayalamParagraphFlow"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        session.setSize(VT100GridSizeMake(110, 6))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: view.compactFrame().height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
        let colors = try XCTUnwrap(helper.colorMap as? iTermColorMap)
        colors.setColor(.white, forKey: Int32(kColorMapForeground))
        colors.setColor(.black, forKey: Int32(kColorMapBackground))
        helper.minimumContrast = 0
        var normalQuoteColor: NSColor?
        for faint in [false, true] {
            for speaker in [false, true] {
                let literal = "  ▎ " + (speaker ? "🔊 " : "") + "മലയാളം വായിക്കാം"
                let styled = "  \u{1b}[\(faint ? 2 : 0)m▎\u{1b}[0m " +
                    "\u{1b}[3m" + (speaker ? "🔊 " : "") + "മലയാളം വായിക്കാം\u{1b}[0m"
                feed("\u{1b}[?1049h\u{1b}[0m\u{1b}[2J\u{1b}[H" + styled, to: session)
                let row = session.screen.numberOfScrollbackLines()
                let endColumn = Int(session.screen.cursorX() - 1)
                feed("\u{1b}[2;1H" + String(repeating: "മ", count: 90) + "\u{1b}[6;1H", to: session)
                let source = (0..<session.screen.numberOfLines()).map { session.screen.screenCharArray(forLine: $0).data }
                let cursor = (session.screen.cursorX(), session.screen.cursorY())
                _ = text.refresh()
                guard let layout = helper.malayalamLayout(atLine: row) else {
                    XCTFail("readout faint=\(faint), speaker=\(speaker) must retain natural shaping")
                    continue
                }
                XCTAssertEqual(layout.attributedString.string, literal)
                XCTAssertEqual(layout.cellUTF16Boundaries[endColumn].intValue, literal.utf16.count)
                XCTAssertEqual(try XCTUnwrap(layout.projection(atColumn: endColumn)).kind, .nativeEdge)
                let index = layout.cellUTF16Boundaries[2].intValue
                let quoteColor = try foregroundColor(layout, at: index)
                if faint {
                    XCTAssertNotEqual(quoteColor, normalQuoteColor, "faint must retain its distinct processed color")
                    let normal = try XCTUnwrap(normalQuoteColor)
                    XCTAssertLessThan(quoteColor.redComponent + quoteColor.greenComponent + quoteColor.blueComponent,
                                      normal.redComponent + normal.greenComponent + normal.blueComponent)
                } else { normalQuoteColor = quoteColor }
                let map = try XCTUnwrap(helper.malayalamDisplayMap, "one quote marker must not disable the document map")
                XCTAssertGreaterThan(map.fragments(forSourceRow: Int(row + 1)).count, 1)
                XCTAssertEqual((0..<session.screen.numberOfLines()).map { session.screen.screenCharArray(forLine: $0).data }, source)
                XCTAssertEqual(session.screen.cursorX(), cursor.0)
                XCTAssertEqual(session.screen.cursorY(), cursor.1)
            }
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { DispatchQueue.main.async { continuation.resume() } } }
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
        let font = try XCTUnwrap(layout.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let alias = try XCTUnwrap(iTermMalayalamRowLayout(
            attributedString: NSAttributedString(string: "😀C", attributes: [.font: font]),
            cellUTF16Boundaries: [0, 2, 2, 3]))
        let asciiStart = try XCTUnwrap(alias.projection(atColumn: 2)?.nativeEdge)
        let asciiEnd = try XCTUnwrap(alias.projection(atColumn: 3)?.nativeEdge)
        let owned = try XCTUnwrap(alias.hitTest(nativeX: asciiStart.x + (asciiEnd.x - asciiStart.x) * 0.8,
                                               reportingASCII: true))
        XCTAssertEqual(owned.logicalColumns.map(\.intValue), [2], "C owns its interval, not the preceding wide-cell alias")
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testVisibleFooterClickRestoresKeyboardFocusWithoutClientInput() throws {
        var sizingTabs = [PTYTab]()
        defer {
            withExtendedLifetime(sizingTabs) {
                let drained = expectation(description: "sizing fixture callbacks drained")
                DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
                wait(for: [drained], timeout: 5)
            }
            iTermUserDefaults.userDefaults().set(true, forKey: "MalayalamNaturalRows")
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
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
        let sizingProfile = try XCTUnwrap(session.profile)
        // The development ruler is restart-only and independent of natural text layout.
        let modes: [(Bool, Bool?)] = [(true, nil), (true, false), (true, true), (false, true)]
        for (natural, cellStrip) in modes {
            let defaults = iTermUserDefaults.userDefaults()
            defaults.set(natural, forKey: "MalayalamNaturalRows")
            if let cellStrip { defaults.set(cellStrip, forKey: "MalayalamCellStrip") }
            else { defaults.removeObject(forKey: "MalayalamCellStrip") }
            let enabled = natural && (cellStrip ?? false)
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            let sizingSession: FooterWriteCapturingSession
            let sizingView: SessionView
            let sizingText: PTYTextView
            if enabled {
                (sizingSession, sizingView, sizingText, _) = try fixture(initialText: "")
            } else {
                sizingSession = try XCTUnwrap(FooterWriteCapturingSession(synthetic: true))
                sessions.append(sizingSession)
                sizingSession.profile = sizingProfile
                let parent = iTermHeadlessWindowController(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
                parents.append(parent)
                sizingSession.setScreenSize(NSSize(width: 640, height: 300), parent: parent)
                sizingSession.setPreferencesFromAddressBookEntry(sizingProfile)
                sizingView = try XCTUnwrap(sizingSession.genericView as? SessionView)
                sizingText = try XCTUnwrap(sizingSession.textview)
            }
            let strip = sizingView.subviews.compactMap { $0 as? iTermMalayalamCellStrip }.first
            XCTAssertEqual(strip != nil, enabled, "normal sessions must not create the development ruler")
            XCTAssertEqual(sizingView.footerReservedHeight, enabled ? 28 : 0, "disabled ruler must reserve no space")
            let tab = try XCTUnwrap(PTYTab(session: sizingSession, parentWindow: nil))
            sizingTabs.append(tab)
            // Every short pair: requested grid, actual pixel resize, and pane-title reservation.
            for first in 0..<3 {
                for second in 0..<3 {
                    var rows: Int32 = 40
                    var expanded = false
                    var title = false
                    for event in [first, second] {
                        switch event {
                        case 0: rows = rows == 40 ? 24 : 40
                        case 1: expanded.toggle()
                        default: title.toggle()
                        }
                        _ = sizingView.setShowTitle(title, adjustScrollView: true)
                        sizingSession.setSize(VT100GridSizeMake(110, rows))
                        let inverse = tab.size()
                        XCTAssertEqual(inverse.height, sizingView.compactFrame().height, accuracy: 0.001,
                                       "tab and view must reserve the same real decorations")
                        sizingView.setFrameSize(NSSize(width: inverse.width,
                            height: inverse.height + (expanded ? 2 * sizingText.lineHeight : 0)))
                        sizingView.updateScrollFrame()
                        let actual = sizingView.scrollview.contentSize
                        let advertised = sizingView.maximumPossibleScrollContentSize()
                        XCTAssertEqual(advertised.width, actual.width, accuracy: 0.001)
                        XCTAssertEqual(advertised.height, actual.height, accuracy: 0.001,
                                       "model sizing must use the space actually left above the footer")
                        let physicalRows = Int32(floor((actual.height - 2 * CGFloat(iTermPreferences.topBottomMargins())) / sizingText.lineHeight))
                        XCTAssertEqual(physicalRows, rows + (expanded ? 2 : 0), "requested grid must survive the real frame round trip")
                        _ = tab.fitSession(toCurrentViewSize: sizingSession)
                        XCTAssertEqual(sizingSession.screen.height(), physicalRows, "real PTYTab resize must update the model to actual content capacity")
                        XCTAssertEqual(tab.size().height, sizingView.frame.height, accuracy: 0.001)
                        XCTAssertEqual(strip?.frame.height ?? 0, enabled ? 28 : 0)
                    }
                }
            }
            XCTAssertTrue(sizingSession.writes.isEmpty)
        }
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

    func testNativeMouseDispatchReportsWrappedButton() async throws {
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["MalayalamVisualWrap", "MalayalamParagraphFlow", "CopySelection"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        defaults.set(false, forKey: keys[2])
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        var profile = try XCTUnwrap(ProfileModel.sharedInstance().defaultBookmark())
        profile[KEY_NORMAL_FONT] = "Monaco 18"
        profile[KEY_NON_ASCII_FONT] = "NotoSansMalayalam-Regular 18"
        profile[KEY_USE_NONASCII_FONT] = true
        profile[KEY_XTERM_MOUSE_REPORTING] = true
        profile[KEY_XTERM_MOUSE_REPORTING_ALLOW_CLICKS_AND_DRAGS] = true
        let terminal = try XCTUnwrap(PseudoTerminal(smartLayout: false,
            windowType: iTermThemedWindowType(.WINDOW_TYPE_NORMAL), savedWindowType: .WINDOW_TYPE_NORMAL,
            percentage: iTermPercentage(width: 0, height: 0), screen: -1, profile: profile))
        let controller = try XCTUnwrap(iTermController.sharedInstance())
        mouseTerminal = terminal
        controller.addTerminalWindow(terminal)
        let session = try XCTUnwrap(FooterWriteCapturingSession(synthetic: false))
        sessions.append(session)
        session.profile = profile
        terminal.setupSession(session, with: nil)
        terminal.insert(session, at: 0)
        let window = try XCTUnwrap(terminal.window)
        let text = try XCTUnwrap(session.textview)
        controller.currentTerminal = terminal
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(text))
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let focused = NSPredicate { _, _ in
            NSApp.isActive && controller.frontTextView() === text && window.firstResponder === text
        }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 5)
        XCTAssertTrue(NSApp.isActive, "activation policy=\(NSApp.activationPolicy().rawValue)")
        guard NSApp.isActive else { return }
        XCTAssertTrue(controller.frontTextView() === text, "real registered terminal must own focus")
        XCTAssertTrue(window.firstResponder === text)
        session.setSize(VT100GridSizeMake(110, 39))
        session.wheelWritableTTY = true
        feed("\u{1b}[?1049h\u{1b}[?1003h\u{1b}[?1006h", to: session)
        for row in 1...35 {
            feed("\u{1b}[\(row);1H" + String(repeating: "മ", count: 90) + " ", to: session)
        }
        let buttonRow: Int32 = 34
        let column = session.screen.cursorX() - 1
        feed("CLICK\u{1b}[37;3H", to: session)
        _ = text.refresh()
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        (scroll.verticalScroller as? PTYScroller)?.userScroll = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
        let piece = try XCTUnwrap(map.fragment(forColumn: Int(column), sourceRow: Int(buttonRow)))
        XCTAssertGreaterThan(piece.displayRow, 0, "target must be on a wrapped fragment")
        let layout = try XCTUnwrap(piece.layout)
        let local = try XCTUnwrap(piece.localColumn(Int(column), sourceRow: Int(buttonRow))).intValue
        let left = CTLineGetOffsetForStringIndex(layout.line, layout.cellUTF16Boundaries[local].intValue, nil)
        let right = CTLineGetOffsetForStringIndex(layout.line, layout.cellUTF16Boundaries[local + 1].intValue, nil)
        var point = text.point(for: VT100GridCoordMake(column, buttonRow))
        point.x = CGFloat(iTermPreferences.sideMargins()) + piece.originX + (left + right) / 2
        point.y += text.lineHeight / 2
        var requested = scroll.contentView.bounds
        requested.origin = NSPoint(x: 0, y: max(0, point.y - requested.height / 2))
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(requested).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds, scroll.contentView.constrainBoundsRect(scroll.contentView.bounds),
                       "native mouse fixture must start within legal document bounds")
        point = text.point(for: VT100GridCoordMake(column, buttonRow))
        point.x = CGFloat(iTermPreferences.sideMargins()) + piece.originX + (left + right) / 2
        point.y += text.lineHeight / 2
        XCTAssertTrue(text.visibleRect.contains(point), "point=\(point), visible=\(text.visibleRect)")
        guard text.visibleRect.contains(point) else { return }
        let source = (0..<session.screen.numberOfLines()).map { session.screen.screenCharArray(forLine: $0).data }
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        session.writes.removeAll()
        MouseEventSynthesizer(window: window).click(at: text.convert(point, to: nil))
        XCTAssertEqual(session.writes.joined(), "\u{1b}[<0;\(column + 1);\(buttonRow + 1)M\u{1b}[<0;\(column + 1);\(buttonRow + 1)m")
        XCTAssertFalse(text.selection.hasSelection)
        XCTAssertEqual((0..<session.screen.numberOfLines()).map { session.screen.screenCharArray(forLine: $0).data }, source)
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { DispatchQueue.main.async { continuation.resume() } } }
    }

    func testNativeWheelOwnershipTracksProfileAndClientModes() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["ProportionalScrollWheelReporting": false,
            "DoubleReportScrollWheel": false, "AlternateMouseScrollStringForUp": "",
            "AlternateMouseScrollStringForDown": ""]
        // Restore the real preference values, not assumed machine defaults.
        let restoredKeys = Array(settings.keys) + ["CopySelection", "MalayalamVisualWrap", "MalayalamParagraphFlow"]
        let previous = Dictionary(uniqueKeysWithValues: restoredKeys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "queued margin work before fixture release")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in restoredKeys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 30)
        feed(String(repeating: "ചരിത്രം\r\n", count: 20) + "\u{1b}[?1049h\u{1b}[?1006h\u{1b}[Hമലയാളം", to: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        _ = text.refresh()
        let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_ALLOW_ALTERNATE_MOUSE_SCROLL] = false
        profile[KEY_AUTOMATICALLY_ENABLE_ALTERNATE_MOUSE_SCROLL] = false
        profile[KEY_RESTRICT_MOUSE_REPORTING_TO_ALTERNATE_SCREEN_MODE] = true
        enum Event: CaseIterable { case reporting, wheelAllowed, clientMode, writable, up, down }
        let events = Event.allCases
        let traces: [[Event]] = [[]] + events.map { [$0] } + events.flatMap { a in events.map { [a, $0] } }
        // Two starts include the observed broken profile and the corrected preview contract.
        for initialReporting in [false, true] {
            for trace in traces {
                var reporting = initialReporting, allowed = true, client = true, writable = true
                func apply() {
                    profile[KEY_XTERM_MOUSE_REPORTING] = reporting
                    profile[KEY_XTERM_MOUSE_REPORTING_ALLOW_MOUSE_WHEEL] = allowed
                    session.setPreferencesFromAddressBookEntry(profile)
                    session.wheelWritableTTY = writable
                    feed(client ? "\u{1b}[?1000h" : "\u{1b}[?1000l", to: session)
                }
                apply()
                text.scrollEnd()
                scroller.userScroll = false
                XCTAssertGreaterThanOrEqual(view.scrollview.documentVisibleRect.maxY,
                    try XCTUnwrap(view.scrollview.documentView).frame.maxY - 1)
                // Observe both directions after every settings pair, including pairs without a wheel.
                for event in trace + [.up, .down] {
                    switch event {
                    case .reporting: reporting.toggle(); apply()
                    case .wheelAllowed: allowed.toggle(); apply()
                    case .clientMode: client.toggle(); apply()
                    case .writable: writable.toggle(); apply()
                    case .up, .down:
                        let source = (0..<session.screen.numberOfLines()).map { row -> Data in
                            let line = session.screen.screenCharArray(forLine: row)
                            return Data(bytes: line.line, count: Int(session.screen.width()) * MemoryLayout<screen_char_t>.stride)
                        }
                        let cursor = (session.screen.cursorX(), session.screen.cursorY())
                        let clip = view.scrollview.contentView.bounds
                        session.writes.removeAll()
                        let live = NSRect(x: CGFloat(iTermPreferences.sideMargins()),
                            y: CGFloat(session.screen.numberOfScrollbackLines()) * text.lineHeight,
                            width: CGFloat(session.screen.width()) * text.charWidth,
                            height: CGFloat(session.screen.height()) * text.lineHeight)
                        let visibleLive = text.visibleRect.intersection(live)
                        XCTAssertFalse(visibleLive.isEmpty, "wheel must start over visible live terminal cells")
                        guard !visibleLive.isEmpty else { return }
                        let target = text.convert(NSPoint(x: visibleLive.midX, y: visibleLive.midY), to: nil)
                        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1, wheel1: event == .up ? 1 : -1, wheel2: 0, wheel3: 0))
                        cg.location = CGPoint(x: target.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - target.y)
                        let wheel = try XCTUnwrap(NSEvent(cgEvent: cg))
                        XCTAssertEqual(wheel.locationInWindow.x, target.x, accuracy: 0.5)
                        XCTAssertEqual(wheel.locationInWindow.y, target.y, accuracy: 0.5)
                        XCTAssertTrue(visibleLive.contains(text.convert(wheel.locationInWindow, from: nil)))
                        text.scrollWheel(with: wheel)
                        let clientOwns = reporting && allowed && client && writable
                        let context = "start reporting=\(initialReporting), events=\(trace)"
                        if clientOwns {
                            XCTAssertEqual(session.writes.count, 1, context)
                            let report = session.writes.joined()
                            XCTAssertTrue(report.hasPrefix(event == .up ? "\u{1b}[<64;" : "\u{1b}[<65;"), context + report.debugDescription)
                            XCTAssertTrue(report.hasSuffix("M"), context)
                            XCTAssertEqual(view.scrollview.contentView.bounds, clip, "client owner must not also scroll local clip: " + context)
                        } else { XCTAssertTrue(session.writes.isEmpty, context) }
                        XCTAssertEqual(session.screen.cursorX(), cursor.0)
                        XCTAssertEqual(session.screen.cursorY(), cursor.1)
                        for row in 0..<session.screen.numberOfLines() {
                            let line = session.screen.screenCharArray(forLine: row)
                            XCTAssertEqual(Data(bytes: line.line, count: Int(session.screen.width()) * MemoryLayout<screen_char_t>.stride), source[Int(row)], context)
                        }
                    }
                }
            }
        }
        // Client reports must name the source cell under the rendered button, not a visual fragment.
        defaults.set(false, forKey: "CopySelection")
        defaults.set(true, forKey: "MalayalamVisualWrap")
        defaults.set(false, forKey: "MalayalamParagraphFlow")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        profile[KEY_XTERM_MOUSE_REPORTING] = true
        profile[KEY_XTERM_MOUSE_REPORTING_ALLOW_CLICKS_AND_DRAGS] = true
        session.setPreferencesFromAddressBookEntry(profile)
        session.wheelWritableTTY = true
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(text))
        feed("\u{1b}[?1000h\u{1b}[?1006h\u{1b}[1;1H\u{1b}[2K" + String(repeating: "മ", count: 24) + " ", to: session)
        let buttonColumn = session.screen.cursorX() - 1
        feed("CLICK\u{1b}[2;3HASCII\u{1b}[6;1H", to: session)
        let buttonRow = session.screen.numberOfScrollbackLines()
        let mouseSource = (0..<session.screen.numberOfLines()).map { session.screen.screenCharArray(forLine: $0).data }
        let mouseCursor = (session.screen.cursorX(), session.screen.cursorY())
        var mouseNumber = 1000
        for (natural, width) in [(false, 640), (true, 180)] {
            defaults.set(natural, forKey: "MalayalamNaturalRows")
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            view.setFrameSize(NSSize(width: CGFloat(width), height: view.compactFrame().height))
            _ = text.refresh()
            var point = text.point(for: VT100GridCoordMake(buttonColumn, buttonRow))
            let next = text.point(for: VT100GridCoordMake(buttonColumn + 1, buttonRow))
            point.x = (point.x + next.x) / 2
            point.y += text.lineHeight / 2
            if natural {
                let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
                let piece = try XCTUnwrap(map.fragment(forColumn: Int(buttonColumn), sourceRow: Int(buttonRow)))
                let layout = try XCTUnwrap(piece.layout)
                let local = try XCTUnwrap(piece.localColumn(Int(buttonColumn), sourceRow: Int(buttonRow))).intValue
                let left = CTLineGetOffsetForStringIndex(layout.line, layout.cellUTF16Boundaries[local].intValue, nil)
                let right = CTLineGetOffsetForStringIndex(layout.line, layout.cellUTF16Boundaries[local + 1].intValue, nil)
                XCTAssertEqual(point.x, CGFloat(iTermPreferences.sideMargins()) + piece.originX + (left + right) / 2, accuracy: 0.01)
            }
            scroller.userScroll = true
            let clip = view.scrollview.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, point.y - 2 * text.lineHeight)))
            view.scrollview.reflectScrolledClipView(clip)
            XCTAssertGreaterThan(clip.bounds.minY, 0, "probe must include a genuinely scrolled viewport")
            point = text.point(for: VT100GridCoordMake(buttonColumn, buttonRow))
            let visibleNext = text.point(for: VT100GridCoordMake(buttonColumn + 1, buttonRow))
            point.x = (point.x + visibleNext.x) / 2
            point.y += text.lineHeight / 2
            XCTAssertTrue(text.visibleRect.contains(point))
            session.writes.removeAll()
            text.selection.clear()
            let reported = text.clientMouseCell(forViewPoint: point)
            XCTAssertEqual(reported.x, buttonColumn)
            XCTAssertEqual(reported.y, 0)
            var rightSide = point
            rightSide.x += (visibleNext.x - point.x) * 0.6
            XCTAssertEqual(text.clientMouseCell(forViewPoint: rightSide).x, buttonColumn,
                           "the right side of shaped ASCII C still belongs to C")
            var ascii = text.point(for: VT100GridCoordMake(2, buttonRow + 1))
            let asciiNext = text.point(for: VT100GridCoordMake(3, buttonRow + 1))
            ascii.x += (asciiNext.x - ascii.x) * 0.8
            ascii.y += text.lineHeight / 2
            XCTAssertTrue(text.visibleRect.contains(ascii))
            let asciiCell = text.clientMouseCell(forViewPoint: ascii)
            XCTAssertEqual(asciiCell.x, 2, "ASCII grid cells use containment, not selection rounding")
            XCTAssertEqual(asciiCell.y, 1)
            session.writes.removeAll()
            var end = text.point(for: VT100GridCoordMake(buttonColumn + 5, buttonRow))
            end.y += text.lineHeight / 2
            for (kind, target) in [(NSEvent.EventType.leftMouseDown, point), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: text.convert(target, to: nil),
                    modifierFlags: [.option], timestamp: Double(mouseNumber), windowNumber: window.windowNumber,
                    context: nil, eventNumber: mouseNumber, clickCount: 1, pressure: 1))
                mouseNumber += 1
                if kind == .leftMouseDown { text.mouseDown(with: event) }
                else if kind == .leftMouseDragged { text.mouseDragged(with: event) }
                else { text.mouseUp(with: event) }
            }
            XCTAssertEqual(text.selectedText, "CLICK", "Option-drag must use the displayed source cells")
            XCTAssertTrue(session.writes.isEmpty)
            XCTAssertEqual((0..<session.screen.numberOfLines()).map { session.screen.screenCharArray(forLine: $0).data }, mouseSource)
            XCTAssertEqual(session.screen.cursorX(), mouseCursor.0)
            XCTAssertEqual(session.screen.cursorY(), mouseCursor.1)
        }
        defaults.set(true, forKey: "MalayalamNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        // Clearing archived TUI frames must leave the inspected viewport inside the surviving grid.
        profile[KEY_SCROLLBACK_IN_ALTERNATE_SCREEN] = true
        session.setPreferencesFromAddressBookEntry(profile)
        let frame = (1...6).map { "\u{1b}[\($0);1H\u{1b}[5mമലയാളം FRAME \($0)\u{1b}[0m" }.joined()
        feed("\u{1b}[?1049h\u{1b}[2J" + frame + "\u{1b}[2J" + frame, to: session)
        _ = text.refresh()
        XCTAssertNotNil(text.drawingHelper.malayalamDisplayMap, "blink uses local grid fragments")
        XCTAssertNil(text.drawingHelper.malayalamLayout(atLine: session.screen.numberOfScrollbackLines()))
        let history = session.screen.numberOfScrollbackLines()
        XCTAssertGreaterThan(history, 6)
        let grid = (0..<6).map { session.screen.screenCharArray(forLine: history + $0).data }
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let clip = view.scrollview.contentView
        let document = try XCTUnwrap(view.scrollview.documentView)
        scroller.userScroll = true
        clip.scroll(to: NSPoint(x: 0, y: CGFloat(history - 4) * text.lineHeight))
        view.scrollview.reflectScrolledClipView(clip)
        XCTAssertGreaterThan(clip.bounds.minY, 6 * text.lineHeight)
        let before = "clip=\(clip.bounds), document=\(document.frame), text=\(text.frame), desired=\(text.desiredHeight)"
        session.writes.removeAll()
        session.clearScrollbackBuffer()
        let afterAction = "clip=\(clip.bounds), document=\(document.frame), text=\(text.frame), desired=\(text.desiredHeight)"
        let expectedHeight = max(clip.bounds.height, text.desiredHeight + CGFloat(iTermPreferences.topBottomMargins()))
        XCTAssertEqual(document.frame.height, expectedHeight, accuracy: 0.5,
                       "clear must complete its joined display refresh before returning")
        let geometry = XCTAttachment(string: "before: \(before)\nafter action: \(afterAction)")
        geometry.name = "clear-scrollback-viewport"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertEqual(session.screen.numberOfScrollbackLines(), 0)
        XCTAssertTrue(session.screen.showingAlternateScreen())
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertEqual((0..<6).map { session.screen.screenCharArray(forLine: $0).data }, grid)
        XCTAssertLessThanOrEqual(clip.bounds.minY, document.frame.minY + max(0, document.frame.height - clip.bounds.height) + 0.5,
                                 "cleared history cannot remain the visible scroll target")
        XCTAssertGreaterThan(clip.bounds.intersection(document.frame).height, 0)
        let survivingInspection = clip.bounds
        XCTAssertTrue(scroller.userScroll, "clamping must not cancel deliberate inspection")
        session.clearScrollbackBuffer()
        XCTAssertEqual(clip.bounds, survivingInspection, "a second clear with no history preserves valid inspection")
        XCTAssertTrue(scroller.userScroll)
        XCTAssertEqual((0..<6).map { session.screen.screenCharArray(forLine: $0).data }, grid)
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testNativeWheelRoundTripsThroughPrivateTmuxDocument() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ITERM2_MALAYALAM_SCROLL_LIVE"] == "1",
                          "Explicit opt-in installed-tmux roundtrip")
        let tmux = "/opt/homebrew/bin/tmux"
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tmux))
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("ml-wheel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let socket = root.appendingPathComponent("socket").path
        let config = root.appendingPathComponent("tmux.conf")
        try """
            set -s set-clipboard off
            set -g mouse on
            set -g status off
            set -g history-limit 1000
            bind -T copy-mode WheelUpPane send-keys -X -N 5 cursor-up
            bind -T copy-mode WheelDownPane send-keys -X -N 5 cursor-down
            """.write(to: config, atomically: true, encoding: .utf8)
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                           "SHELL": "/bin/bash", "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        let base = ["-u", "-S", socket, "-f", config.path]
        // Same Process/readback pattern as TmuxWorkgroupLiveHarness, but with a real PTY client.
        func control(_ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = base + args
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, args.joined(separator: " "))
            return String(decoding: data, as: UTF8.self)
        }
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["RunJobsInServers", "ProportionalScrollWheelReporting", "DoubleReportScrollWheel"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        for key in keys { defaults.set(false, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        defer {
            _ = try? control(["kill-server"])
            try? FileManager.default.removeItem(at: root)
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 100)
        session.forwardWritesToPTY = true
        defer {
            session.shell.delegate = nil
            session.shell.stop()
            let drained = expectation(description: "queued margin work before real fixture release")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_XTERM_MOUSE_REPORTING] = true
        profile[KEY_XTERM_MOUSE_REPORTING_ALLOW_MOUSE_WHEEL] = true
        profile[KEY_SCROLLBACK_IN_ALTERNATE_SCREEN] = false
        profile[KEY_ALLOW_ALTERNATE_MOUSE_SCROLL] = false
        profile[KEY_AUTOMATICALLY_ENABLE_ALTERNATE_MOUSE_SCROLL] = false
        session.profile = profile
        session.setPreferencesFromAddressBookEntry(profile)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        session.setSize(VT100GridSizeMake(60, 10))
        let expected = (1...60).map { String(format: "ROW%03d മലയാളം", $0) }
        func active() -> String {
            let first = session.screen.numberOfScrollbackLines()
            return (first..<(first + session.screen.height())).map {
                session.screen.screenCharArray(forLine: $0).stringValue
            }.joined(separator: "\n")
        }
        func observed(_ label: String, _ predicate: @escaping () -> Bool) {
            let ready = expectation(for: NSPredicate { _, _ in predicate() }, evaluatedWith: nil)
            wait(for: [ready], timeout: 10)
            XCTAssertTrue(predicate(), label)
        }
        let program = "for ((i=1;i<=60;i++)); do printf 'ROW%03d മലയാളം' \"$i\"; ((i==60)) || printf '\\r\\n'; done; exec /bin/cat"
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let pane = "/bin/bash --noprofile --norc -c " + quote(program)
        let launched = expectation(description: "private PTY tmux client launched")
        session.shell.launch(withPath: "/usr/bin/env", arguments: ["-i"] + environment.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value } +
            [tmux] + base + ["new-session", "-s", "document", pane], environment: environment,
            customShell: nil, gridSize: VT100GridSizeMake(60, 10), viewSize: view.frame.size,
            maybeScaleFactor: 1, isUTF8: true) { launched.fulfill() }
        wait(for: [launched], timeout: 10)
        observed("real child output parsed") { active().contains("ROW060") }
        XCTAssertGreaterThan(session.shell.pid, 0)
        XCTAssertTrue(session.textViewCanWriteToTTY(), "use real task writability, not the test override")
        _ = try control(["copy-mode", "-t", "document:0.0"])
        _ = try control(["send-keys", "-t", "document:0.0", "-X", "history-top"])
        observed("copy view starts at document top") { active().contains("ROW001") }
        func canonical() throws {
            let rows = try control(["capture-pane", "-p", "-J", "-S", "-", "-t", "document:0.0"])
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            XCTAssertEqual(rows, expected)
        }
        func wheel(up: Bool, pixel: Bool = false, expectedReport: Bool = true) throws {
            _ = text.refresh()
            let live = NSRect(x: CGFloat(iTermPreferences.sideMargins()),
                y: CGFloat(session.screen.numberOfScrollbackLines()) * text.lineHeight,
                width: CGFloat(session.screen.width()) * text.charWidth,
                height: CGFloat(session.screen.height()) * text.lineHeight)
            let visible = text.visibleRect.intersection(live)
            XCTAssertFalse(visible.isEmpty)
            guard !visible.isEmpty else { return }
            let point = text.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: pixel ? .pixel : .line,
                wheelCount: 1, wheel1: up ? (pixel ? 27 : 1) : (pixel ? -27 : -1), wheel2: 0, wheel3: 0))
            cg.flags = [] // This fixture sends plain wheel input, independent of ambient keyboard state.
            cg.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertTrue(event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty)
            XCTAssertTrue(visible.contains(text.convert(event.locationInWindow, from: nil)))
            let clip = view.scrollview.contentView.bounds
            session.writes.removeAll()
            text.scrollWheel(with: event)
            XCTAssertEqual(session.writes.count, expectedReport ? 1 : 0, "native event obeys the actual profile gate")
            if expectedReport {
                let report = try XCTUnwrap(session.writes.first)
                XCTAssertEqual(report.components(separatedBy: ";").first, "\u{1b}[<\(up ? 64 : 65)",
                               "plain wheel must emit the unmodified SGR button code")
                XCTAssertEqual(view.scrollview.contentView.bounds, clip, "client owns the immediate event")
            }
        }
        try canonical()
        let copyState = ["display", "-p", "-t", "document:0.0", "#{copy_cursor_x},#{copy_cursor_y},#{scroll_position}"]
        let beforeBlocked = try control(copyState)
        let sourceBeforeBlocked = active()
        profile[KEY_XTERM_MOUSE_REPORTING] = false
        session.profile = profile
        session.setPreferencesFromAddressBookEntry(profile)
        try wheel(up: false, expectedReport: false)
        XCTAssertEqual(try control(copyState), beforeBlocked, "observed bad profile cannot move the real tmux document")
        XCTAssertEqual(active(), sourceBeforeBlocked)
        try canonical()
        profile[KEY_XTERM_MOUSE_REPORTING] = true
        session.profile = profile
        session.setPreferencesFromAddressBookEntry(profile)
        for _ in 0..<14 { try wheel(up: false) }
        observed("native down reaches actual document bottom") { active().contains("ROW060") && !active().contains("ROW001") }
        XCTAssertTrue(try control(["display", "-p", "-t", "document:0.0", "#{pane_in_mode}"]).hasPrefix("1"))
        try canonical()
        for (columns, rows) in [(60, 6), (80, 12), (60, 10)] {
            session.setSize(VT100GridSizeMake(Int32(columns), Int32(rows)))
            observed("actual PTY resize acknowledged") {
                (try? control(["display", "-p", "-t", "document:0.0", "#{pane_width}x#{pane_height}"])) == "\(columns)x\(rows)\n"
            }
            try canonical()
        }
        for _ in 0..<14 { try wheel(up: true) }
        observed("native up returns actual document top") { active().contains("ROW001") && !active().contains("ROW060") }
        // A pixel scroll uses the same native conversion path, not a prebuilt mouse report.
        let beforePixel = session.screen.cursorY()
        try wheel(up: false, pixel: true)
        observed("pixel down moves actual client copy cursor") { session.screen.cursorY() != beforePixel }
        for _ in 0..<2 { try wheel(up: true) }
        observed("native top restored after pixel leg") { active().contains("ROW001") }
        try canonical()
        let image = try XCTUnwrap(text.renderImage(withLines: NSRange(location: Int(session.screen.numberOfScrollbackLines()),
            length: Int(session.screen.height())), includeMargins: true, backgroundColor: .black,
            showCursor: true, includeSelection: false))
        let attachment = XCTAttachment(image: image)
        attachment.name = "native-PTY-document-top"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private func prefixes(_ events: [Int], depth: Int, eventCount: Int = 4,
                          check: ([Int]) throws -> Void) throws {
        try check(events)
        if depth > 0 {
            for event in 0..<eventCount {
                try prefixes(events + [event], depth: depth - 1, eventCount: eventCount, check: check)
            }
        }
    }

    func testAlternateScreenVisualWrapAddsPresentationHeightWithoutChangingSource() throws {
        defer {
            // Margin-color updates are queued by refresh. Finish them before releasing their source fixtures.
            let drained = expectation(description: "fixture refresh callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        let defaults = iTermUserDefaults.userDefaults()
        let saved = defaults.object(forKey: "MalayalamVisualWrap")
        addTeardownBlock {
            if let saved { defaults.set(saved, forKey: "MalayalamVisualWrap") }
            else { defaults.removeObject(forKey: "MalayalamVisualWrap") }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        defaults.set(false, forKey: "MalayalamVisualWrap")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "")
        feed("\u{1b}[?1049h\u{1b}[2J\u{1b}[H" + String(repeating: "കേ", count: 39) + "\r\nASCII\r\n", to: session)
        XCTAssertTrue(session.screen.showingAlternateScreen())
        XCTAssertEqual(session.screen.numberOfScrollbackLines(), 0)
        let first = try XCTUnwrap(session.screen.screenCharArray(forLine: 0)).stringValue
        let second = try XCTUnwrap(session.screen.screenCharArray(forLine: 1)).stringValue
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let sourceLines = session.screen.numberOfLines()
        let sourceWidth = session.screen.width()
        let layout = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0))
        XCTAssertGreaterThan(layout.naturalWidth, view.scrollview.contentSize.width,
                             "fixture must genuinely overflow the real viewport without client wrapping")
        let unwrappedHeight = text.desiredHeight
        let boxCursor = try XCTUnwrap(ITermCursorType(rawValue: 2)) // Existing CURSOR_BOX enum value.
        let baselineHelper = try XCTUnwrap(text.drawingHelper)
        baselineHelper.cursorType = boxCursor
        baselineHelper.cursorCoord = VT100GridCoordMake(0, 1) // ASCII row, not the Malayalam native caret.
        let ordinaryCursor = baselineHelper.cursorFrameForSolidRectangle
        defaults.set(true, forKey: "MalayalamVisualWrap")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        _ = text.refresh()
        XCTAssertGreaterThan(text.desiredHeight, unwrappedHeight,
                             "alternate-screen visual fragments must reserve height before the following ASCII row")
        XCTAssertEqual(try XCTUnwrap(session.screen.screenCharArray(forLine: 0)).stringValue, first)
        XCTAssertEqual(try XCTUnwrap(session.screen.screenCharArray(forLine: 1)).stringValue, second)
        XCTAssertEqual(session.screen.numberOfLines(), sourceLines)
        XCTAssertEqual(session.screen.width(), sourceWidth)
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)

        // Every short prefix of width, addressed redraw, rollout mode and screen transitions.
        // These are native geometry/source checks, not physical mouse-input proof.
        func check(_ events: [Int]) throws {
            // CSI 2 J does not reset terminal history. Independent prefixes need independent terminals.
            defaults.set(false, forKey: "MalayalamVisualWrap")
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            let (session, view, text, _) = try fixture(initialText: "")
            feed("\u{1b}[?1049h\u{1b}[2J\u{1b}[H" + String(repeating: "കേ", count: 39) + "\r\nASCII\r\n", to: session)
            let unwrappedHeight = text.desiredHeight
            XCTAssertEqual(session.screen.numberOfScrollbackLines(), 0, "fresh prefix fixture: \(events)")
            var enabled = true
            var narrow = false
            var short = false
            var alternate = true
            defaults.set(true, forKey: "MalayalamVisualWrap")
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            for (index, event) in events.enumerated() {
                let trace = "event prefix \(Array(events.prefix(index + 1)))"
                switch event {
                case 0:
                    narrow.toggle()
                    view.setFrameSize(NSSize(width: narrow ? 360 : 640, height: view.frame.height))
                case 1:
                    short.toggle()
                    // Real CUP/EL repaint replaces a source row without inserting a protocol line.
                    feed("\u{1b}[1;1H\u{1b}[2K" + String(repeating: "കേ", count: short ? 3 : 39) +
                         "\u{1b}[2;1HASCII\u{1b}[K\u{1b}[3;1H", to: session)
                case 2:
                    enabled.toggle()
                    defaults.set(enabled, forKey: "MalayalamVisualWrap")
                    iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
                default:
                    alternate.toggle()
                    feed(alternate ? "\u{1b}[?1049h" : "\u{1b}[?1049l", to: session)
                    feed("\u{1b}[2J\u{1b}[H" + String(repeating: "കേ", count: short ? 3 : 39) + "\r\nASCII\r\n", to: session)
                }
                _ = text.refresh()
                let helper = try XCTUnwrap(text.drawingHelper)
                let source = try XCTUnwrap(session.screen.screenCharArray(forLine: 0)).stringValue
                let following = try XCTUnwrap(session.screen.screenCharArray(forLine: 1)).stringValue
                XCTAssertEqual(source.replacingOccurrences(of: "\0", with: ""), String(repeating: "കേ", count: short ? 3 : 39), trace)
                XCTAssertEqual(following.replacingOccurrences(of: "\0", with: ""), "ASCII", trace)
                XCTAssertEqual(session.screen.cursorX(), 1, trace)
                XCTAssertEqual(session.screen.cursorY(), 3, trace)
                XCTAssertEqual(session.screen.numberOfScrollbackLines(), 0, trace)
                XCTAssertEqual(session.screen.width(), sourceWidth, trace)
                XCTAssertEqual(session.screen.numberOfLines(), sourceLines, trace)
                if enabled && alternate {
                    let map = try XCTUnwrap(helper.malayalamDisplayMap, "enabled alternate-grid mapping: \(trace)")
                    let pieces = map.fragments(forSourceRow: 0)
                    XCTAssertFalse(pieces.isEmpty)
                    XCTAssertEqual(map.firstDisplayRow(forSourceRow: 1), pieces.count)
                    if !short { XCTAssertGreaterThan(pieces.count, 1) }
                    let layout = try XCTUnwrap(helper.malayalamLayout(atLine: 0))
                    let recovered = pieces.map { layout.attributedString.attributedSubstring(from: $0.sourceRange).string }.joined()
                    XCTAssertEqual(recovered, layout.attributedString.string, "visual breaks must not insert source newlines")
                    for fragment in pieces {
                        let piece = try XCTUnwrap(fragment.layout)
                        let ink = CTLineGetBoundsWithOptions(piece.line, .useGlyphPathBounds)
                        let occupied = fragment.originX + max(piece.naturalWidth, ink.isNull ? 0 : ink.maxX)
                        let available = view.scrollview.documentVisibleRect.width - 2 * CGFloat(iTermPreferences.sideMargins()) - 2
                        if fragment.oversizedCluster {
                            XCTAssertGreaterThan(occupied, available)
                            let interior = (fragment.firstColumn + 1..<fragment.endColumn).contains {
                                guard let position = layout.projection(atColumn: $0) else { return false }
                                return position.kind == .nativeEdge && position.utf16Index > fragment.sourceRange.location &&
                                    position.utf16Index < NSMaxRange(fragment.sourceRange)
                            }
                            XCTAssertFalse(interior, "only one indivisible native interval may overflow")
                        } else {
                            XCTAssertLessThanOrEqual(occupied, available + 0.000001)
                        }
                        for column in fragment.firstColumn..<fragment.endColumn {
                            guard let edge = piece.projection(atColumn: column - fragment.firstColumn)?.nativeEdge else { continue }
                            let x = CGFloat(iTermPreferences.sideMargins()) + fragment.originX + edge.x
                            let hit = try XCTUnwrap(helper.malayalamColumnFor(x: x, displayRow: Int32(fragment.displayRow)))
                            let candidate = Int(hit.intValue) - fragment.firstColumn
                            XCTAssertTrue(try XCTUnwrap(piece.hitTest(nativeX: edge.x)).logicalColumns.contains(NSNumber(value: candidate)))
                        }
                    }
                    // Exact source ownership spans fragments; selected extraction has no visual newline.
                    text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                        VT100GridAbsCoordRangeMake(0, 0, short ? 3 : 39, 0), 0, 0), mode: .kiTermSelectionModeCharacter)
                    XCTAssertEqual(text.selectedText, String(repeating: "കേ", count: short ? 3 : 39))
                    var partial = ObjCBool(false)
                    let rects = try XCTUnwrap(helper.malayalamSelectionRects(NSRange(location: 0, length: short ? 3 : 39),
                        layout: layout, line: 0, partial: &partial))
                    XCTAssertFalse(partial.boolValue)
                    XCTAssertEqual(rects.count, pieces.count)
                    text.selection.clear()
                    let image = try XCTUnwrap(text.renderLines(toImage: NSRange(location: 0, length: 2)))
                    XCTAssertEqual(image.size.height, CGFloat(map.firstDisplayRow(forSourceRow: 2)) * text.lineHeight)
                    XCTAssertEqual(text.superview?.frame.height, text.frame.height + CGFloat(iTermPreferences.topBottomMargins()), "production wrapper follows presentation height")
                    let originalType = helper.cursorType
                    let originalCoord = helper.cursorCoord
                    helper.cursorType = boxCursor
                    helper.cursorCoord = VT100GridCoordMake(0, 1)
                    let shiftedCursor = helper.cursorFrameForSolidRectangle
                    XCTAssertEqual(shiftedCursor.width, ordinaryCursor.width, "ASCII keeps the configured box cursor")
                    XCTAssertEqual(shiftedCursor.height, ordinaryCursor.height)
                    XCTAssertEqual(shiftedCursor.origin.y - ordinaryCursor.origin.y,
                        CGFloat(map.firstDisplayRow(forSourceRow: 1) - 1) * text.lineHeight)
                    helper.cursorType = originalType
                    helper.cursorCoord = originalCoord
                } else {
                    XCTAssertNil(helper.malayalamDisplayMap)
                    XCTAssertEqual(text.desiredHeight, unwrappedHeight, trace)
                }
                XCTAssertTrue(session.writes.isEmpty)
            }
        }
        try prefixes([], depth: 2, check: check)
        try check([0, 1, 0]) // width restore after a client repaint
        try check([2, 1, 2]) // reenable after a client repaint must not retain stale fragments

        // Retained primary history is part of the same document as the alternate grid.
        func checkHistory(_ events: [Int]) throws {
            defaults.set(true, forKey: "MalayalamVisualWrap")
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 8)
            XCTAssertEqual(session.screen.width(), 40)
            XCTAssertEqual(session.screen.height(), 6)
            let sample = String(repeating: "കേ", count: 39)
            feed(String(repeating: sample + "\r\n", count: 14), to: session)
            feed("\u{1b}[?1049h\u{1b}[2J\u{1b}[H" + sample + "\r\nASCII\u{1b}[6;1H", to: session)
            _ = text.refresh()
            let retained = session.screen.numberOfScrollbackLines()
            XCTAssertEqual(retained, 8, "fourteen unwrapped source rows must fill the eight-row history limit")
            let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
            let clip = view.scrollview.contentView
            var narrow = false
            var gappedStyle = false
            var editedASCII = false
            var fontSize = 20
            var inspect = false
            var inspectedRow = Int(retained) - 1
            var inspectedColumn = 0
            for event in [-1] + events {
                let beforeOverflow = session.screen.totalScrollbackOverflow()
                let previousMap = text.drawingHelper.malayalamDisplayMap
                switch event {
                case 0:
                    narrow.toggle()
                    view.setFrameSize(NSSize(width: narrow ? 360 : 640, height: view.frame.height))
                case 1:
                    gappedStyle.toggle()
                    // Interior NUL cells, changed source boundaries and synthesized style must all miss stale geometry.
                    let row = gappedStyle ? "\u{1b}[1;3H\u{1b}[1;3m" + String(repeating: "കേ", count: 37) :
                        "\u{1b}[1;1H\u{1b}[0m" + sample
                    feed("\u{1b}[1;1H\u{1b}[2K" + row + "\u{1b}[0m\u{1b}[6;1H", to: session)
                case 2:
                    feed("\u{1b}[?1049l", to: session)
                    _ = text.refresh()
                    XCTAssertNil(text.drawingHelper.malayalamDisplayMap)
                    feed("\u{1b}[?1049h\u{1b}[2J\u{1b}[H" + sample + "\r\nASCII\u{1b}[6;1H", to: session)
                    gappedStyle = false
                    editedASCII = false
                    inspect = false
                    scroller.userScroll = false
                case 3:
                    // Inspect a surviving history cell while one older wrapped source row is evicted.
                    let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
                    let fragment = try XCTUnwrap(map.fragments(forSourceRow: Int(retained) - 1).last)
                    inspectedRow = fragment.sourceRow
                    inspectedColumn = fragment.firstColumn
                    inspect = true
                    scroller.userScroll = true
                    clip.scroll(to: NSPoint(x: 0, y: CGFloat(fragment.displayRow) * text.lineHeight))
                    view.scrollview.reflectScrolledClipView(clip)
                    feed("\u{1b}[?1049l\u{1b}[6;1H\r\n\u{1b}[?47h", to: session)
                case 4:
                    fontSize = fontSize == 20 ? 22 : 20
                    var profile = try XCTUnwrap(session.profile)
                    profile[KEY_NORMAL_FONT] = "Monaco \(fontSize)"
                    profile[KEY_NON_ASCII_FONT] = "NotoSansMalayalam-Regular \(fontSize)"
                    text.setFontTable(FontTable.fontTable(forProfile: profile), horizontalSpacing: 1, verticalSpacing: 1)
                default: break
                }
                let overflow = session.screen.totalScrollbackOverflow() - beforeOverflow
                if event == 3 {
                    XCTAssertEqual(overflow, 1, "one primary source row must actually be evicted: \(events)")
                    inspectedRow -= Int(overflow)
                    // API sync leaves overflow pending; the following normal refresh sees it again.
                    session.sync()
                    let syncedMap = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
                    let syncedAnchor = try XCTUnwrap(syncedMap.fragment(forColumn: inspectedColumn, sourceRow: inspectedRow))
                    XCTAssertEqual(clip.bounds.minY, CGFloat(syncedAnchor.displayRow) * text.lineHeight)
                }
                let rowsBefore = (0..<session.screen.numberOfLines()).map {
                    session.screen.screenCharArray(forLine: $0).stringValue
                }
                let cursorBefore = (session.screen.cursorX(), session.screen.cursorY())
                _ = text.refresh()
                let helper = try XCTUnwrap(text.drawingHelper)
                let map = try XCTUnwrap(helper.malayalamDisplayMap, "history must not disable mapping: \(events)")
                if [0, 1, 4].contains(event) {
                    XCTAssertFalse(map === previousMap, "viewport, content/style/boundaries or fonts must invalidate geometry")
                }
                let rowBuilds = helper.malayalamRowLayoutBuildCount
                _ = text.refresh()
                XCTAssertTrue(text.drawingHelper.malayalamDisplayMap === map,
                              "unchanged source and viewport reuse mapped geometry: \(events)")
                XCTAssertEqual(helper.malayalamRowLayoutBuildCount, rowBuilds,
                               "unchanged refresh must not shape replacement source rows: \(events)")
                let history = Int(session.screen.numberOfScrollbackLines())
                XCTAssertEqual(history, Int(retained))
                XCTAssertEqual(session.screen.width(), 40, "view reflow must not change the client grid")
                XCTAssertEqual(session.screen.height(), 6)
                XCTAssertEqual(map.sourceRowCount, rowsBefore.count)
                XCTAssertGreaterThan(map.fragments(forSourceRow: 0).count, 1, "Malayalam history wraps naturally")
                XCTAssertGreaterThan(map.fragments(forSourceRow: history).count, 1, "alternate grid also wraps")
                XCTAssertEqual((0..<session.screen.numberOfLines()).map {
                    session.screen.screenCharArray(forLine: $0).stringValue
                }, rowsBefore, "mapping must preserve all source history and active rows")
                XCTAssertEqual(session.screen.cursorX(), cursorBefore.0)
                XCTAssertEqual(session.screen.cursorY(), cursorBefore.1)
                let cursor = helper.cursorFrameForSolidRectangle
                let cursorRow = history + Int(cursorBefore.1) - 1
                XCTAssertEqual(cursor.minY, CGFloat(map.firstDisplayRow(forSourceRow: cursorRow)) * text.lineHeight)
                if inspect {
                    let anchor = try XCTUnwrap(map.fragment(forColumn: inspectedColumn, sourceRow: inspectedRow))
                    XCTAssertEqual(clip.bounds.minY, CGFloat(anchor.displayRow) * text.lineHeight,
                                   "history eviction and resize preserve the same surviving source cell exactly once")
                } else {
                    let viewport = text.textDrawingHelperVisibleRectExcludingTopMargin()
                    XCTAssertGreaterThanOrEqual(cursor.minY, viewport.minY)
                    XCTAssertLessThanOrEqual(cursor.maxY, viewport.maxY)
                }
                let historyLayout = try XCTUnwrap(helper.malayalamLayout(atLine: 0))
                let recovered = map.fragments(forSourceRow: 0).map {
                    historyLayout.attributedString.attributedSubstring(from: $0.sourceRange).string
                }.joined()
                XCTAssertEqual(recovered, historyLayout.attributedString.string)
                var duplicateBoundaryChecked = false
                for fragment in map.fragments(forSourceRow: history) {
                    let piece = try XCTUnwrap(fragment.layout)
                    for edge in piece.nativeEdges {
                        guard let hit = piece.hitTest(nativeX: edge.x), !hit.logicalColumns.isEmpty else { continue }
                        duplicateBoundaryChecked = duplicateBoundaryChecked || hit.logicalColumns.count > 1
                        let column = fragment.firstColumn + (try XCTUnwrap(hit.logicalColumns.last)).intValue
                        let savedCursor = helper.cursorCoord
                        helper.cursorCoord = VT100GridCoordMake(Int32(column), 0)
                        let actual = helper.malayalamColumnFor(x: CGFloat(iTermPreferences.sideMargins()) + fragment.originX + edge.x,
                                                              displayRow: Int32(fragment.displayRow))
                        XCTAssertEqual(actual?.intValue, column, "duplicate hit boundaries preserve the active grid cursor with history")
                        helper.cursorCoord = savedCursor
                    }
                }
                XCTAssertTrue(duplicateBoundaryChecked, "blank continuation cells must exercise cursor-hit affinity")
                let image = try XCTUnwrap(text.renderLines(toImage: NSRange(location: 0, length: history + 1)))
                XCTAssertEqual(image.size.height, CGFloat(map.firstDisplayRow(forSourceRow: history + 1)) * text.lineHeight)
                text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                    VT100GridAbsCoordRangeMake(0, session.screen.totalScrollbackOverflow(), 39,
                                              session.screen.totalScrollbackOverflow()), 0, 0), mode: .kiTermSelectionModeCharacter)
                XCTAssertEqual(text.selectedText, sample, "copy retains source text without visual newlines")
                text.selection.clear()
                session.redrawRects.removeAll()
                editedASCII.toggle()
                feed("\u{1b}[2;1H" + (editedASCII ? "EDIT!" : "ASCII") + "\u{1b}[6;1H", to: session)
                _ = text.refresh()
                XCTAssertTrue(text.drawingHelper.malayalamDisplayMap === map, "ASCII repaint does not rebuild Malayalam geometry")
                XCTAssertFalse(session.redrawRects.isEmpty, "same-map ASCII edits still reach the real redraw delegate")
                XCTAssertTrue(session.writes.isEmpty)
            }
        }
        try prefixes([], depth: 2, eventCount: 5, check: checkHistory)
        try checkHistory([3, 0, 1])
        try checkHistory([0, 3, 0])
        try checkHistory([1, 2, 1])
        try checkHistory([4, 0, 4])
        try checkHistory([3, 4, 4])

        // A correct native caret rectangle must also remain inside the rendered viewport after CUP.
        let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
        scroller.userScroll = false
        defaults.set(true, forKey: "MalayalamVisualWrap")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        view.setFrameSize(NSSize(width: 130, height: view.frame.height))
        feed("\u{1b}[?1049h\u{1b}[2J\u{1b}[H" + String(repeating: "കേ", count: 39) + "\r\nASCII\r\n", to: session)
        _ = text.refresh()
        feed("\u{1b}[1;1H", to: session)
        _ = text.refresh()
        let viewport = text.textDrawingHelperVisibleRectExcludingTopMargin()
        let caret = text.drawingHelper.cursorFrameForSolidRectangle
        XCTAssertGreaterThanOrEqual(caret.minY, viewport.minY)
        XCTAssertLessThanOrEqual(caret.maxY, viewport.maxY)
        XCTAssertEqual(text.virtualOffset + CGFloat(iTermPreferences.topBottomMargins()), viewport.minY)

        // Deliberate inspection follows the same source cell through reflow and an addressed repaint.
        scroller.userScroll = true
        let before = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
        let inspected = try XCTUnwrap(before.fragments(forSourceRow: 0).dropFirst(2).first)
        let clip = view.scrollview.contentView
        clip.scroll(to: NSPoint(x: 0, y: CGFloat(inspected.displayRow) * text.lineHeight))
        view.scrollview.reflectScrolledClipView(clip)
        let anchorColumn = inspected.firstColumn
        let fullImage = try XCTUnwrap(text.renderLines(toImage: NSRange(location: 0, length: 2)))
        var batchedImage: NSImage?
        var completed = 0
        let token = text.renderLinesToImage(inBatches: NSRange(location: 0, length: 2), batchSize: 1,
            progress: { done, _ in completed = Int(done) }, completion: { batchedImage = $0 })
        XCTAssertNotNil(token, "synchronous mapped capture still returns the existing cancellation token")
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(try XCTUnwrap(batchedImage).size, fullImage.size)
        XCTAssertEqual(batchedImage?.tiffRepresentation, fullImage.tiffRepresentation)
        let attachment = XCTAttachment(image: fullImage)
        attachment.name = "alternate-wrap-130"
        attachment.lifetime = .keepAlways
        add(attachment)
        for width in [180, 130] {
            view.setFrameSize(NSSize(width: CGFloat(width), height: view.frame.height))
            feed("\u{1b}[2;1HASCII\u{1b}[K\u{1b}[1;1H", to: session)
            _ = text.refresh()
            let after = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
            let projected = try XCTUnwrap(after.fragment(forColumn: anchorColumn, sourceRow: 0))
            // Display rows belong to clip coordinates; documentVisibleRect subtracts the wrapper margin.
            XCTAssertEqual(clip.bounds.minY, CGFloat(projected.displayRow) * text.lineHeight)
            let rendered = text.textDrawingHelperVisibleRectExcludingTopMargin()
            XCTAssertEqual(rendered.minY, CGFloat(projected.displayRow) * text.lineHeight)
            XCTAssertEqual(text.virtualOffset + CGFloat(iTermPreferences.topBottomMargins()), rendered.minY)
            // A repaint without another resize must not recapture a margin-biased source cell.
            feed("\u{1b}[2;1HASCII\u{1b}[K\u{1b}[1;1H", to: session)
            _ = text.refresh()
            XCTAssertEqual(clip.bounds.minY, CGFloat(projected.displayRow) * text.lineHeight)
            XCTAssertEqual(text.textDrawingHelperVisibleRectExcludingTopMargin().minY, rendered.minY)
            XCTAssertTrue(scroller.userScroll, "addressed output must not cancel deliberate inspection")
            XCTAssertEqual(try XCTUnwrap(session.screen.screenCharArray(forLine: 0)).stringValue, first)
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testClaudePaintedRowsCanReplayAsOneProseParagraph() throws {
        defer {
            let drained = expectation(description: "paragraph replay callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        let (session, _, text, _) = try fixture(initialText: "")
        session.setSize(VT100GridSizeMake(110, 6))
        session.screen.performBlock(joinedThreads: { _, state, _ in
            state.mutateColorMap { colors in
                colors.setColor(.white, forKey: Int32(kColorMapForeground))
                colors.setColor(.black, forKey: Int32(kColorMapBackground))
                colors.minimumContrast = 0
            }
        })
        session.sync()
        let phrase = "കേരനിരകളാടും ഹരിത"
        let painted = phrase.replacingOccurrences(of: " ", with: "\u{1b}[1C")
        // Client-style positioned output: nine phrases, then seven, both HARD-ended.
        feed("\u{1b}[?1049h\u{1b}[H⏺\u{1b}[1C\u{1b}[4mകേരളപ്പിറവി\u{1b}[0m" +
             "\u{1b}[3;3H" + Array(repeating: painted, count: 9).joined(separator: "\u{1b}[1C") +
             "\u{1b}[4;3H" + Array(repeating: painted, count: 7).joined(separator: "\u{1b}[1C") +
             "\u{1b}[5;3HWRAP-END", to: session)
        let first = session.screen.numberOfScrollbackLines()
        let stored = (0..<5).map { session.screen.screenCharArray(forLine: first + Int32($0)) }
        let sourceBytes = stored.map { Data(bytes: $0.line, count: 110 * MemoryLayout<screen_char_t>.stride) }
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let helper = try XCTUnwrap(text.drawingHelper)
        let rows = stored.enumerated().map { index, source in
            iTermMalayalamProseSourceRow(row: Int(first) + index,
                layout: helper.malayalamLayout(atLine: first + Int32(index)), eol: source.eol, rawText: source.stringValue)
        }
        XCTAssertTrue(rows.allSatisfy { $0.eol == Int32(EOL_HARD) })
        XCTAssertEqual(rows[2].usedColumns, 109)
        XCTAssertEqual(rows[3].usedColumns, 85)
        let width = CGFloat(110) * helper.cellSize.width
        let disabled = iTermMalayalamProseFlow.groups(rows, columns: 110, width: width)
        XCTAssertEqual(disabled.count, 5, "ordinary terminal policy never guesses across HARD rows")
        let groups = iTermMalayalamProseFlow.groups(rows, columns: 110, width: width, clientProse: true)
        XCTAssertEqual(groups.map { $0.rows.count }, [1, 1, 2, 1], "heading, blank line and following hard block stay separate")
        let paragraph = try XCTUnwrap(groups[2].paragraph)
        // The source deliberately contains one sixteen-phrase body paragraph.
        XCTAssertEqual(paragraph.layout.attributedString.string, Array(repeating: phrase, count: 16).joined(separator: " "))
        XCTAssertGreaterThan(paragraph.indentWidth, 0)
        let firstBodyEnd = paragraph.layout.cellUTF16Boundaries[109].intValue
        let secondBodyStart = paragraph.layout.cellUTF16Boundaries[112].intValue
        XCTAssertTrue(paragraph.map.fragments.contains {
            $0.sourceRange.location < firstBodyEnd && NSMaxRange($0.sourceRange) > secondBodyStart
        }, "one visual line must contain visible text from both sides of the old client-painted seam")
        for (offset, count) in [(0, 109), (1, 85)] {
            let sourceRow = Int(first) + 2 + offset
            for column in 0..<count {
                let cell = iTermMalayalamProseCell(row: sourceRow, column: column)
                let point = try XCTUnwrap(paragraph.projection(cell))
                XCTAssertEqual(point.caret.logicalColumn + point.fragment.firstColumn, offset * 110 + column)
                if point.caret.kind == .nativeEdge, let edge = point.caret.nativeEdge {
                    let hits = paragraph.hit(x: paragraph.indentWidth + point.fragment.originX + edge.x,
                                             displayRow: point.fragment.displayRow)
                    XCTAssertTrue(hits.contains(cell), "native caret/hit keeps its source row and column")
                }
            }
            XCTAssertFalse(paragraph.selectionRects(iTermMalayalamProseSpan(sourceRow: sourceRow,
                columns: NSRange(location: 2, length: count - 2)), lineHeight: text.lineHeight).isEmpty)
        }
        let shifted = rows.map { iTermMalayalamProseSourceRow(row: $0.row + 5, layout: $0.layout, eol: $0.eol, rawText: $0.rawText) }
        let moved = try XCTUnwrap(iTermMalayalamProseFlow.groups(shifted, columns: 110, width: width,
            clientProse: true, previousParagraphs: [paragraph])[2].paragraph)
        XCTAssertTrue(moved.layout === paragraph.layout)
        XCTAssertTrue(moved.map === paragraph.map, "reuse immutable geometry, not old source coordinates")
        XCTAssertEqual(moved.rows.map(\.row), paragraph.rows.map { $0.row + 5 })
        let movedPoint = try XCTUnwrap(moved.projection(iTermMalayalamProseCell(row: Int(first) + 8, column: 2)))
        let movedEdge = try XCTUnwrap(movedPoint.caret.nativeEdge)
        XCTAssertTrue(moved.hit(x: moved.indentWidth + movedPoint.fragment.originX + movedEdge.x,
            displayRow: movedPoint.fragment.displayRow).contains(iTermMalayalamProseCell(row: Int(first) + 8, column: 2)))
        // Every short pair changes source ownership, policy inputs, or immutable presentation.
        let traces = [[]] + (0..<6).map { [$0] } + (0..<6).flatMap { a in (0..<6).map { [a, $0] } }
        for events in traces {
            var layouts = Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap { index, row in
                row.layout.map { (NSNumber(value: index), $0) }
            })
            var eols = rows.map { NSNumber(value: $0.eol) }
            var texts = rows.map(\.rawText)
            var currentWidth = width
            func makeMap(previous: iTermMalayalamDisplayMap?) throws -> iTermMalayalamDisplayMap {
                try XCTUnwrap(iTermMalayalamDisplayMap(rows: layouts, rowCount: texts.count, columns: 110,
                    width: currentWidth, sourceEols: eols, sourceTexts: texts, previousMap: previous))
            }
            var prior = try makeMap(previous: nil)
            for event in events {
                switch event {
                case 0:
                    layouts = Dictionary(uniqueKeysWithValues: layouts.map { (NSNumber(value: $0.key.intValue + 1), $0.value) })
                    eols.insert(NSNumber(value: EOL_HARD), at: 0)
                    texts.insert("", at: 0)
                    layouts[0] = layouts[3] // A shared source layout may own multiple row IDs.
                case 1:
                    eols = eols.map { NSNumber(value: $0.int32Value == Int32(EOL_HARD) ? EOL_SOFT : EOL_HARD) }
                case 2, 3:
                    let key = try XCTUnwrap(layouts.keys.sorted { $0.intValue < $1.intValue }.first {
                        layouts[$0]?.attributedString.string.contains("കേര") == true
                    })
                    let old = try XCTUnwrap(layouts[key])
                    let value = old.attributedString.mutableCopy() as! NSMutableAttributedString
                    if event == 2 {
                        value.addAttribute(.foregroundColor, value: NSColor.green,
                                           range: NSRange(location: 0, length: value.length))
                    } else {
                        value.mutableString.replaceOccurrences(of: "ക", with: "മ", options: [], range: NSRange(location: 0, length: value.length))
                    }
                    layouts[key] = try XCTUnwrap(iTermMalayalamRowLayout(attributedString: value,
                        cellUTF16Boundaries: old.cellUTF16Boundaries))
                case 4: currentWidth *= 0.8
                case 5:
                    layouts.removeValue(forKey: 1)
                    texts[1] = "```"
                default: break
                }
                let warm = try makeMap(previous: prior)
                let cold = try makeMap(previous: nil)
                XCTAssertEqual(warm.displayRowCount, cold.displayRowCount, "\(events)")
                XCTAssertEqual(warm.fragments.map(\.sourceRow), cold.fragments.map(\.sourceRow))
                XCTAssertEqual(warm.fragments.map(\.sourceRange), cold.fragments.map(\.sourceRange))
                for (key, facts) in warm.proseFacts {
                    XCTAssertTrue(layouts.values.contains { $0 === facts.layout }, "snapshot retains only current source layouts")
                    if let saved = prior.proseFacts[key] { XCTAssertTrue(facts === saved, "same immutable layout reuses facts") }
                    let uncached = iTermMalayalamProseSourceRow(row: 0, layout: facts.layout, eol: Int32(EOL_HARD))
                    XCTAssertEqual(facts.indent, uncached.indent)
                    XCTAssertEqual(facts.usedColumns, uncached.usedColumns)
                    XCTAssertEqual(facts.firstWordCellWidth, uncached.firstWordCellWidth)
                    XCTAssertEqual(facts.isPlainProse, uncached.isPlainProse)
                    XCTAssertEqual(facts.background, uncached.background)
                }
                let wrapOnly = try XCTUnwrap(iTermMalayalamDisplayMap(rows: layouts, rowCount: texts.count,
                    columns: 110, width: currentWidth, previousMap: warm))
                XCTAssertTrue(wrapOnly.proseFacts.isEmpty, "wrap-only policy never derives prose facts")
                prior = warm
            }
        }
        let size = NSSize(width: width, height: CGFloat(paragraph.map.displayRowCount) * text.lineHeight)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.setFill()
            rect.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for piece in paragraph.map.fragments {
                guard let line = piece.layout?.line else { continue }
                context.saveGState()
                context.setShouldAntialias(false)
                context.translateBy(x: paragraph.indentWidth + piece.originX,
                    y: CGFloat(piece.displayRow) * text.lineHeight + helper.baselineOffset + text.lineHeight)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            }
            return true
        }
        let preview = XCTAttachment(image: image)
        preview.name = "Claude-prose-paragraph-replay-only"
        preview.lifetime = .keepAlways
        add(preview)
        for (index, original) in sourceBytes.enumerated() {
            let source = session.screen.screenCharArray(forLine: first + Int32(index))
            XCTAssertEqual(Data(bytes: source.line, count: 110 * MemoryLayout<screen_char_t>.stride), original)
            XCTAssertEqual(source.eol, Int32(EOL_HARD))
        }
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testSyntheticParagraphsUseSourceCellWordWrapEvidence() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["MalayalamVisualWrap", "MalayalamParagraphFlow"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            let drained = expectation(description: "synthetic corpus callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        keys.forEach { defaults.set(true, forKey: $0) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, _, text, _) = try fixture(initialText: "")
        session.setSize(VT100GridSizeMake(212, 16))
        session.screen.performBlock(joinedThreads: { _, state, _ in
            state.mutateColorMap { colors in
                colors.setColor(.white, forKey: Int32(kColorMapForeground))
                colors.setColor(.black, forKey: Int32(kColorMapBackground))
                colors.minimumContrast = 0
            }
        })
        session.sync()
        // Synthetic syllable specimens retain cell packing, gaps, styles and conjunct boundaries.
        let captured: [(row: Int, text: String, counts: [Int], bold: NSRange)] = [
            (0, "\u{0}\u{0}നികൃക്ഷക്മാക:\u{0}രകമക്കൃ\u{0}ക്ഷമാ\u{0}കൃക്ഷകക്ഷ.\u{0}മക്മാ\u{0}മകോക്ഷക്നികൃ\u{0}മക്മാനിക്കോക്\u{0}മക്ഷക്കൈക്ഷ\u{0}കൃകോകൈ\u{0}മക്കൃക്ഷക്\u{0}കകൃനക്കേക്നി\u{0}കകൈനരനിക്.\u{0}കക്ക്കൃ\u{0}\"നക്നിമകോകും\u{0}മാക്ഷകോക്കേര\"\u{0}നക്ഷമാനി\u{0}കമകേ\u{0}\"മകും\u{0}കമാ\u{0}കൃകോകൈ\u{0}മാകകൃനക്കേമാ\u{0}കൃകോ\u{0}കേരനിക്\"\u{0}കക്ഷകൃകോകൈക്ഷനി\u{0}നക്ഷ\u{0}നിക്ഷകൈകേ\u{0}നിമക്കൈക്\u{0}നിര\u{0}കൈകേക്നിക്കോ.\u{0}മനക്കോ\u{0}നരനികൃക്കൈക്ഷക്\u{0}ക\u{0}കേമാനി\u{0}നകൈകേ",
             [1, 1, 2, 2, 2, 1, 2, 2, 1, 1, 1, 1, 1, 1, 2, 2, 1, 2, 1, 2, 1, 2, 2, 1, 1, 2, 1, 1, 1, 1, 2, 2, 1, 1, 2, 2, 1, 2, 2, 2, 1, 1, 2, 2, 2, 2, 2, 2, 1, 1, 2, 1, 2, 2, 2, 1, 1, 2, 2, 2, 1, 1, 2, 2, 2, 1, 2, 1, 1, 2, 1, 2, 2, 2, 2, 1, 1, 2, 1, 1, 2, 2, 1, 1, 1, 2, 2, 2, 1, 1, 1, 2, 2, 1, 2, 3, 1, 2, 2, 1, 2, 2, 2, 1, 1, 1, 1, 2, 1, 2, 2, 1, 1, 1, 2, 1, 1, 1, 3, 1, 1, 2, 1, 2, 2, 2, 1, 2, 1, 2, 1, 2, 2, 2, 1, 2, 2, 1, 2, 1, 2, 2, 1, 1, 1, 2, 1, 2, 2, 2, 2, 1, 2, 1, 1, 2, 1, 1, 2, 2, 1, 2, 2, 1, 2, 1, 2, 2, 2, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 1, 2, 1, 1, 1, 2, 2, 2, 1, 1, 2, 2], NSRange(location: 2, length: 8)),
            (1, "\u{0}\u{0}നരക്ക്ഷമാ,\u{0}നകൈക്\u{0}നക്ഷ\u{0}നമാ\u{0}കൃകോ,\u{0}മനിക്\u{0}മനരക\u{0}നരക്ഷക്കൃകോകൈ\u{0}മാനിമന\u{0}കമനിരക\u{0}നരക്ഷകോക്കേ\u{0}നക്കോ\u{0}കേക്ഷക്ഷകൈകേക്.",
             [1, 1, 1, 1, 2, 2, 1, 2, 1, 1, 1, 2, 2, 1, 1, 2, 1, 1, 1, 2, 1, 2, 2, 1, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 2, 2, 2, 2, 1, 2, 2, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 2, 1, 2, 2, 2, 1, 1, 2, 2, 1, 2, 2, 1, 2, 1, 2, 2, 2, 1], NSRange(location: 0, length: 0)),
            (2, "\u{0}\u{0}നര\u{0}മക്കും\u{0}കൃകോകൈകേക്ക്\u{0}കോക്ഷര\u{0}മനകൈക്ഷക്\u{0}കകൈകേക്.\u{0}നക്കേ\u{0}നിര\u{0}മക്മാനിക്ഷക്\u{0}amplesa\u{0}മക്,\u{0}amples\u{0}കക്ഷ.\u{0}ക്ക്കൃക്ഷക്\u{0}കകൃക്കൈകമാക്,\u{0}മക്\u{0}കകും\u{0}രകക്കും\u{0}കമകേര\u{0}കൃക്ഷക്ഷനക്ഷ.\u{0}amplesa\u{0}കൃകോ\u{0}നക്ഷകും\u{0}കൈകക്ഷ\u{0}കോകൈ\u{0}മാനിക്കോകൈകും\u{0}നിക്കോക്കേമാകും\u{0}കോകൈക്മാന\u{0}കകൈകേര\u{0}മക്ഷകേക്,\u{0}കോക്ഷര\u{0}മനക്ഷകും\u{0}രകോമക്മാ.\u{0}നക്കേമ\u{0}രക്കൈകേ\u{0}നിമകോകൈകമ\u{0}രക്കൈന",
             [1, 1, 1, 1, 1, 1, 2, 3, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 1, 1, 1, 1, 1, 2, 2, 1, 2, 1, 1, 2, 2, 2, 1, 1, 1, 2, 2, 1, 2, 1, 1, 1, 2, 2, 2, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 2, 2, 2, 2, 1, 2, 1, 1, 2, 2, 2, 1, 2, 2, 1, 1, 1, 2, 1, 1, 3, 1, 1, 1, 2, 3, 1, 1, 1, 2, 1, 1, 2, 2, 1, 2, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 2, 1, 3, 1, 2, 1, 2, 1, 1, 2, 2, 1, 2, 2, 2, 2, 2, 3, 1, 2, 2, 2, 2, 2, 2, 3, 1, 2, 2, 2, 2, 1, 1, 1, 2, 2, 1, 1, 1, 2, 1, 2, 2, 1, 1, 2, 2, 1, 1, 1, 1, 1, 2, 1, 3, 1, 1, 2, 1, 2, 2, 1, 1, 1, 2, 2, 1, 1, 1, 2, 2, 2, 1, 2, 1, 2, 2, 1, 1, 1, 1, 2, 2, 1], NSRange(location: 0, length: 0)),
            (3, "\u{0}\u{0}നകൃക\u{0}നരകകൃക്ഷ.\u{0}നകൃക്കൈന\u{0}കമക്ഷക്ഷന\u{0}കമക്മാക്കൃക്ഷക്\u{0}നകൃ\u{0}മനമാകകൃകോ\u{0}കമാ\u{0}രകോമക്മാക്കൃ\u{0}രക്ക്ഷകൃകോ\u{0}നക്ഷകൃക്\u{0}ക്ഷക്കൃകോ.\u{0}രനികൃ\u{0}രകേ\u{0}ക്കൃകോകൈന\u{0}നിക്ഷകൈക്ക്.\u{0}\"മനമാകമക്ഷ,\u{0}നക്ക്കൈ\u{0}മാക്കൃ\"\u{0}കക്നികൃക്കൈന\u{0}കമക്ക്\u{0}മാനിക്ഷകൈ\u{0}മാക്ക്കോര\u{0}മാക്ഷകോ\u{0}നമാക്കൃന\u{0}കക്നി\u{0}കോക്കേക്ഷക്\u{0}ര\u{0}മനക്കോകൈകേക്കും.\u{0}രകേക്ക്\u{0}കോകും\u{0}രനി\u{0}കോകൈകേ\u{0}നകൃകോമ\u{0}രകക്കോകൈ",
             [1, 1, 1, 2, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 1, 2, 1, 1, 2, 1, 1, 1, 2, 1, 2, 2, 1, 1, 2, 1, 1, 2, 1, 2, 2, 2, 2, 1, 1, 2, 2, 1, 2, 2, 1, 1, 2, 1, 2, 2, 1, 2, 1, 2, 2, 2, 1, 1, 1, 2, 2, 1, 1, 2, 1, 2, 2, 2, 2, 1, 1, 2, 2, 1, 2, 2, 2, 1, 1, 1, 1, 1, 2, 1, 1, 2, 1, 1, 1, 1, 2, 2, 2, 1, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 1, 1, 2, 2, 1, 2, 2, 2, 1, 2, 1, 2, 2, 2, 2, 1, 1, 2, 2, 1, 2, 1, 1, 2, 2, 2, 1, 1, 1, 2, 2, 1, 2, 2, 2, 2, 1, 2, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 1, 1, 1, 2, 2, 2, 1, 2, 3, 1, 1, 2, 1, 2, 2, 2, 1, 1, 2, 2, 1, 1, 1, 1, 2, 2, 2], NSRange(location: 0, length: 0)),
            (4, "\u{0}\u{0}നിക്കോമക്മാനിക്കോ.\u{0}മനികൃക്ക്\u{0}മാകമനരകേമ\u{0}രകകൈനമാനി\u{0}ക്ഷക്മാനിക്ഷമകേക്നിക്കോക്കേകും,\u{0}ക്കൈനരനിക്ഷ\u{0}കമാ\u{0}ക്കോമനരകകൃന\u{0}കമക്ക്\u{0}കൈക്മാകകും.",
             [1, 1, 2, 2, 2, 1, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 1, 2, 1, 1, 1, 1, 2, 1, 1, 1, 1, 2, 1, 2, 2, 1, 2, 1, 2, 2, 2, 2, 1, 1, 2, 2, 2, 2, 2, 2, 2, 3, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 1, 2, 1, 2, 2, 1, 1, 1, 1, 2, 1, 1, 1, 1, 2, 2, 1, 2, 2, 2, 1, 3, 1], NSRange(location: 0, length: 0)),
            (5, "\u{0}\u{0}mpl\u{0}നമാനികൃക്ഷ\u{0}മക്ഷ\u{0}കൈക്ഷനികൃ\u{0}കൈകമക്കൃക്\u{0}കേര\u{0}കൃകോക്കേക്നി,\u{0}കൈക്ക്\u{0}കൃനരക്ഷനിര:",
             [1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 2, 2, 1, 2, 2, 1, 2, 1, 1, 2, 2, 2, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2, 1, 1, 2, 2, 2, 1, 2, 1, 1, 2, 1, 2, 1, 1], NSRange(location: 0, length: 0)),
            (6, "\u{0}\u{0}1. \"നക്ഷക്ക്\" am \"ക്ക്മാക്ഷക്\"",
             [1, 1, 1, 1, 1, 1, 1, 2, 1, 2, 2, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 2, 1], NSRange(location: 2, length: 22)),
            (7, "\u{0}\u{0}-\u{0}കമനക്ഷമ:\u{0}sa\u{0}കൃകമകേ\u{0}കകൃകോ\u{0}കേമാനിക്\u{0}മക്ഷനിക്\u{0}ക്ഷമാന\u{0}കോക്കേ.\u{0}കൃനകൈകേ\u{0}നരകോക്ഷ\u{0}കകൃകോരക്മാക്കൃക,\u{0}മാകക്കോരക്ക്\u{0}\u{0}കമകേ\u{0}കമനക്ഷമനിക്ഷ\u{0}കേമാകമന\u{0}(മനിക്ഷ\u{0}കേരകമക്ക്\u{0}മക്ക്,\u{0}കേരനികൃകോ\u{0}കേമനിര\u{0}മക്ക്\u{0}കൃകോ)\u{0}മാനിരക\u{0}ക്മാകമകും\u{0}കക്ഷക്കും\u{0}നരനികൃക്കും.",
             [1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 2, 1, 1, 2, 2, 1, 2, 2, 2, 2, 1, 1, 2, 1, 2, 2, 1, 2, 1, 2, 1, 1, 2, 2, 2, 1, 1, 2, 1, 2, 2, 1, 1, 1, 2, 2, 1, 1, 1, 2, 2, 1, 2, 2, 2, 2, 1, 1, 1, 2, 1, 2, 2, 1, 2, 2, 1, 1, 1, 1, 2, 1, 1, 1, 1, 2, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 2, 1, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2, 1, 2, 2, 2, 1, 2, 1, 2, 1, 1, 1, 2, 2, 1, 2, 2, 1, 1, 2, 2, 1, 1, 1, 2, 2, 1, 1, 3, 1, 1, 2, 1, 2, 3, 1, 1, 1, 2, 2, 2, 3, 1], NSRange(location: 4, length: 7)),
            (8, "\u{0}\u{0}-\u{0}കമക്ഷകും നകൈക്ഷനകും:\u{0}sam\u{0}നകൈകേമാ\u{0}രകകും,\u{0}കക്കോ\u{0}കേക്നികൃകോക്ഷ\u{0}കകൃ\u{0}രകമാക്ഷ.\u{0}നമാക്ഷനക്കേക്\u{0}ക്ഷകൈനമാ\u{0}മക്ഷ\u{0}മക്കൃ\u{0}കൈനമാകക്ഷരകേക്നിര,\u{0}sa\u{0}ക്ക്\u{0}കമനി\u{0}കക്ക്മാനികൃക്ഷ\u{0}മാനരകമ\u{0}മാനി.\u{0}രകേമനകൃ:\u{0}നമാകമകോ,\u{0}മന,\u{0}മനമാകകൃ,\u{0}\u{0}മാനിക്കോ,\u{0}രനിമ\u{0}കൈകമാ,\u{0}\"മകേക്ഷമ\u{0}കൈക്ഷക്\"\u{0}മക്ഷനിക്\u{0}കൈക\u{0}നരക്കൈക്മാക്ഷ\u{0}കൈകമാനര.",
             [1, 1, 1, 1, 1, 1, 2, 1, 3, 1, 1, 2, 2, 1, 1, 3, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 3, 1, 1, 1, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 1, 2, 2, 1, 1, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1, 2, 1, 2, 1, 2, 1, 1, 2, 1, 1, 1, 2, 2, 1, 2, 1, 2, 1, 2, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2, 1, 1, 2, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 2, 1, 1, 2, 1, 1, 1, 2, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 2, 1, 2, 1, 1, 1, 1, 2, 2, 1, 1, 1, 2, 2, 1, 2, 1, 1, 1, 2, 1, 2, 2, 1, 2, 1, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 2, 1, 2, 1, 1, 1], NSRange(location: 4, length: 13)),
            (9, "\u{0}\u{0}-\u{0}ക്ക്കേക്ഷക് രക്ഷനി കമകേമാക്കൃക്ഷ:\u{0}നകൃക്കൈന\u{0}കക്കോക്ഷമ\u{0}രകോക്ഷമാനിക്കോര,\u{0}നിരകക്കേ\u{0}\u{0}plesamples\u{0}mples\u{0}നിക്ക്\u{0}കേകും:\u{0}ക്ഷകേ,\u{0}ക്ഷക്ഷ,\u{0}ക്ഷരക്മാ,\u{0}കക്ഷക്ഷമ.\u{0}കമാനിക്ക്\u{0}കേക്നിക്ഷക്കേമാക്ഷ\u{0}ക്കേക്നിമകോ\u{0}ക്മാനികൃകകൈകേ\u{0}നിമകോരക്കും,\u{0}\"കൈക്മാക\"\u{0}ക്ഷമാനര\u{0}കൈകേമാനി\u{0}നക്കേക്ക്കൃകും\u{0}കേക്നിമകോക്ഷ.",
             [1, 1, 1, 1, 2, 2, 2, 2, 1, 2, 1, 1, 2, 1, 2, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 2, 2, 1, 2, 2, 2, 2, 1, 1, 1, 2, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 2, 3, 1, 1, 2, 1, 2, 1, 1, 2, 1, 2, 1, 1, 1, 2, 1, 1, 2, 2, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 2, 2, 2, 2, 1, 2, 2, 2, 2, 1, 1, 2, 2, 2, 2, 1, 2, 1, 2, 2, 2, 2, 1, 2, 2, 1, 2, 1, 2, 1, 2, 3, 1, 1, 1, 2, 2, 2, 1, 1, 1, 2, 1, 2, 1, 1, 1, 2, 2, 2, 2, 1, 1, 2, 2, 2, 2, 2, 3, 1, 2, 2, 2, 1, 2, 2, 1, 1], NSRange(location: 4, length: 21))
        ]
        var expected: [[String]] = []
        var replay = "\u{1b}[?1049h\u{1b}[0m\u{1b}[2J"
        for (row, fixture) in captured.enumerated() {
            let scalars = Array(fixture.text.unicodeScalars)
            var offset = 0
            var cells: [String] = []
            for (column, count) in fixture.counts.enumerated() {
                let cell = String(String.UnicodeScalarView(scalars[offset..<(offset + count)]))
                offset += count
                cells.append(cell)
                if cell == "\u{0}" { continue }
                replay += "\u{1b}[\(row + 1);\(column + 1)H\u{1b}[\(NSLocationInRange(column, fixture.bold) ? 1 : 0)m" + cell
            }
            XCTAssertEqual(offset, scalars.count)
            expected.append(cells)
        }
        // Visible CUP-indented fences must protect otherwise joinable prose rows.
        replay += "\u{1b}[0m\u{1b}[11;3H```\u{1b}[12;3H" + captured[2].text.dropFirst(2).replacingOccurrences(of: "\u{0}", with: "\u{1b}[1C") +
                  "\u{1b}[13;3H" + captured[3].text.dropFirst(2).replacingOccurrences(of: "\u{0}", with: "\u{1b}[1C") + "\u{1b}[14;3H```\u{1b}[16;3H"
        feed(replay, to: session)
        _ = text.refresh()
        let first = session.screen.numberOfScrollbackLines()
        let helper = try XCTUnwrap(text.drawingHelper)
        let map = try XCTUnwrap(helper.malayalamDisplayMap)
        var sourceBytes: [Data] = []
        for (index, fixture) in captured.enumerated() {
            let source = session.screen.screenCharArray(forLine: first + Int32(index))
            XCTAssertEqual(source.stringValueIncludingEmbeddedNulls, fixture.text, "specimen row \(fixture.row)")
            XCTAssertEqual(source.eol, Int32(EOL_HARD))
            sourceBytes.append(Data(bytes: source.line, count: 212 * MemoryLayout<screen_char_t>.stride))
            for column in 0..<212 {
                let cell = source.line.advanced(by: column)
                if column < expected[index].count {
                    XCTAssertEqual(ScreenCharToStr(cell), expected[index][column], "row \(fixture.row), cell \(column)")
                } else { XCTAssertEqual(cell.pointee.code, 0) }
                XCTAssertEqual(cell.pointee.bold, NSLocationInRange(column, fixture.bold) ? 1 : 0)
                XCTAssertEqual(cell.pointee.backgroundColorMode, UInt32(ColorModeAlternate.rawValue))
                XCTAssertEqual(cell.pointee.backgroundColor, 0)
            }
        }
        // Independent source-cell packing evidence, including two gaps larger than the old threshold.
        for (a, b, used, word) in [(0, 1, 205, 7), (2, 3, 211, 3), (3, 4, 204, 10)] {
            let layout = try XCTUnwrap(helper.malayalamLayout(atLine: first + Int32(a)))
            let row = iTermMalayalamProseSourceRow(row: a, layout: layout, eol: Int32(EOL_HARD))
            XCTAssertEqual(row.usedColumns, used)
            XCTAssertEqual(expected[b].dropFirst(2).prefix { $0 != "\u{0}" }.count, word)
            XCTAssertLessThan(212 - used, 1 + word)
        }
        for indexes in [[0, 1], [2, 3, 4]] {
            let paragraph = try XCTUnwrap(map.fragments(forSourceRow: Int(first) + indexes[0]).first?.paragraph)
            XCTAssertEqual(paragraph.rows.map(\.row), indexes.map { Int(first) + $0 })
            let semantic = indexes.map { captured[$0].text.dropFirst(2).replacingOccurrences(of: "\u{0}", with: " ") }.joined(separator: " ")
            XCTAssertEqual(paragraph.layout.attributedString.string, semantic)
        }
        let latin = try XCTUnwrap(helper.malayalamLayout(atLine: first + 5))
        XCTAssertTrue(iTermMalayalamProseSourceRow(row: 5, layout: latin, eol: Int32(EOL_HARD)).isPlainProse)
        for index in [5, 6, 7, 8, 9, 11, 12] {
            XCTAssertNil(map.fragments(forSourceRow: Int(first) + index).first?.paragraph,
                         "short hard blocks, headings, distinct list items and fenced code stay separate")
        }
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        _ = try renderedBitmap(text, row: first + 3, name: "synthetic-cross-row-paragraph")
        for (index, bytes) in sourceBytes.enumerated() {
            let source = session.screen.screenCharArray(forLine: first + Int32(index))
            XCTAssertEqual(Data(bytes: source.line, count: 212 * MemoryLayout<screen_char_t>.stride), bytes)
            XCTAssertEqual(source.eol, Int32(EOL_HARD))
        }
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)

        @MainActor func reducedFixture() throws -> (FooterWriteCapturingSession, PTYTextView) {
            let (session, _, text, _) = try fixture(initialText: "")
            session.setSize(VT100GridSizeMake(110, 6))
            session.screen.performBlock(joinedThreads: { _, state, _ in
                state.mutateColorMap { colors in
                    colors.setColor(.white, forKey: Int32(kColorMapForeground))
                    colors.setColor(.black, forKey: Int32(kColorMapBackground))
                    colors.minimumContrast = 0
                }
            })
            session.sync()
            return (session, text)
        }
        let phrase = "കേരനിരകളാടും ഹരിത"
        let painted = phrase.replacingOccurrences(of: " ", with: "\u{1b}[1C")
        let nine = Array(repeating: painted, count: 9).joined(separator: "\u{1b}[1C")
        let (complexSession, complexText) = try reducedFixture()
        feed("\u{1b}[?1049h\u{1b}[1;3H" + nine + "\u{1b}[2;3H" + painted + " \u{0d4d}", to: complexSession)
        let complexRow = complexSession.screen.numberOfScrollbackLines() + 1
        let complexSource = complexSession.screen.screenCharArray(forLine: complexRow)
        XCTAssertEqual(ScreenCharToStr(complexSource.line.advanced(by: 13)), " \u{0d4d}")
        XCTAssertNotEqual(complexSource.line[13].complexChar, 0)
        let complexBytes = Data(bytes: complexSource.line, count: 110 * MemoryLayout<screen_char_t>.stride)
        for enabled in [true, false, true] {
            defaults.set(enabled, forKey: "MalayalamParagraphFlow")
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            _ = complexText.refresh()
            let helper = try XCTUnwrap(complexText.drawingHelper)
            let layout = try XCTUnwrap(helper.malayalamLayout(atLine: complexRow))
            XCTAssertEqual(layout.cellUTF16Boundaries.count, 111, "aliases retain every source cell")
            XCTAssertEqual(iTermMalayalamProseSourceRow(row: Int(complexRow), layout: layout,
                eol: Int32(EOL_HARD)).usedColumns, 14, "SPACE plus a Malayalam mark is visible content, not padding")
            let paragraph = helper.malayalamDisplayMap?.fragments(forSourceRow: Int(complexRow)).first?.paragraph
            if enabled {
                let joined = try XCTUnwrap(paragraph)
                XCTAssertEqual(joined.layout.attributedString.string,
                    Array(repeating: phrase, count: 10).joined(separator: " ") + " \u{0d4d}")
            } else { XCTAssertNil(paragraph) }
            let current = complexSession.screen.screenCharArray(forLine: complexRow)
            XCTAssertEqual(Data(bytes: current.line, count: 110 * MemoryLayout<screen_char_t>.stride), complexBytes)
            XCTAssertEqual(current.eol, Int32(EOL_HARD))
        }
        feed("\u{1b}[2;1H\u{1b}[2K\u{1b}[2;3H \u{0d4d}" + painted, to: complexSession)
        _ = complexText.refresh()
        let leading = try XCTUnwrap(complexText.drawingHelper?.malayalamLayout(atLine: complexRow))
        XCTAssertEqual(iTermMalayalamProseSourceRow(row: Int(complexRow), layout: leading,
            eol: Int32(EOL_HARD)).indent, 2, "a space-based complex cell is not another indentation cell")
        XCTAssertTrue(complexSession.writes.isEmpty)

        let (fenceSession, fenceText) = try reducedFixture()
        feed("\u{1b}[?1049h\u{1b}[1;3H````\u{1b}[3;3H" + nine + "\u{1b}[4;3H" + painted, to: fenceSession)
        for close in ["```", "```` info", "````   "] {
            feed("\u{1b}[2;1H\u{1b}[2K\u{1b}[2;3H" + close, to: fenceSession)
            let row = fenceSession.screen.numberOfScrollbackLines() + 2
            let source = fenceSession.screen.screenCharArray(forLine: row)
            let bytes = Data(bytes: source.line, count: 110 * MemoryLayout<screen_char_t>.stride)
            _ = fenceText.refresh()
            let paragraph = fenceText.drawingHelper?.malayalamDisplayMap?.fragments(forSourceRow: Int(row)).first?.paragraph
            if close == "````   " { XCTAssertNotNil(paragraph, "a proper close lets subsequent prose flow") }
            else { XCTAssertNil(paragraph, "a shorter or info-suffixed run cannot close the longer fence") }
            let current = fenceSession.screen.screenCharArray(forLine: row)
            XCTAssertEqual(Data(bytes: current.line, count: 110 * MemoryLayout<screen_char_t>.stride), bytes)
            XCTAssertEqual(current.eol, Int32(EOL_HARD))
        }
        XCTAssertTrue(fenceSession.writes.isEmpty)
    }

    func testClaudeParagraphFlowKeepsTerminalCellsAcrossEvents() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["MalayalamVisualWrap", "MalayalamParagraphFlow"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            let drained = expectation(description: "paragraph view callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        defaults.set(true, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "")
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_USE_SELECTED_TEXT_COLOR] = true
        profile[KEY_USE_SEPARATE_COLORS_FOR_LIGHT_AND_DARK_MODE] = false
        session.profile = profile
        session.setPreferencesFromAddressBookEntry(profile)
        session.setSize(VT100GridSizeMake(110, 6))
        session.screen.performBlock(joinedThreads: { _, state, _ in
            state.mutateColorMap { colors in
                colors.setColor(.red, forKey: Int32(kColorMapForeground))
                colors.setColor(.blue, forKey: Int32(kColorMapSelection))
                colors.setColor(.white, forKey: Int32(kColorMapSelectedText))
                colors.setColor(.black, forKey: Int32(kColorMapBackground))
                colors.minimumContrast = 0
            }
        })
        session.sync()
        let phrase = "കേരനിരകളാടും ഹരിത".replacingOccurrences(of: " ", with: "\u{1b}[1C")
        let firstText = Array(repeating: phrase, count: 9).joined(separator: "\u{1b}[1C")
        let secondText = Array(repeating: phrase, count: 7).joined(separator: "\u{1b}[1C")
        feed("\u{1b}[?1049h\u{1b}[H⏺\u{1b}[1C\u{1b}[4mകേരളപ്പിറവി\u{1b}[0m" +
             "\u{1b}[3;3H" + firstText + "\u{1b}[4;3H" + secondText + "\u{1b}[5;3HWRAP-END", to: session)
        // Every short pair changes real mode, viewport, decoration or exact-cell inspection state.
        for first in 0..<5 {
            for second in 0..<5 {
                var enabled = false, narrow = false, underlined = false, inspected = false, selected = false
                for (step, event) in [first, second].enumerated() {
                    switch event {
                    case 0: enabled.toggle()
                    case 1: narrow.toggle()
                    case 2: underlined.toggle()
                    case 3: inspected.toggle()
                    default: selected.toggle()
                    }
                    defaults.set(enabled, forKey: keys[1])
                    iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
                    view.setFrameSize(NSSize(width: narrow ? 640 : 1347, height: 180))
                    feed("\u{1b}[3;3H" + (underlined ? "\u{1b}[4m" : "\u{1b}[0m") + firstText +
                         "\u{1b}[0m\u{1b}[4;3H" + secondText + "\u{1b}[5;3H", to: session)
                    let row = session.screen.numberOfScrollbackLines() + 2
                    if inspected { text.selectMalayalamColumn(108, absoluteRow: Int64(row + 1) + Int64(session.screen.totalScrollbackOverflow())) }
                    else {
                        text.selection.clear()
                        if selected {
                            let absolute = Int64(row) + Int64(session.screen.totalScrollbackOverflow())
                            text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                                VT100GridAbsCoordRangeMake(2, absolute, 109, absolute), 0, 0), mode: .kiTermSelectionModeCharacter)
                        }
                    }
                    guard session.screen.width() == 110 && session.screen.height() == 6 else {
                        XCTFail("viewport-only fixture must retain its requested terminal grid")
                        return
                    }
                    let source = (0..<6).map { session.screen.screenCharArray(forLine: row - 2 + Int32($0)) }
                    let bytes = source.map { Data(bytes: $0.line, count: 110 * MemoryLayout<screen_char_t>.stride) }
                    let cursor = (session.screen.cursorX(), session.screen.cursorY())
                    _ = text.refresh()
                    let helper = try XCTUnwrap(text.drawingHelper)
                    let map = try XCTUnwrap(helper.malayalamDisplayMap)
                    XCTAssertEqual(map.paragraphFlowEnabled, enabled)
                    let pieces = map.fragments(forSourceRow: Int(row))
                    XCTAssertEqual(pieces.first?.paragraph != nil, enabled && !underlined,
                                   "default HARD rows and decorated blocks remain separate")
                    for sourceRow in [row, row + 1] {
                        for column in 0..<110 {
                            let piece = try XCTUnwrap(map.fragment(forColumn: column, sourceRow: Int(sourceRow)))
                            let local = try XCTUnwrap(piece.localColumn(column, sourceRow: Int(sourceRow))).intValue
                            let point = try XCTUnwrap(piece.layout?.projection(atColumn: local))
                            guard let edge = point.nativeEdge else { continue }
                            let x = try XCTUnwrap(helper.malayalamX(forColumn: Int32(column), line: sourceRow)).doubleValue
                            XCTAssertTrue(x.isFinite)
                            if point.kind == .nativeEdge {
                                XCTAssertTrue(piece.sourceCells(forLocalColumn: local).contains {
                                    $0.pointValue == NSPoint(x: CGFloat(column), y: CGFloat(sourceRow))
                                })
                            }
                            if inspected && sourceRow == row + 1 && column == 108 {
                                if piece.paragraph != nil {
                                    let hit = try XCTUnwrap(helper.malayalamCell(forX: CGFloat(x), displayRow: Int32(piece.displayRow)))
                                    XCTAssertEqual(hit.pointValue, NSPoint(x: 108, y: CGFloat(sourceRow)),
                                                   "collapsed padding keeps its exact inspected source-cell alias")
                                }
                                XCTAssertEqual((text.malayalamCellStripState()?["focus"] as? NSNumber)?.intValue, 108)
                            }
                            XCTAssertTrue(edge.x.isFinite)
                        }
                    }
                    if let paragraph = pieces.first?.paragraph {
                        XCTAssertTrue(pieces.contains { paragraph.spans(in: $0).count == 2 })
                        // Rendering from a viewport starting within the group must still include its owner.
                        let middle = pieces[pieces.count / 2]
                        view.scrollview.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(middle.displayRow) * text.lineHeight))
                        let image = try renderedBitmap(text, row: row + 1, includeSelection: true,
                            name: "paragraph-partial-\(first)-\(second)-\(step)")
                        XCTAssertGreaterThan(image.pixelsHigh, 0)
                        if selected && !inspected {
                            let unselected = try renderedBitmap(text, row: row + 1, includeSelection: false,
                                name: "paragraph-clean-\(first)-\(second)-\(step)")
                            XCTAssertNotEqual(image.tiffRepresentation, unselected.tiffRepresentation,
                                              "current selection paint must reach a fragment shared by both source rows")
                        }
                    }
                    for (index, original) in bytes.enumerated() {
                        let current = session.screen.screenCharArray(forLine: row - 2 + Int32(index))
                        XCTAssertEqual(Data(bytes: current.line, count: 110 * MemoryLayout<screen_char_t>.stride), original)
                        XCTAssertEqual(current.eol, source[index].eol)
                    }
                    XCTAssertEqual(session.screen.cursorX(), cursor.0)
                    XCTAssertEqual(session.screen.cursorY(), cursor.1)
                    XCTAssertTrue(session.writes.isEmpty)
                }
            }
        }
    }

    func testClearHistoryReusesMovedNaturalLayoutsAcrossShortSequences() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": true,
                        "ExtendBackgroundColorIntoMargins": true]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "history layout reuse callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let templates = (0..<9).map { "  മലയാളം വരി" + String(format: "%02d", $0) }
        // All twenty-seven length-three traces over refresh, real clear/redraw and replacement.
        for trace in 0..<27 {
            let events = [trace / 9, (trace / 3) % 3, trace % 3]
            let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 12)
            session.setSize(VT100GridSizeMake(110, 6))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: view.compactFrame().height),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            var history = (0..<12).map { templates[$0 % templates.count] }
            var grid = Array(templates.prefix(6))
            func frame() -> String {
                grid.enumerated().map { "\u{1b}[\($0.offset + 1);1H" + $0.element }.joined()
            }
            feed((0..<17).map { templates[$0 % templates.count] + "\r\n" }.joined() +
                 "\u{1b}[?1049h" + frame(), to: session)
            _ = text.refresh()
            let helper = try XCTUnwrap(text.drawingHelper)
            let cursorX = session.screen.cursorX(), cursorY = session.screen.cursorY()
            func checkSource() {
                XCTAssertEqual(session.screen.numberOfScrollbackLines(), 12, "trace \(events)")
                XCTAssertEqual(session.screen.width(), 110)
                XCTAssertEqual(session.screen.height(), 6)
                XCTAssertEqual(session.screen.cursorX(), cursorX)
                XCTAssertEqual(session.screen.cursorY(), cursorY)
                for (index, expected) in (history + grid).enumerated() {
                    let row = session.screen.screenCharArray(forLine: Int32(index))
                    XCTAssertEqual(row.stringValue, expected, "trace \(events), row \(index)")
                    XCTAssertEqual(row.eol, Int32(EOL_HARD))
                }
                XCTAssertTrue(session.writes.isEmpty)
            }
            checkSource()
            for event in events {
                let before = try XCTUnwrap(helper.malayalamDisplayMap)
                let builds = helper.malayalamRowLayoutBuildCount
                let overflow = session.screen.totalScrollbackOverflow()
                switch event {
                case 0: break
                case 1:
                    history = Array((history + grid).suffix(12))
                    feed("\u{1b}[2J" + frame(), to: session)
                default:
                    grid[0] = templates[8]
                    // Accept data only; save/restore cursor makes the source-coordinate oracle independent.
                    feed("\u{1b}7\u{1b}[1;1H\u{1b}[2K" + grid[0] + "\u{1b}8", to: session)
                }
                _ = text.refresh()
                checkSource()
                let after = try XCTUnwrap(helper.malayalamDisplayMap)
                if event == 1 {
                    XCTAssertEqual(session.screen.totalScrollbackOverflow() - overflow, 6)
                    for row in 0..<18 {
                        let oldRow = row < 12 ? row + 6 : row
                        let old = try XCTUnwrap(before.sourceLayout(forRow: oldRow))
                        let new = try XCTUnwrap(after.sourceLayout(forRow: row))
                        XCTAssertTrue(old.attributedString.isEqual(to: new.attributedString))
                        XCTAssertEqual(old.cellUTF16Boundaries, new.cellUTF16Boundaries)
                    }
                }
                if event != 2 {
                    XCTAssertEqual(helper.malayalamRowLayoutBuildCount, builds,
                                   "trace \(events): unchanged or moved identical attributed rows need no new shaping")
                } else {
                    XCTAssertLessThanOrEqual(helper.malayalamRowLayoutBuildCount - builds, 1,
                                             "only the replaced source row may need shaping")
                }
                let prepared = helper.malayalamRowLayoutPreparationCount
                let shaped = helper.malayalamRowLayoutBuildCount
                _ = text.refresh()
                XCTAssertEqual(helper.malayalamRowLayoutPreparationCount, prepared)
                XCTAssertEqual(helper.malayalamRowLayoutBuildCount, shaped)
                checkSource()
            }
        }
    }

    func testResponsiveBoxTableKeepsNaturalCellsAndSharedColumns() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": true, "CopySelection": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "responsive table callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let rows = [
            "  ├────────────────────────────────────────────────┼────────────────────┤",
            "  │ Outcome                                        │ Chance             │",
            "  ├────────────────────────────────────────────────┼────────────────────┤",
            "  │ Garden (തോട്ടത്തിൽ നിറയെ പൂക്കൾ, എല്ലാം bright green).    │ 25–35%             │",
            "  ├────────────────────────────────────────────────┼────────────────────┤",
            "  │ Lake map (കുളത്തിലെ ചെറുമീനുകൾ, കരയിൽ നിറമുള്ള മരങ്ങളും പൂക്കളും) │ 15–25%             │",
            "  ├────────────────────────────────────────────────┼────────────────────┤",
        ]
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 100)
        session.setSize(VT100GridSizeMake(110, 8))
        feed(rows.joined(separator: "\r\n") + String(repeating: "\r\n", count: 8) + "\u{1b}[?1049h", to: session)
        let height = view.compactFrame().height
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
        scroller.userScroll = true
        view.scrollview.contentView.scroll(to: .zero)
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let originalHistory = session.screen.numberOfScrollbackLines()
        XCTAssertGreaterThanOrEqual(originalHistory, Int32(rows.count))
        // Bounded pairs of narrow/wide presentation resize, unchanged redraw and real clear.
        for first in 0..<3 {
            for second in 0..<3 {
                for event in [first, second] {
                    if event == 0 {
                        view.setFrameSize(NSSize(width: view.frame.width < 700 ? 1100 : 430, height: height))
                    } else if event == 2 {
                        feed("\u{1b}[2J", to: session) // Empty alternate grid, retained table stays immutable.
                    }
                    _ = text.refresh()
                    let helper = try XCTUnwrap(text.drawingHelper)
                    let map = try XCTUnwrap(helper.malayalamDisplayMap)
                    let cell = helper.cellSize.width
                    let margin = CGFloat(iTermPreferences.sideMargins())
                    let budget = view.scrollview.documentVisibleRect.width - 2 * margin - 2
                    func x(_ column: Int32, _ row: Int32) -> CGFloat {
                        text.point(for: VT100GridCoordMake(column, row)).x
                    }
                    let anchors = [x(2, 0), x(51, 0), x(72, 0)]
                    XCTAssertEqual(anchors[0], margin + 2 * cell, accuracy: 0.01)
                    XCTAssertEqual(anchors[2] + cell, margin + budget - 2 * cell, accuracy: 0.01,
                                   "table fills the available width with a two-cell right gutter")
                    XCTAssertLessThanOrEqual(anchors[2] - anchors[1], 12 * cell, "short values stay compact")
                    for row in rows.indices {
                        for (index, column) in [2, 51, 72].enumerated() {
                            XCTAssertEqual(x(Int32(column), Int32(row)), anchors[index], accuracy: 0.01,
                                           "headers, horizontal borders and natural cells share anchors")
                        }
                        XCTAssertEqual(session.screen.screenCharArray(forLine: Int32(row)).stringValue, rows[row])
                        XCTAssertEqual(session.screen.screenCharArray(forLine: Int32(row)).eol, Int32(EOL_HARD))
                    }
                    if view.frame.width < 700 {
                        XCTAssertGreaterThan(map.fragments(forSourceRow: 5).count, 1, "Long catalogue text wraps inside its cell")
                    }
                    else {
                        let source = try XCTUnwrap(map.sourceLayout(forRow: 3))
                        let start = source.cellUTF16Boundaries[4].intValue
                        let end = source.cellUTF16Boundaries[47].intValue
                        let content = source.attributedString.attributedSubstring(from: NSRange(location: start, length: end - start))
                        let native = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(content), nil, nil, nil)
                        XCTAssertEqual(x(47, 3) - x(4, 3), native, accuracy: 0.01,
                                       "Malayalam cell content keeps its native advance, not a squeezed or spaced fit")
                    }
                    // Existing public geometry APIs must round-trip real indent, border, padding and ASCII cells.
                    let source = try XCTUnwrap(map.sourceLayout(forRow: 3))
                    for column: Int32 in [0, 1, 2, 3, 4, 51, 52, 53] {
                        let piece = try XCTUnwrap(map.fragment(forColumn: Int(column), sourceRow: 3))
                        let hit = try XCTUnwrap(helper.malayalamCell(forX: x(column, 3), displayRow: Int32(piece.displayRow)))
                        XCTAssertEqual(hit.pointValue, NSPoint(x: CGFloat(column), y: 3))
                        var partial: ObjCBool = false
                        let rectangles = try XCTUnwrap(helper.malayalamSelectionRects(NSRange(location: Int(column), length: 1),
                            layout: source, line: 3, partial: &partial))
                        XCTAssertFalse(rectangles.isEmpty, "real source whitespace still owns selection geometry")
                        for value in rectangles {
                            XCTAssertGreaterThanOrEqual(value.rectValue.minX, margin)
                            XCTAssertLessThanOrEqual(value.rectValue.maxX, column < 51 ? anchors[1] : anchors[2] + cell,
                                                     "selection stays inside its cell, not across the neighbor")
                        }
                    }
                    let overflow = session.screen.totalScrollbackOverflow()
                    text.selection.clear()
                    text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                        VT100GridAbsCoordRangeMake(0, overflow + 3, 73, overflow + 3), 0, 0),
                        mode: .kiTermSelectionModeCharacter)
                    XCTAssertEqual(text.selectedText, rows[3], "copy never adds presentation wraps")
                    text.selection.clear()
                    XCTAssertEqual(session.screen.cursorX(), cursor.0)
                    XCTAssertEqual(session.screen.cursorY(), cursor.1)
                    XCTAssertEqual(session.screen.width(), 110)
                    XCTAssertEqual(session.screen.height(), 8)
                    XCTAssertTrue(session.writes.isEmpty)
                }
            }
        }
        // Active-table style changes preserve geometry and painted source decorations.
        view.setFrameSize(NSSize(width: 1100, height: height))
        feed("\u{1b}[H" + rows.joined(separator: "\r\n"), to: session)
        _ = text.refresh()
        let active = session.screen.numberOfScrollbackLines()
        let body = active + 3, border = active + 2
        let styleCursor = (session.screen.cursorX(), session.screen.cursorY())
        feed("\u{1b}7\u{1b}[4;1H\u{1b}[4;38;2;0;255;0;58;2;0;255;0m  \u{1b}[0m\u{1b}8", to: session)
        _ = text.refresh()
        let prefix = try renderedBitmap(text, row: body, name: "responsive-table-underlined-source-indent")
        let prefixScale = CGFloat(prefix.pixelsWide) / prefix.size.width
        let prefixX = Int((CGFloat(iTermPreferences.sideMargins()) + 1.5 * text.drawingHelper.cellSize.width) * prefixScale)
        XCTAssertTrue((0..<prefix.pixelsHigh).contains { y in
            guard let color = prefix.colorAt(x: prefixX, y: y)?.usingColorSpace(.sRGB) else { return false }
            return color.greenComponent > 0.6 && color.redComponent < 0.4 && color.blueComponent < 0.4
        }, "underlined source indentation has visible ink, even though it is outside the first border")
        let beforeLetter = text.point(for: VT100GridCoordMake(4, body)).x
        feed("\u{1b}7\u{1b}[4;4H\u{1b}[4m \u{1b}[0m\u{1b}8", to: session)
        _ = text.refresh()
        XCTAssertEqual(text.point(for: VT100GridCoordMake(4, body)).x, beforeLetter, accuracy: 0.01,
                       "underlining an existing leading space must not add another inset")
        feed("\u{1b}7\u{1b}[4;53H\u{1b}[4m" + String(repeating: " ", count: 20) + "\u{1b}[0m\u{1b}8", to: session)
        _ = text.refresh()
        var currentMap = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
        let decoratedFragment = try XCTUnwrap(currentMap.fragment(forColumn: 53, sourceRow: Int(body)))
        let decorated = try XCTUnwrap(decoratedFragment.layout)
        let decoratedColumn = try XCTUnwrap(decoratedFragment.localColumn(53, sourceRow: Int(body))).intValue
        let decoratedOffset = decorated.cellUTF16Boundaries[decoratedColumn].intValue
        XCTAssertFalse(decorated.attributedString.string.isEmpty, "an underlined all-space cell must not vanish")
        XCTAssertTrue((decorated.attributedString.attribute(NSAttributedString.Key("iTermMalayalamUnderlineAttribute"),
            at: decoratedOffset, effectiveRange: nil) as? NSNumber)?.boolValue == true)
        feed("\u{1b}7\u{1b}[4;54H\u{1b}[0m\u{00a0}\u{1b}8", to: session)
        _ = text.refresh()
        currentMap = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
        let nonbreakingFragment = try XCTUnwrap(currentMap.fragment(forColumn: 53, sourceRow: Int(body)))
        let nonbreaking = try XCTUnwrap(nonbreakingFragment.layout)
        let nonbreakingColumn = try XCTUnwrap(nonbreakingFragment.localColumn(53, sourceRow: Int(body))).intValue
        let nonbreakingStart = nonbreaking.cellUTF16Boundaries[nonbreakingColumn].intValue
        let nonbreakingEnd = nonbreaking.cellUTF16Boundaries[nonbreakingColumn + 1].intValue
        XCTAssertEqual((nonbreaking.attributedString.string as NSString).substring(with:
            NSRange(location: nonbreakingStart, length: nonbreakingEnd - nonbreakingStart)), "\u{00a0}",
            "NBSP is content, not removable client fill")
        XCTAssertLessThanOrEqual(text.point(for: VT100GridCoordMake(72, body)).x -
            text.point(for: VT100GridCoordMake(51, body)).x, 12 * text.drawingHelper.cellSize.width,
            "a whitespace-only cell must not turn the compact value column into flexible prose")
        feed("\u{1b}7\u{1b}[4;4H\u{1b}[48;2;0;0;255m \u{1b}[0m\u{1b}8", to: session)
        _ = text.refresh()
        let background = try renderedBitmap(text, row: body, name: "responsive-table-padding-background-clip")
        XCTAssertEqual(background.size.height,
            CGFloat(try XCTUnwrap(text.drawingHelper.malayalamDisplayMap).fragments(forSourceRow: Int(body)).count) * text.lineHeight,
            accuracy: 0.01, "one source-row image includes all of its wrapped visual rows")
        let backgroundScale = CGFloat(background.pixelsWide) / background.size.width
        for (first, expectedBlue) in [(Int32(3), true), (Int32(52), false)] {
            let left = text.point(for: VT100GridCoordMake(first, body)).x
            let right = text.point(for: VT100GridCoordMake(first + 1, body)).x
            let pixel = try XCTUnwrap(background.colorAt(x: Int((left + right) / 2 * backgroundScale), y: 2)?.usingColorSpace(.sRGB))
            XCTAssertEqual(pixel.blueComponent > 0.6 && pixel.redComponent < 0.4, expectedBlue,
                           "the padding background paints its own band, not the neighboring cell")
        }
        feed("\u{1b}7\u{1b}[3;21H\u{1b}[1;38;2;255;0;0m─\u{1b}[0m\u{1b}8", to: session)
        _ = text.refresh()
        let image = try renderedBitmap(text, row: border, name: "responsive-table-interior-border-style")
        let scale = CGFloat(image.pixelsWide) / image.size.width
        func redPixels(between first: Int32, and end: Int32) -> Int {
            let left = text.point(for: VT100GridCoordMake(first, border)).x
            let right = text.point(for: VT100GridCoordMake(end, border)).x
            let x = Int((left + right) / 2 * scale)
            guard x >= 0 && x < image.pixelsWide else { return 0 }
            return (0..<image.pixelsHigh).filter { y in
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.redComponent > 0.6 && color.greenComponent < 0.4 && color.blueComponent < 0.4
            }.count
        }
        XCTAssertGreaterThan(redPixels(between: 20, and: 21), 0, "the interior dash keeps its own red foreground")
        XCTAssertEqual(redPixels(between: 18, and: 19), 0, "joint or neighboring dash color must not leak")
        XCTAssertEqual(session.screen.screenCharArray(forLine: border).stringValue, rows[2])
        let expectedBody = rows[3].replacingOccurrences(of: " 25–35%             ",
            with: " \u{00a0}" + String(repeating: " ", count: 18))
        XCTAssertEqual(session.screen.screenCharArray(forLine: body).stringValue, expectedBody)
        XCTAssertEqual(session.screen.screenCharArray(forLine: body).eol, Int32(EOL_HARD))
        let absolute = session.screen.totalScrollbackOverflow() + Int64(body)
        text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
            VT100GridAbsCoordRangeMake(0, absolute, 73, absolute), 0, 0), mode: .kiTermSelectionModeCharacter)
        XCTAssertEqual(text.selectedText, expectedBody)
        text.selection.clear()
        XCTAssertEqual(session.screen.cursorX(), styleCursor.0)
        XCTAssertEqual(session.screen.cursorY(), styleCursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testNativePasteAndEditingRoundTripThroughBashReadline() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ITERM2_MALAYALAM_PASTE_LIVE"] == "1",
                          "Explicit opt-in real PTY paste and shell line-editor roundtrip")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ml-paste-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["RunJobsInServers": false, "QuickPasteBytesPerCall": 8192,
            "AlwaysWarnBeforePastingOverSize": -1, "StripZeroWidthFormatCharactersOnPaste": false,
            "SavePasteHistory": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            try? FileManager.default.removeItem(at: root)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 100)
        session.forwardWritesToPTY = true
        defer {
            session.shell.delegate = nil
            session.shell.stop()
            let drained = expectation(description: "Readline task callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_CHARACTER_ENCODING] = String.Encoding.utf8.rawValue
        profile[KEY_ALLOW_PASTE_BRACKETING] = true
        session.profile = profile
        session.setPreferencesFromAddressBookEntry(profile)
        session.setSize(VT100GridSizeMake(110, 10))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: view.compactFrame().height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(text))
        func transcript() -> String {
            (0..<session.screen.numberOfLines()).map {
                session.screen.screenCharArray(forLine: $0).stringValue
            }.joined(separator: "\n")
        }
        func currentLine() -> String {
            let row = session.screen.numberOfScrollbackLines() + session.screen.cursorY() - 1
            return session.screen.screenCharArray(forLine: row).stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var diagnostics = [String]()
        defer {
            let attachment = XCTAttachment(string: diagnostics.joined(separator: "\n"))
            attachment.name = "Readline-source-cursor-and-bracket-mode"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func observed(_ label: String, _ predicate: @escaping () -> Bool) -> Bool {
            let ready = expectation(for: NSPredicate { _, _ in predicate() }, evaluatedWith: nil)
            wait(for: [ready], timeout: 10)
            let matched = predicate()
            diagnostics.append("\(label): source=\(currentLine().debugDescription), " +
                "cursor=(\(session.screen.cursorX()),\(session.screen.cursorY())), " +
                "DEC2004=\(session.screen.terminalBracketedPasteMode), matched=\(matched)")
            if !matched { diagnostics.append(transcript()) }
            XCTAssertTrue(matched, label)
            return matched
        }
        let environment = ["HOME": root.path, "ZDOTDIR": root.path, "INPUTRC": "/dev/null", "HISTFILE": "/dev/null",
            "HISTSIZE": "0", "HISTFILESIZE": "0", "BASH_SILENCE_DEPRECATION_WARNING": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        // Both editors accept data, never evaluate it as a command; od reports accepted bytes independently.
        let program = #"""
        for ((i=0;i<9;i++)); do
            IFS= read -e -r -p "$(printf 'READ%02d> ' "$i")" reply || exit
            hex=$(printf '%s' "$reply" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n')
            printf '\r\nMLHEX%02d:%s:DONE%02d\r\n' "$i" "$hex" "$i"
        done
        exec /bin/zsh -f -i -c "$1"
        """#
        let zleProgram = #"""
        bindkey -e
        reply=""
        vared -p "ZLE-BRACKET> " reply || exit
        hex=$(printf '%s' "$reply" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n')
        printf '\r\nZLEHEX:%s:ZLEDONE\r\n' "$hex"
        exec /bin/cat
        """#
        let launched = expectation(description: "private Bash Readline PTY launched")
        session.shell.launch(withPath: "/usr/bin/env", arguments: ["-i"] +
            environment.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value } +
            ["/bin/bash", "--noprofile", "--norc", "-i", "-c", program, "ml-paste", zleProgram], environment: environment,
            customShell: nil, gridSize: VT100GridSizeMake(110, 10), viewSize: view.frame.size,
            maybeScaleFactor: 1, isUTF8: true) { launched.fulfill() }
        wait(for: [launched], timeout: 10)
        let prefix = "മലയാളം ന്\u{200D} "
        var caseIndex = 0
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: Double(caseIndex), windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            text.keyDown(with: event)
        }
        for first in 0..<3 {
            for second in 0..<3 {
                let prompt = String(format: "READ%02d> ", caseIndex)
                guard observed("real Readline prompt \(caseIndex)", {
                    currentLine() == prompt.trimmingCharacters(in: .whitespaces)
                }) else { return }
                XCTAssertTrue(session.textViewCanWriteToTTY())
                XCTAssertEqual(session.screen.terminalEncoding, String.Encoding.utf8.rawValue)
                // The child owns DEC2004 mode. Do not synthesize a mode unsupported by its Readline.
                session.paste(prefix + "AB", flags: [])
                guard observed("paste echoed by child", { currentLine().hasSuffix("AB") }) else { return }
                let startX = session.screen.cursorX() - 2
                var suffix = Array("AB"), cursor = 2
                for action in [first, second] {
                    switch action {
                    case 0: cursor = max(0, cursor - 1); try key("\u{f702}", code: 123, modifiers: .function)
                    case 1: cursor = min(suffix.count, cursor + 1); try key("\u{f703}", code: 124, modifiers: .function)
                    default:
                        if cursor > 0 { suffix.remove(at: cursor - 1); cursor -= 1 }
                        try key("\u{7f}", code: 51)
                    }
                    guard observed("native edit echoed by child", {
                        currentLine().hasSuffix(String(suffix)) &&
                            session.screen.cursorX() == startX + Int32(cursor)
                    }) else { return }
                }
                try key("\r", code: 36)
                let expectedHex = (prefix + String(suffix)).utf8.map { String(format: "%02x", $0) }.joined()
                let result = String(format: "MLHEX%02d:", caseIndex) + expectedHex + String(format: ":DONE%02d", caseIndex)
                guard observed("accepted UTF8 bytes \(caseIndex)", { transcript().contains(result) }) else { return }
                XCTAssertEqual(session.screen.width(), 110)
                XCTAssertEqual(session.screen.height(), 10)
                caseIndex += 1
            }
        }
        // ZLE advertises real DEC2004 support; never force the terminal mode from the test.
        guard observed("ZLE prompt with bracketed paste enabled", {
            currentLine().hasSuffix("ZLE-BRACKET>") && session.screen.terminalBracketedPasteMode
        }) else { return }
        let bracketPayload = "ക്ഷ ന്\u{200D}👩‍💻🙂\tEND"
        session.paste(bracketPayload, flags: [])
        XCTAssertFalse(session.isPasting())
        guard observed("ZLE bracketed payload echo", { currentLine().hasSuffix("END") }) else { return }
        try key("\r", code: 36)
        let bracketHex = bracketPayload.utf8.map { String(format: "%02x", $0) }.joined()
        let bracketResult = "ZLEHEX:" + bracketHex + ":ZLEDONE"
        XCTAssertLessThan(bracketResult.count, Int(session.screen.width()))
        guard observed("ZLE accepted exact UTF8 including literal tab", {
            transcript().contains(bracketResult)
        }) else { return }
        guard observed("ZLE disabled bracketed paste after acceptance", {
            !session.screen.terminalBracketedPasteMode
        }) else { return }
    }

    func testNativePastePreservesMalayalamAcrossBracketModeChanges() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["QuickPasteBytesPerCall": 8192,
            "AlwaysWarnBeforePastingOverSize": -1, "StripZeroWidthFormatCharactersOnPaste": false,
            "SavePasteHistory": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "native paste callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, _, _, _) = try fixture(initialText: "ചരിത്രം\r\nCLI ക്ഷ മലയാളം")
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_CHARACTER_ENCODING] = String.Encoding.utf8.rawValue
        profile[KEY_ALLOW_PASTE_BRACKETING] = true
        session.setPreferencesFromAddressBookEntry(profile)
        XCTAssertEqual(session.screen.terminalEncoding, String.Encoding.utf8.rawValue)
        XCTAssertTrue(session.screen.terminalAllowPasteBracketing)
        let payload = "CLI ക്ഷ മലയാളം ന്\u{200D} end"
        let width = session.screen.width()
        let height = session.screen.height()
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let rows = (0..<session.screen.numberOfLines()).map { row -> (Data, Int32) in
            let source = session.screen.screenCharArray(forLine: row)
            return (Data(bytes: source.line, count: Int(width) * MemoryLayout<screen_char_t>.stride), source.eol)
        }
        // Covers each short mode transition, including repeated enable and repeated disable.
        for enabled in [false, false, true, true, false, true] {
            session.writes.removeAll()
            feed(enabled ? "\u{1b}[?2004h" : "\u{1b}[?2004l", to: session)
            XCTAssertEqual(session.screen.terminalBracketedPasteMode, enabled)
            XCTAssertTrue(session.writes.isEmpty, "changing paste mode must not send input")
            // Same post-clipboard entry used by normal Paste, with the real helper and zero flags.
            session.paste(payload, flags: [])
            let expected = enabled ? "\u{1b}[200~" + payload + "\u{1b}[201~" : payload
            XCTAssertEqual(session.writes.count, 1, "short paste must complete in one synchronous chunk")
            XCTAssertEqual(Data(session.writes.joined().utf8), Data(expected.utf8))
            XCTAssertFalse(session.isPasting())
            XCTAssertEqual(session.screen.cursorX(), cursor.0)
            XCTAssertEqual(session.screen.cursorY(), cursor.1)
            XCTAssertEqual(session.screen.width(), width)
            XCTAssertEqual(session.screen.height(), height)
            XCTAssertEqual(Int(session.screen.numberOfLines()), rows.count)
            for (row, original) in rows.enumerated() {
                let source = session.screen.screenCharArray(forLine: Int32(row))
                XCTAssertEqual(Data(bytes: source.line, count: Int(width) * MemoryLayout<screen_char_t>.stride), original.0)
                XCTAssertEqual(source.eol, original.1)
            }
        }
    }

    func testGridRowIdentityKeepsSemanticCellsAcrossShortEventSequences() throws {
        VT100LineInfoEnableGenerationTracking()
        enum Event: CaseIterable { case scroll, clean, redraw, copy, edit }
        for first in Event.allCases {
            for second in Event.allCases {
                for third in Event.allCases {
                    let trace = [first, second, third]
                    let source = try XCTUnwrap(VT100Grid(size: VT100GridSizeMake(5, 4), delegate: nil))
                    let destination = try XCTUnwrap(VT100Grid(size: VT100GridSizeMake(5, 4), delegate: nil))
                    let history = LineBuffer(blockSize: 1000)
                    var model = [[UInt16]]()
                    for row: Int32 in 0..<4 {
                        var cell = screen_char_t()
                        cell.code = UInt16(65 + row)
                        source.setCharsFrom(VT100GridCoordMake(0, row), to: VT100GridCoordMake(4, row),
                                            to: cell, externalAttributes: nil)
                        model.append(Array(repeating: cell.code, count: 5) + [UInt16(EOL_HARD)])
                    }
                    source.markAllCharsDirty(false, updateTimestamps: false)
                    source.isAllDirty = true
                    var semanticsByGeneration = [Int64: [UInt16]]()
                    var editCode: UInt16 = 88
                    func observe(_ grid: VT100Grid, stage: String) {
                        for row: Int32 in 0..<4 {
                            let cells = grid.screenChars(atLineNumber: row)!
                            // Read actual fields, not struct padding or a renderer-derived string.
                            let semantic = (0..<5).map { cells[$0].code } + [cells[5].code]
                            XCTAssertEqual(semantic, model[Int(row)], "\(trace), \(stage), row \(row): cells/EOL")
                            let generation = grid.generation(forLine: row)
                            if let previous = semanticsByGeneration[generation] {
                                XCTAssertEqual(semantic, previous,
                                    "\(trace), \(stage), row \(row): reused generation \(generation) changed semantic cells/EOL")
                            } else { semanticsByGeneration[generation] = semantic }
                        }
                    }
                    func frame(_ stage: String) {
                        observe(source, stage: stage + " source")
                        destination.copyDirty(from: source, didScroll: true)
                        observe(destination, stage: stage + " immutable copy")
                        for row: Int32 in 0..<4 {
                            XCTAssertEqual(destination.generation(forLine: row), source.generation(forLine: row))
                        }
                    }
                    frame("initial")
                    for event in trace {
                        switch event {
                        case .scroll:
                            _ = source.scrollWholeScreenUp(into: history, unlimitedScrollback: true)
                            model.removeFirst()
                            model.append(Array(repeating: UInt16(0), count: 5) + [UInt16(EOL_HARD)])
                        case .clean: source.markAllCharsDirty(false, updateTimestamps: false)
                        case .redraw: source.isAllDirty = true
                        case .copy: destination.copyDirty(from: source, didScroll: true)
                        case .edit:
                            var cell = screen_char_t()
                            cell.code = editCode
                            source.setCharsFrom(VT100GridCoordMake(2, 1), to: VT100GridCoordMake(2, 1),
                                                to: cell, externalAttributes: nil)
                            model[1][2] = editCode
                            editCode += 1
                        }
                        frame(String(describing: event))
                    }
                }
            }
        }
    }

    func testFindRevealsLaterVisualFragmentOfRetainedHardRow() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": false, "CopySelection": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "Find reveal callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 12)
        session.setSize(VT100GridSizeMake(110, 6))
        let token = "FINDME"
        let sourceText = String(repeating: "മ", count: 90) + token
        feed(sourceText + "\u{1b}[6;1H" + String(repeating: "\r\n", count: 6) + "\u{1b}[?1049h", to: session)
        XCTAssertEqual(session.screen.numberOfScrollbackLines(), 6)
        let source = session.screen.screenCharArray(forLine: 0)
        XCTAssertEqual(source.eol, Int32(EOL_HARD))
        XCTAssertEqual(source.stringValue, sourceText)
        for (offset, scalar) in token.unicodeScalars.enumerated() {
            XCTAssertEqual(UInt32(source.line[90 + offset].code), scalar.value, "independent source-column oracle")
        }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 180, height: view.compactFrame().height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(text))
        _ = text.refresh()
        let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
        scroller.userScroll = true
        view.scrollview.contentView.scroll(to: .zero)
        view.scrollview.reflectScrolledClipView(view.scrollview.contentView)
        _ = text.refresh()
        let capacity = floor((view.scrollview.contentSize.height -
            2 * CGFloat(iTermPreferences.topBottomMargins())) / text.lineHeight)
        XCTAssertEqual(capacity, 6, "legal clip must match the six-row PTY")
        let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
        XCTAssertGreaterThan(map.fragments(forSourceRow: 0).count, 6)
        func point(_ column: Int32) -> NSPoint {
            var result = text.point(for: VT100GridCoordMake(column, 0))
            result.y += text.lineHeight / 2
            return result
        }
        XCTAssertTrue(text.visibleRect.contains(point(0)), "first fragment must really be visible")
        XCTAssertFalse(text.visibleRect.contains(point(90)), "match must really be on an offscreen fragment")
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let originals = (0..<session.screen.numberOfLines()).map { row -> (Data, Int32) in
            let line = session.screen.screenCharArray(forLine: row)
            return (Data(bytes: line.line, count: 110 * MemoryLayout<screen_char_t>.stride), line.eol)
        }
        let find = try XCTUnwrap(text.findOnPageHelper.delegate)
        let range = VT100GridCoordRangeMake(90, 0, 96, 0)
        // Actual Find selection/reveal delegate boundary, not query-engine or physical keyboard coverage.
        find.find(onPageSelect: range, logicalWindow: VT100GridRangeMake(0, 0), wrapped: false)
        find.find(onPageRevealRange: range)
        _ = text.refresh()
        XCTAssertEqual(text.selectedText, token)
        XCTAssertEqual(text.selection.selectedIndexes(onAbsoluteLine: session.screen.totalScrollbackOverflow()),
                       IndexSet(integersIn: 90..<96))
        for column: Int32 in 90..<96 {
            XCTAssertTrue(text.visibleRect.contains(point(column)), "Find must reveal actual matched fragment, column \(column)")
        }
        XCTAssertEqual(session.screen.width(), 110)
        XCTAssertEqual(session.screen.height(), 6)
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertEqual(Int(session.screen.numberOfLines()), originals.count)
        for (row, original) in originals.enumerated() {
            let line = session.screen.screenCharArray(forLine: Int32(row))
            XCTAssertEqual(Data(bytes: line.line, count: 110 * MemoryLayout<screen_char_t>.stride), original.0)
            XCTAssertEqual(line.eol, original.1)
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testMarginRefreshWithParagraphHistoryInSixRowClip() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": true,
                        "ExtendBackgroundColorIntoMargins": true]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "paragraph margin callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 30)
        session.setSize(VT100GridSizeMake(110, 6))
        // Establish the real layout before enabling the ordinary margin refresh.
        text.marginColorAllowed = false
        let phrase = "കേരനിരകളാടും ഹരിത".replacingOccurrences(of: " ", with: "\u{1b}[1C")
        let rowText = Array(repeating: phrase, count: 9).joined(separator: "\u{1b}[1C")
        feed(String(repeating: "\u{1b}[3G" + rowText + "\r\n", count: 8) +
             String(repeating: "\r\n", count: 6) + "\u{1b}[?1049h", to: session)
        XCTAssertGreaterThanOrEqual(session.screen.numberOfScrollbackLines(), 8)
        for row in 0..<8 {
            XCTAssertEqual(session.screen.screenCharArray(forLine: Int32(row)).eol, Int32(EOL_HARD))
        }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800,
                                                height: view.compactFrame().height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        _ = text.refresh()
        let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
        scroller.userScroll = true
        view.scrollview.contentView.scroll(to: .zero)
        view.scrollview.reflectScrolledClipView(view.scrollview.contentView)
        _ = text.refresh()
        let capacity = floor((view.scrollview.contentSize.height -
            2 * CGFloat(iTermPreferences.topBottomMargins())) / text.lineHeight)
        XCTAssertEqual(capacity, 6, "the native clip must fit the actual six-row PTY")
        let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
        let paragraph = try XCTUnwrap(map.fragments(forSourceRow: 0).first?.paragraph)
        XCTAssertEqual(paragraph.rows.count, 8)
        XCTAssertTrue(map.fragments(forSourceRow: 7).first?.paragraph === paragraph)
        let clip = view.scrollview.contentView.bounds
        let first = text.drawingHelper.sourceRow(forDisplayRow: Int32(floor(clip.minY / text.lineHeight)))
        let last = map.lastSourceRow(atDisplayRow: Int(floor((clip.maxY - 0.001) / text.lineHeight)))
        XCTAssertGreaterThan(last - Int(first) + 1, 6, "six display lines cover more than six source rows")
        text.marginColorAllowed = true
        _ = text.refresh()
        _ = text.updateMarginColor()
        XCTAssertTrue(text.marginColor.enabled.boolValue, "uniform source backgrounds must extend into margins")
        XCTAssertEqual(session.screen.width(), 110)
        XCTAssertEqual(session.screen.height(), 6)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testSelectedTextPreservesLiteralUTF8AcrossSoftAndHardHistoryRows() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": false,
            "CopySelection": false, "CopyLastNewline": false, "TrimWhitespaceOnCopy": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "literal extraction callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        XCTAssertFalse(iTermAdvancedSettingsModel.trimWhitespaceOnCopy())
        XCTAssertFalse(iTermPreferences.bool(forKey: kPreferenceKeyCopyLastNewline))
        let pasteboard = NSPasteboard(name: .init("MalayalamLiteralCopy-\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let longSuffix = String(repeating: "x", count: 110) + "  tail  "
        // Both original literal payloads retain the same extraction contract under natural wrapping.
        let variants = [
            ("  മലയാളം ന്\u{200D} 👩\u{200D}💻  " + longSuffix, "  രണ്ടാം 🙂 END  "),
            ("  മലയാളം ന്\u{200D}  " + longSuffix, "  👩\u{200D}💻 🙂 END  ")
        ]
        for (a, b) in variants {
            let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 24)
            session.setSize(VT100GridSizeMake(110, 6))
            // Independent input oracle, never reconstructed from source cells or presentation text.
            let expected = Data((a + "\n" + b).utf8)
            XCTAssertLessThanOrEqual(expected.count, Int(iTermAdvancedSettingsModel.maximumBytesToProvideToServices()))
            feed(a, to: session)
            let hardRow = session.screen.cursorY() - 1
            XCTAssertGreaterThan(hardRow, 0, "A must really cross a PTY soft boundary")
            feed("\r\n" + b, to: session)
            let end = VT100GridCoordMake(session.screen.cursorX() - 1, session.screen.cursorY() - 1)
            XCTAssertEqual(end.y, hardRow + 1)
            XCTAssertLessThan(end.y, 5, "the complete input must fit before history retention")
            let originals = (0...end.y).map { row -> (Data, Int32) in
                let source = session.screen.screenCharArray(forLine: row)
                return (Data(bytes: source.line, count: 110 * MemoryLayout<screen_char_t>.stride), source.eol)
            }
            for row in 0..<hardRow { XCTAssertEqual(originals[Int(row)].1, Int32(EOL_SOFT)) }
            XCTAssertEqual(originals[Int(hardRow)].1, Int32(EOL_HARD))
            XCTAssertEqual(originals[Int(end.y)].1, Int32(EOL_HARD))
            feed("\u{1b}[6;1H" + String(repeating: "\r\n", count: 6) + "\u{1b}[?1049h", to: session)
            XCTAssertEqual(session.screen.numberOfScrollbackLines(), 6)
            XCTAssertGreaterThan(session.screen.numberOfScrollbackLines(), end.y)
            let cursor = (session.screen.cursorX(), session.screen.cursorY())
            let height = view.compactFrame().height
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            _ = text.refresh()
            let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
            scroller.userScroll = true
            view.scrollview.contentView.scroll(to: .zero)
            view.scrollview.reflectScrolledClipView(view.scrollview.contentView)
            _ = text.refresh()
            let overflow = session.screen.totalScrollbackOverflow()
            text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                VT100GridAbsCoordRangeMake(0, overflow, end.x, overflow + Int64(end.y)), 0, 0),
                mode: .kiTermSelectionModeCharacter)
            // Resize only the presentation. Keep the same source selection through both reflows.
            for width: CGFloat in [800, 260, 800] {
                view.setFrameSize(NSSize(width: width, height: height))
                _ = text.refresh()
                let capacity = floor((view.scrollview.contentSize.height -
                    2 * CGFloat(iTermPreferences.topBottomMargins())) / text.lineHeight)
                XCTAssertEqual(capacity, 6)
                let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
                if width == 260 { XCTAssertGreaterThan(map.fragments(forSourceRow: 0).count, 1) }
                let copied = try XCTUnwrap(text.selectedText)
                XCTAssertEqual(Data(copied.utf8), expected, "literal bytes, including explicit spaces, width \(width)")
                XCTAssertNotEqual(Data(copied.utf8), Data((a + b).utf8), "negative oracle: omitting the HARD newline changes the contract")
                // Production Services export, not Command-C routing or the user's general clipboard.
                let wrote = (text as AnyObject).writeSelection?(to: pasteboard, types: [NSPasteboard.PasteboardType.string])
                XCTAssertEqual(wrote, true)
                XCTAssertEqual(try XCTUnwrap(pasteboard.data(forType: .string)), expected)
                XCTAssertEqual(session.screen.width(), 110)
                XCTAssertEqual(session.screen.height(), 6)
                XCTAssertEqual(session.screen.cursorX(), cursor.0)
                XCTAssertEqual(session.screen.cursorY(), cursor.1)
                for (row, original) in originals.enumerated() {
                    let source = session.screen.screenCharArray(forLine: Int32(row))
                    XCTAssertEqual(Data(bytes: source.line, count: 110 * MemoryLayout<screen_char_t>.stride), original.0)
                    XCTAssertEqual(source.eol, original.1)
                }
                XCTAssertTrue(session.writes.isEmpty)
            }
        }
    }

    func testMixedMalayalamEmojiKeepsNaturalHistoryGeometryAndSourceCells() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": false,
            "CopySelection": false, "CopyLastNewline": false, "TrimWhitespaceOnCopy": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "mixed emoji geometry callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 12)
        session.setSize(VT100GridSizeMake(110, 6))
        let literal = "മലയാളം 👩🏽\u{200D}💻🙂 🌶\u{FE0F} 🌶\u{FE0E} 🇮🇳 1\u{FE0F}\u{20E3} END " + String(repeating: "മ", count: 24)
        feed(literal, to: session)
        XCTAssertEqual(session.screen.cursorY(), 1, "mixed input must fit one real source row")
        let endColumn = session.screen.cursorX() - 1
        let original = session.screen.screenCharArray(forLine: 0)
        let bytes = Data(bytes: original.line, count: 110 * MemoryLayout<screen_char_t>.stride)
        XCTAssertEqual(original.eol, Int32(EOL_HARD))
        let rightHalves = (0..<Int(endColumn)).filter { ScreenCharIsDWC_RIGHT(original.line[$0]) }
        XCTAssertGreaterThanOrEqual(rightHalves.count, 2, "real terminal wide-cell aliases must be present")
        feed("\u{1b}[6;1H" + String(repeating: "\r\n", count: 6) + "\u{1b}[?1049h", to: session)
        XCTAssertEqual(session.screen.numberOfScrollbackLines(), 6)
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let height = view.compactFrame().height
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        _ = text.refresh()
        let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
        scroller.userScroll = true
        view.scrollview.contentView.scroll(to: .zero)
        view.scrollview.reflectScrolledClipView(view.scrollview.contentView)
        _ = text.refresh()
        for width: CGFloat in [800, 260] {
            view.setFrameSize(NSSize(width: width, height: height))
            _ = text.refresh()
            // Desired mixed-row support: current source rejects supplementary emoji before this point.
            let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
            let layout = try XCTUnwrap(map.sourceLayout(forRow: 0))
            XCTAssertEqual(Data(layout.attributedString.string.utf8), Data(literal.utf8))
            XCTAssertEqual(layout.cellUTF16Boundaries.count, 111)
            let utf16 = layout.attributedString.string as NSString
            for value in layout.cellUTF16Boundaries {
                let offset = value.intValue
                if offset > 0 && offset < utf16.length {
                    XCTAssertFalse(CFStringIsSurrogateHighCharacter(utf16.character(at: offset - 1)) &&
                        CFStringIsSurrogateLowCharacter(utf16.character(at: offset)), "no cell boundary splits a surrogate pair")
                }
            }
            for column in rightHalves {
                XCTAssertEqual(layout.cellUTF16Boundaries[column], layout.cellUTF16Boundaries[column + 1],
                    "DWC_RIGHT remains an empty source alias, not a manufactured half-width")
            }
            let pieces = map.fragments(forSourceRow: 0)
            if width == 260 { XCTAssertGreaterThan(pieces.count, 1) }
            let independent = CTLineCreateWithAttributedString(layout.attributedString)
            for emoji in ["👩🏽\u{200D}💻", "🙂", "🌶\u{FE0F}", "🌶\u{FE0E}", "🇮🇳", "1\u{FE0F}\u{20E3}"] {
                let range = (literal as NSString).range(of: emoji)
                let first = try XCTUnwrap(layout.cellUTF16Boundaries.firstIndex(of: NSNumber(value: range.location)))
                let last = try XCTUnwrap(layout.cellUTF16Boundaries.lastIndex(of: NSNumber(value: NSMaxRange(range))))
                for (column, offset) in [(first, range.location), (last, NSMaxRange(range))] {
                    let projection = try XCTUnwrap(layout.projection(atColumn: column))
                    XCTAssertEqual(projection.kind, .nativeEdge, "only actual emoji cluster endpoints require carets")
                    let edge = try XCTUnwrap(projection.nativeEdge)
                    var secondary: CGFloat = 0
                    let primary = CTLineGetOffsetForStringIndex(independent, offset, &secondary)
                    XCTAssertTrue(abs(edge.x - primary) < 0.001 || abs(edge.x - secondary) < 0.001)
                    let hit = try XCTUnwrap(layout.hitTest(nativeX: edge.x))
                    XCTAssertTrue(hit.logicalColumns.contains(NSNumber(value: column)))
                }
                for piece in pieces {
                    let overlap = NSIntersectionRange(piece.sourceRange, range)
                    XCTAssertTrue(overlap.length == 0 || overlap == range, "visual wrap must not split an emoji cluster")
                }
            }
            let overflow = session.screen.totalScrollbackOverflow()
            text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                VT100GridAbsCoordRangeMake(0, overflow, endColumn, overflow), 0, 0), mode: .kiTermSelectionModeCharacter)
            XCTAssertEqual(Data(try XCTUnwrap(text.selectedText).utf8), Data(literal.utf8))
            text.selection.clear()
            _ = try renderedBitmap(text, row: 0, name: "mixed-emoji-native-history-\(Int(width))")
            let current = session.screen.screenCharArray(forLine: 0)
            XCTAssertEqual(Data(bytes: current.line, count: 110 * MemoryLayout<screen_char_t>.stride), bytes)
            XCTAssertEqual(current.eol, Int32(EOL_HARD))
            XCTAssertEqual(session.screen.cursorX(), cursor.0)
            XCTAssertEqual(session.screen.cursorY(), cursor.1)
            XCTAssertEqual(session.screen.width(), 110)
            XCTAssertEqual(session.screen.height(), 6)
            let capacity = floor((view.scrollview.contentSize.height -
                2 * CGFloat(iTermPreferences.topBottomMargins())) / text.lineHeight)
            XCTAssertEqual(capacity, 6)
            XCTAssertTrue(session.writes.isEmpty)
        }
        // Supplementary letters remain outside the admitted common-symbol policy.
        feed("\u{1b}[Hമലയാളം \u{10400}", to: session)
        _ = text.refresh()
        XCTAssertNotNil(text.drawingHelper.malayalamDisplayMap, "unsupported script is local to its grid row")
        XCTAssertNil(text.drawingHelper.malayalamLayout(atLine: session.screen.numberOfScrollbackLines()))
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testUnsupportedRowsKeepNeighboringMalayalamWrapped() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["MalayalamVisualWrap", "MalayalamParagraphFlow", "CopySelection", "CopyLastNewline"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            let drained = expectation(description: "row-local callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        defaults.set(true, forKey: keys[0])
        defaults.set(false, forKey: keys[2])
        defaults.set(false, forKey: keys[3])
        let prose = String(repeating: "മ", count: 90)
        for paragraph in [false, true] {
            defaults.set(paragraph, forKey: keys[1])
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            let (session, view, text, _) = try fixture(initialText: "")
            var profile = try XCTUnwrap(session.profile)
            profile[KEY_SCROLLBACK_IN_ALTERNATE_SCREEN] = false
            session.setPreferencesFromAddressBookEntry(profile)
            session.setSize(VT100GridSizeMake(110, 6))
            let height = view.compactFrame().height
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: height),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            windows.append(window)
            feed("\u{1b}[?1049h", to: session)
            let helper = try XCTUnwrap(text.drawingHelper)
            try prefixes([], depth: 3, eventCount: 3) { events in
                var kind = 0
                var narrow = true
                var scrolled = false
                for event in [-1] + events {
                    if event == 0 { kind = (kind + 1) % 3 }
                    if event == 1 { narrow.toggle() }
                    if event == 2 { scrolled.toggle() }
                    view.setFrameSize(NSSize(width: narrow ? 260 : 400, height: height))
                    let middle = "ROW മലയാളം" + (kind == 2 ? " \u{10400}" : "")
                    feed("\u{1b}[0m\u{1b}[H\u{1b}[2J" + prose + "\u{1b}[2;1H" +
                         (kind == 1 ? "\u{1b}[5m" : "") + middle + "\u{1b}[0m\u{1b}[3;1H" + prose + "\u{1b}[6;1H", to: session)
                    let base = session.screen.numberOfScrollbackLines()
                    XCTAssertEqual(session.screen.width(), 110)
                    let source = (0..<session.screen.numberOfLines()).map { session.screen.screenCharArray(forLine: $0).data }
                    let cursor = (session.screen.cursorX(), session.screen.cursorY())
                    _ = text.refresh()
                    let map = try XCTUnwrap(helper.malayalamDisplayMap, "paragraph=\(paragraph), events=\(events), kind=\(kind)")
                    XCTAssertGreaterThan(map.fragments(forSourceRow: Int(base)).count, 1)
                    XCTAssertGreaterThan(map.fragments(forSourceRow: Int(base + 2)).count, 1)
                    let pieces = map.fragments(forSourceRow: Int(base + 1))
                    if kind != 0 { XCTAssertEqual(pieces.count, 1) }
                    XCTAssertEqual(pieces[0].layout == nil, kind != 0)
                    let clip = view.scrollview.contentView
                    (view.scrollview.verticalScroller as? PTYScroller)?.userScroll = true
                    clip.scroll(to: NSPoint(x: 0, y: scrolled ? text.lineHeight : 0))
                    view.scrollview.reflectScrolledClipView(clip)
                    let cold = try XCTUnwrap(text.perform(NSSelectorFromString("newDrawingHelperForOffscreenRendering"))?
                        .takeRetainedValue() as? iTermTextDrawingHelper)
                    cold.didFinishSetup()
                    for row: Int32 in [base, base + 1, base + 2] {
                        let actual = helper.malayalamLayout(atLine: row)
                        let expected = cold.malayalamLayout(atLine: row)
                        XCTAssertEqual(actual?.attributedString, expected?.attributedString)
                        XCTAssertEqual(actual?.cellUTF16Boundaries, expected?.cellUTF16Boundaries)
                    }
                    let builds = helper.malayalamRowLayoutBuildCount
                    _ = text.refresh()
                    XCTAssertEqual(helper.malayalamRowLayoutBuildCount, builds)
                    let absolute = Int64(base) + session.screen.totalScrollbackOverflow()
                    text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                        VT100GridAbsCoordRangeMake(0, absolute, 90, absolute + 2), 0, 0), mode: .kiTermSelectionModeCharacter)
                    XCTAssertEqual(text.selectedText, prose + "\n" + middle + "\n" + prose)
                    text.selection.clear()
                    XCTAssertEqual((0..<session.screen.numberOfLines()).map { session.screen.screenCharArray(forLine: $0).data }, source)
                    XCTAssertEqual(session.screen.cursorX(), cursor.0)
                    XCTAssertEqual(session.screen.cursorY(), cursor.1)
                    XCTAssertTrue(session.writes.isEmpty)
                }
            }
            // Invalid selector contexts stay unsupported, but cannot disable their neighbors.
            for invalid in ["A\u{FE0F}", "\u{FE0E}", "A\u{20E3}"] {
                feed("\u{1b}[2;1H\u{1b}[2Kമലയാളം " + invalid, to: session)
                _ = text.refresh()
                XCTAssertNil(helper.malayalamLayout(atLine: session.screen.numberOfScrollbackLines() + 1))
                XCTAssertNotNil(helper.malayalamDisplayMap)
            }
            feed("\u{1b}[2;1H\u{1b}[2K│ മലയാളം \u{10400} │", to: session)
            _ = text.refresh()
            XCTAssertNil(helper.malayalamDisplayMap, "failed boxed-table preparation cannot mix shared geometry")
        }
    }

    func testTextDragCopiesOriginalParagraphHistoryAcrossUpdates() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": true,
                                       "CopySelection": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            let drained = expectation(description: "history drag callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, view, text, _) = try fixture(initialText: "", scrollbackLines: 12)
        session.setSize(VT100GridSizeMake(110, 6))
        let phrase = "കേരനിരകളാടും ഹരിത".replacingOccurrences(of: " ", with: "\u{1b}[1C")
        let first = Array(repeating: phrase, count: 9).joined(separator: "\u{1b}[1C")
        let second = Array(repeating: phrase, count: 7).joined(separator: "\u{1b}[1C")
        feed("\u{1b}[1;3H" + first + "\u{1b}[2;3H" + second + "\u{1b}[6;1H" +
             String(repeating: "\r\n", count: 6) + "\u{1b}[?1049h", to: session)
        XCTAssertEqual(session.screen.numberOfScrollbackLines(), 6, "the paragraph must really reside in retained history")
        let original = (0..<2).map { session.screen.screenCharArray(forLine: Int32($0)) }
        XCTAssertEqual(original.map { $0.eol }, [Int32(EOL_HARD), Int32(EOL_HARD)])
        let bytes = original.map { Data(bytes: $0.line, count: 110 * MemoryLayout<screen_char_t>.stride) }
        // Stop inside the second source row so both drag endpoints fit the six-line clip.
        let endColumn = 3
        func sourceSlice(_ row: Int, _ range: Range<Int>) -> String {
            range.map { column in
                let cell = original[row].line.advanced(by: column)
                return cell.pointee.code == 0 ? " " : (ScreenCharToStr(cell) ?? "")
            }.joined()
        }
        // Independent original HARD-row/cell oracle, not the joined paragraph display string.
        let expected = sourceSlice(0, 3..<110).trimmingCharacters(in: .whitespaces) + "\n" +
                       sourceSlice(1, 0..<endColumn)
        let frameHeight = view.compactFrame().height
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: frameHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(text))
        var eventNumber = 100
        var dragContext = ""
        func mouse(_ kind: NSEvent.EventType, column: Int32, row: Int32) throws {
            _ = text.refresh()
            var point = text.point(for: VT100GridCoordMake(column, row))
            point.y += text.lineHeight / 2
            let clip = view.scrollview.contentView.bounds
            let piece = text.drawingHelper.malayalamDisplayMap?.fragment(forColumn: Int(column), sourceRow: Int(row))
            let firstVisible = text.drawingHelper.sourceRow(forDisplayRow: Int32(floor(clip.minY / text.lineHeight)))
            XCTAssertTrue(text.visibleRect.contains(point),
                "\(dragContext) stage=\(kind) source=(\(column),\(row)) point=\(point) visible=\(text.visibleRect) " +
                "clip=\(clip) fragment=\(String(describing: piece?.displayRow)) firstVisibleSource=\(firstVisible)")
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: text.convert(point, to: nil),
                modifierFlags: [], timestamp: Double(eventNumber), windowNumber: window.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 1))
            eventNumber += 1
            switch kind {
            case .leftMouseDown: text.mouseDown(with: event)
            case .leftMouseDragged: text.mouseDragged(with: event)
            default: text.mouseUp(with: event)
            }
        }
        // All short pairs of viewport reflow and addressed output, in both drag directions.
        for before in 0..<2 {
            for during in 0..<2 {
                for reverse in [false, true] {
                    dragContext = "before=\(before) during=\(during) reverse=\(reverse)"
                    text.selection.clear()
                    var narrow = false
                    view.setFrameSize(NSSize(width: 800, height: frameHeight))
                    _ = text.refresh()
                    let scroller = try XCTUnwrap(view.scrollview.verticalScroller as? PTYScroller)
                    scroller.userScroll = true
                    view.scrollview.contentView.scroll(to: .zero)
                    view.scrollview.reflectScrolledClipView(view.scrollview.contentView)
                    func update(_ event: Int) {
                        if event == 0 {
                            narrow.toggle()
                            view.setFrameSize(NSSize(width: narrow ? 560 : 800, height: frameHeight))
                        } else { feed("\u{1b}[4;1HSTATUS\u{1b}[6;1H", to: session) }
                        _ = text.refresh()
                        let capacity = floor((view.scrollview.contentSize.height -
                            2 * CGFloat(iTermPreferences.topBottomMargins())) / text.lineHeight)
                        XCTAssertEqual(capacity, 6, "native clip must match the six-row PTY, including footer reservation")
                    }
                    update(before)
                    let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
                    let group = try XCTUnwrap(map.fragments(forSourceRow: 0).first?.paragraph)
                    XCTAssertTrue(map.fragments(forSourceRow: 1).first?.paragraph === group)
                    // Column three is a visible cluster edge, not the collapsed indent aliases at zero through two.
                    let start: (Int32, Int32) = reverse ? (Int32(endColumn), 1) : (3, 0)
                    let end: (Int32, Int32) = reverse ? (3, 0) : (Int32(endColumn), 1)
                    try mouse(.leftMouseDown, column: start.0, row: start.1)
                    XCTAssertTrue(text.selection.live, "test must enter the production text-drag path")
                    update(during)
                    try mouse(.leftMouseDragged, column: end.0, row: end.1)
                    try mouse(.leftMouseUp, column: end.0, row: end.1)
                    XCTAssertFalse(text.selection.live)
                    XCTAssertEqual(text.selectedText, expected, "before=\(before), during=\(during), reverse=\(reverse)")
                    for row in 0..<2 {
                        let current = session.screen.screenCharArray(forLine: Int32(row))
                        XCTAssertEqual(Data(bytes: current.line, count: 110 * MemoryLayout<screen_char_t>.stride), bytes[row])
                        XCTAssertEqual(current.eol, Int32(EOL_HARD))
                    }
                    XCTAssertEqual(session.screen.width(), 110)
                    XCTAssertEqual(session.screen.height(), 6)
                    XCTAssertTrue(session.writes.isEmpty, "ordinary local copy must not send terminal input")
                }
            }
        }
    }

    func testUnderlinedMalayalamHeadingKeepsNaturalGeometryAndDecoration() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let saved = defaults.object(forKey: "MalayalamVisualWrap")
        defer {
            if let saved { defaults.set(saved, forKey: "MalayalamVisualWrap") }
            else { defaults.removeObject(forKey: "MalayalamVisualWrap") }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        defer {
            // Match the visual-wrap fixture: drain queued margin updates before session teardown.
            let drained = expectation(description: "fixture refresh callbacks drained")
            DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
            wait(for: [drained], timeout: 5)
        }
        defaults.set(true, forKey: "MalayalamVisualWrap")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        func check(_ events: [Int]) throws {
            let (session, view, text, _) = try fixture(initialText: "")
            // Synthetic sessions need each used palette entry before any indexed text can draw.
            let helper = try XCTUnwrap(text.drawingHelper)
            let colors = try XCTUnwrap(helper.colorMap as? iTermColorMap)
            colors.setColor(.white, forKey: Int32(kColorMapForeground))
            colors.setColor(.black, forKey: Int32(kColorMapBackground))
            colors.setColor(.white, forKey: Int32(kColorMapBold))
            colors.setColor(.black, forKey: Int32(kColorMapSelection))
            colors.setColor(.white, forKey: Int32(kColorMapSelectedText))
            colors.setColor(.white, forKey: Int32(kColorMap8bitBase + 231))
            colors.setColor(.green, forKey: Int32(kColorMap8bitBase + 2))
            colors.setColor(.green, forKey: Int32(kColorMap8bitBase + 10))
            colors.setColor(.red, forKey: Int32(kColorMapUnderline))
            feed(String(repeating: "HISTORY\r\n", count: 7) + "\u{1b}[?1049h\u{1b}[2J", to: session)
            let row = session.screen.numberOfScrollbackLines()
            XCTAssertGreaterThan(row, 0, "heading must keep full-document mapping with retained history")
            var underlined = true
            var styled = true
            var narrow = false
            var selection = 0
            var colored = false
            for (index, event) in ([-1] + events).enumerated() {
                switch event {
                case 0: underlined.toggle()
                case 1: styled.toggle()
                case 2:
                    narrow.toggle()
                    view.setFrameSize(NSSize(width: narrow ? 130 : 640, height: view.frame.height))
                case 3: selection = (selection + 1) % 3
                case 4: colored.toggle()
                default: break
                }
                let style = "\u{1b}[0m" + (styled ? "\u{1b}[1;3m" : "") + (underlined ? "\u{1b}[4m" : "")
                let title = colored ? "കേരളപ്\u{1b}[32mപിറവി\u{1b}[39m" : "കേരളപ്പിറവി"
                feed("\u{1b}[1;1H\u{1b}[2K\u{1b}[38;5;231m⏺\u{1b}[0m\u{1b}[1;3H" + style +
                     title + "\u{1b}[0m\u{1b}[2;1HASCII\u{1b}[6;1H", to: session)
                let source = session.screen.screenCharArray(forLine: row)
                XCTAssertEqual(source.stringValueIncludingEmbeddedNulls, "⏺\0കേരളപ്പിറവി")
                XCTAssertEqual(source.line[1].code, 0, "captured spacer stays an actual NUL cell")
                for column in 2..<9 {
                    XCTAssertEqual(source.line[column].bold, styled ? 1 : 0)
                    XCTAssertEqual(source.line[column].italic, styled ? 1 : 0)
                    XCTAssertEqual(source.line[column].underline, underlined ? 1 : 0)
                }
                let originalCells = source.data
                if selection > 0 {
                    let absolute = Int64(row) + session.screen.totalScrollbackOverflow()
                    let first: Int32 = selection == 1 ? 2 : 5
                    let end: Int32 = selection == 1 ? 9 : 6
                    text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                        VT100GridAbsCoordRangeMake(first, absolute, end, absolute), 0, 0), mode: .kiTermSelectionModeCharacter)
                    XCTAssertEqual(text.selectedText, selection == 1 ? "കേരളപ്പിറവി" : "പ്")
                } else { text.selection.clear() }
                _ = text.refresh()
                let layout = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: row), "single underline must not force grid fallback")
                let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap, "one heading must not disable the full document map")
                let pieces = map.fragments(forSourceRow: Int(row))
                XCTAssertFalse(pieces.isEmpty)
                let recovered = pieces.map { layout.attributedString.attributedSubstring(from: $0.sourceRange).string }.joined()
                XCTAssertEqual(recovered, "⏺ കേരളപ്പിറവി")
                let left = try XCTUnwrap(layout.projection(atColumn: 2)?.nativeEdge)
                let right = try XCTUnwrap(layout.projection(atColumn: 9)?.nativeEdge)
                // Paint representative endpoint states; every prefix still checks source and geometry.
                if index == events.count && (events.isEmpty || events == [0] || events == [2] || events == [3, 3, 4]) {
                    let bitmap = try renderedBitmap(text, row: row, includeSelection: selection > 0, name: "heading-\(events)-\(event)")
                    var redXs = [Int]()
                    var bands = 0
                    var previousRed = false
                    for y in 0..<bitmap.pixelsHigh {
                        var rowRed = false
                        for x in 0..<bitmap.pixelsWide {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                            if color.redComponent > 0.5 && color.greenComponent < 0.2 && color.blueComponent < 0.2 {
                                rowRed = true
                                redXs.append(x)
                            }
                        }
                        if rowRed && !previousRed { bands += 1 }
                        previousRed = rowRed
                    }
                    if underlined {
                        let titleRange = NSRange(location: 2, length: "കേരളപ്പിറവി".utf16.count)
                        let decoratedPieces = pieces.filter { NSIntersectionRange($0.sourceRange, titleRange).length > 0 }.count
                        XCTAssertGreaterThanOrEqual(bands, decoratedPieces, "every decorated natural fragment must paint its underline")
                        if pieces.count == 1 {
                            let scale = CGFloat(bitmap.pixelsWide) / text.frame.width
                            let origin = CGFloat(iTermPreferences.sideMargins()) + pieces[0].originX
                            XCTAssertEqual(CGFloat(try XCTUnwrap(redXs.min())) / scale, origin + left.x, accuracy: 2)
                            XCTAssertEqual(CGFloat(try XCTUnwrap(redXs.max())) / scale, origin + right.x, accuracy: 2)
                        }
                    } else { XCTAssertTrue(redXs.isEmpty, "removing underline must remove its pixels") }
                }
                XCTAssertEqual(session.screen.screenCharArray(forLine: row).data, originalCells,
                               "drawing and selection must preserve heading source/style cells")
                XCTAssertTrue(session.writes.isEmpty)
            }
            // Unsupported variants remain explicit fallback, then ordinary single underline recovers.
            feed("\u{1b}[1;3H\u{1b}[4:3mകേരളപ്പിറവി\u{1b}[0m", to: session)
            _ = text.refresh()
            XCTAssertNil(text.drawingHelper.malayalamLayout(atLine: row))
            XCTAssertNotNil(text.drawingHelper.malayalamDisplayMap, "curly underline stays local")
            feed("\u{1b}[1;3H\u{1b}[4mകേരളപ്പിറവി\u{1b}[0m", to: session)
            _ = text.refresh()
            XCTAssertNotNil(text.drawingHelper.malayalamDisplayMap)
        }
        try prefixes([], depth: 2, eventCount: 5, check: check)
        try check([3, 3, 4])
    }

    func testInactiveFooterSelectionRevealsOverflowAcrossStateChanges() throws {
        let (session, view, text, footer) = try fixture(initialText: String(repeating: "മ", count: 18) + "Z\r\n")
        let row = session.screen.numberOfScrollbackLines()
        let absolute = Int64(row) + session.screen.totalScrollbackOverflow()
        let original = try XCTUnwrap(session.screen.screenCharArray(forLine: row)).stringValue
        let margin = CGFloat(iTermPreferences.sideMargins())
        let initialLayout = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: row))
        let nativeLine = CTLineCreateWithAttributedString(initialLayout.attributedString)
        let nativeLeft = CTLineGetOffsetForStringIndex(nativeLine, 18, nil)
        let nativeRight = CTLineGetOffsetForStringIndex(nativeLine, 19, nil)
        let narrow = max(80, nativeRight / 2)
        XCTAssertGreaterThan(nativeLeft, narrow, "fixture must really overflow before selecting")

        // All short prefixes of selection, clear, viewport resize, mode and cursor changes.
        func check(_ events: [Int]) throws {
            var columns = IndexSet()
            var inspected = false
            var enabled = true
            var active = false
            var width = narrow
            session.setSize(VT100GridSizeMake(40, 6))
            text.selection.clear()
            iTermUserDefaults.userDefaults().set(true, forKey: "MalayalamNaturalRows")
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
            feed("\u{1b}[2;1H", to: session)
            func projectedLeft() throws -> CGFloat {
                let helper = try XCTUnwrap(text.drawingHelper)
                let frame = NSRect(x: 0, y: 0, width: width, height: 200)
                helper.configureForOffscreenRendering(withFrame: frame, visibleRect: frame,
                    renderedRows: NSRange(location: Int(row), length: 1))
                return CGFloat(try XCTUnwrap(helper.malayalamX(forColumn: 18, line: row)).doubleValue)
            }
            for event in events {
                switch event {
                case 0:
                    if enabled {
                        // Choose the output row, then dispatch through the existing real footer.
                        text.selectMalayalamColumn(0, absoluteRow: absolute)
                        drawNotification(text)
                        let cursor = (session.screen.cursorX(), session.screen.cursorY())
                        try click(footer, column: 18)
                        columns = IndexSet(integer: 18)
                        inspected = true
                        XCTAssertEqual(session.screen.cursorX(), cursor.0)
                        XCTAssertEqual(session.screen.cursorY(), cursor.1)
                    }
                case 1: text.selection.clear(); columns = IndexSet(); inspected = false
                case 2: width = width == narrow ? nativeRight + 2 * margin + 20 : narrow
                case 3: enabled.toggle(); if !enabled { inspected = false }
                case 4: active.toggle(); feed(active ? "\u{1b}[1;20H" : "\u{1b}[2;1H", to: session)
                case 5:
                    let range = VT100GridAbsWindowedRangeMake(
                        VT100GridAbsCoordRangeMake(18, absolute, 19, absolute), 0, 0)
                    text.selection.setSelectedLogicalRange(range, mode: .kiTermSelectionModeCharacter)
                    columns = IndexSet(integer: 18); inspected = false
                case 6:
                    session.setSize(VT100GridSizeMake(session.screen.width() == 40 ? 39 : 40, 6))
                    inspected = false
                case 7:
                    // Dragging must not follow its changing first selected column.
                    if enabled {
                        let before = try projectedLeft()
                        text.selection.begin(at: VT100GridAbsCoordMake(18, absolute),
                            mode: .kiTermSelectionModeCharacter, resume: false, append: false)
                        _ = text.selection.moveEndpoint(to: VT100GridAbsCoordMake(0, absolute))
                        XCTAssertEqual(try projectedLeft(), before, accuracy: 0.001,
                            "live drag must retain the pre-drag projection")
                        text.selection.endLive()
                        columns = IndexSet(integersIn: 0..<18); inspected = false
                    }
                default: XCTFail("unknown event")
                }
                iTermUserDefaults.userDefaults().set(enabled, forKey: "MalayalamNaturalRows")
                iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
                let helper = try XCTUnwrap(text.drawingHelper)
                let frame = NSRect(x: 0, y: 0, width: width, height: 200)
                helper.configureForOffscreenRendering(withFrame: frame, visibleRect: frame,
                    renderedRows: NSRange(location: Int(row), length: 1))
                if enabled {
                    let left = try XCTUnwrap(helper.malayalamX(forColumn: 18, line: row)).doubleValue
                    let right = try XCTUnwrap(helper.malayalamX(forColumn: 19, line: row)).doubleValue
                    if inspected || active {
                        XCTAssertGreaterThanOrEqual(left, margin, "selected glyph start must remain visible: \(events)")
                        XCTAssertLessThanOrEqual(right, width - margin - 2 + 0.001,
                            "footer selection must reveal inactive overflow: \(events)")
                    } else {
                        XCTAssertEqual(left, margin + nativeLeft, accuracy: 0.001,
                            "clearing selection must remove inactive pan")
                    }
                    XCTAssertEqual(right - left, nativeRight - nativeLeft, accuracy: 0.001,
                        "panning must not squeeze the selected glyph")
                    let hit = try XCTUnwrap(helper.malayalamColumnFor(x: left + (right - left) * 0.1, line: row))
                    XCTAssertEqual(hit.intValue, 18, "text hits must use the same projection as drawing")
                } else {
                    XCTAssertNil(helper.malayalamLayout(atLine: row), "mode off keeps the ordinary renderer")
                }
                XCTAssertEqual(text.selection.selectedIndexes(onAbsoluteLine: absolute), columns)
                if !columns.isEmpty {
                    XCTAssertEqual(text.selectedText, columns.contains(18) ? "Z" : String(repeating: "മ", count: 18))
                }
                drawNotification(text)
                XCTAssertEqual(footer.columnCount, enabled ? Int(session.screen.width()) : 0)
                XCTAssertEqual(footer.selectedColumns, enabled ? columns : IndexSet())
                XCTAssertLessThanOrEqual(footer.frame.maxY, view.scrollview.frame.minY)
                XCTAssertEqual(try XCTUnwrap(session.screen.screenCharArray(forLine: row)).stringValue, original)
                XCTAssertTrue(session.writes.isEmpty, "footer pan never writes client input")
            }
        }
        func prefixes(_ prefix: [Int], depth: Int) throws {
            try check(prefix)
            if depth > 0 { for event in 0..<8 { try prefixes(prefix + [event], depth: depth - 1) } }
        }
        try prefixes([], depth: 2)
        try check([0, 3, 3]) // Re-enabling the mode must not resurrect footer inspection.
    }

    // Parser-owned columns, including empty wide-cell aliases; omit only trailing grid padding.
    private func hindiSourceCells(_ row: ScreenCharArray) -> [String] {
        let end = (0..<Int(row.length)).reversed().first { column in
            let cell = row.line[column]
            return cell.complexChar != 0 || cell.code != 0
        }.map { $0 + 1 } ?? 0
        return (0..<end).map { column in
            let cell = row.line[column]
            if ScreenCharIsDWC_RIGHT(cell) || ScreenCharIsDWL_SPACER(cell) { return "" }
            if cell.complexChar == 0 && cell.code == 0 { return " " }
            return ScreenCharToStr(row.line.advanced(by: column)) ?? ""
        }
    }

    // Lab-only: bypass admission, but take cell ownership from the real terminal parser.
    private func hindiLayout(_ source: String) throws -> (layout: iTermMalayalamRowLayout, cells: [String]) {
        let (session, _, _, _) = try fixture(initialText: source)
        let row = try XCTUnwrap(session.screen.screenCharArray(forLine: session.screen.numberOfScrollbackLines()))
        let cells = hindiSourceCells(row)
        XCTAssertEqual(Array(cells.joined().utf8), Array(source.utf8))
        let font = try XCTUnwrap(NSFont(name: "DevanagariSangamMN", size: 20))
        let text = NSMutableAttributedString()
        var boundaries: [NSNumber] = [0]
        for cell in cells {
            text.append(NSAttributedString(string: cell, attributes: [.font: font]))
            boundaries.append(NSNumber(value: text.length))
        }
        return (try XCTUnwrap(iTermMalayalamRowLayout(attributedString: text,
            cellUTF16Boundaries: boundaries)), cells)
    }

    func testHindiSourceCellsAndProductionAdmission() throws {
        let conjunct = "क्ष"
        XCTAssertEqual(conjunct.unicodeScalars.map { $0.value }, [0x0915, 0x094D, 0x0937],
                       "conjunct is KA + VIRAMA + SSA")
        let cases: [(String, String, Int)] = [
            ("prebase-i", "कि", 2), ("conjunct", conjunct, 2), ("reph", "कर्म", 3),
            ("spacing-marks", "काँ", 2), ("mixed-emoji", "abc 123 कि 🙂", 12),
        ]
        for (label, source, knownCells) in cases {
            let (session, _, text, _) = try fixture(initialText: source)
            let rowIndex = session.screen.numberOfScrollbackLines()
            let row = try XCTUnwrap(session.screen.screenCharArray(forLine: rowIndex))
            let cells = hindiSourceCells(row)
            let bytesBefore = cells.map { Array($0.utf8) }
            XCTAssertEqual(cells.filter { !$0.isEmpty }.count, knownCells, label)
            XCTAssertEqual(Array(cells.joined().utf8), Array(source.utf8), label)
            let cursor = (session.screen.cursorX(), session.screen.cursorY())
            XCTAssertEqual(cursor.0, Int32(cells.count + 1), "cursor counts aliases too")

            let helper = try XCTUnwrap(text.drawingHelper)
            XCTAssertNil(helper.malayalamLayout(atLine: rowIndex), "Hindi admission stays disabled")
            XCTAssertNil(helper.malayalamDisplayMap)
            XCTAssertTrue(session.writes.isEmpty)
            XCTAssertEqual(hindiSourceCells(row).map { Array($0.utf8) }, bytesBefore, label)
            XCTAssertEqual(session.screen.cursorX(), cursor.0)
            XCTAssertEqual(session.screen.cursorY(), cursor.1)
        }
    }

    func testHindiLayoutRepresentsRealSourceCells() throws {
        let source = "abc 123 कि 🙂 कर्म"
        XCTAssertEqual(source.unicodeScalars.map { $0.value },
                       [0x61, 0x62, 0x63, 0x20, 0x31, 0x32, 0x33, 0x20, 0x0915, 0x093F, 0x20,
                        0x1F642, 0x20, 0x0915, 0x0930, 0x094D, 0x092E])
        let (layout, cells) = try hindiLayout(source)
        XCTAssertTrue(cells.contains(""), "emoji must exercise a wide-cell alias")
        // Expected spans come from parser strings, never from returned selection ranges.
        var boundaries = [0]
        for cell in cells { boundaries.append(boundaries.last! + cell.utf16.count) }
        XCTAssertEqual(boundaries.last, source.utf16.count)
        XCTAssertEqual(layout.cellUTF16Boundaries.map { $0.intValue }, boundaries)
        XCTAssertEqual(Array(layout.attributedString.string.utf8), Array(source.utf8))
        XCTAssertEqual(layout.naturalWidth, CTLineGetTypographicBounds(layout.line, nil, nil, nil), accuracy: 0.001)
        var kinds: [iTermMalayalamCaretKind: Int] = [:]
        for column in cells.indices {
            let projection = try XCTUnwrap(layout.projection(atColumn: column))
            XCTAssertEqual(projection.logicalColumn, column)
            XCTAssertEqual(projection.utf16Index, boundaries[column])
            kinds[projection.kind, default: 0] += 1
            let columns = NSRange(location: column, length: 1)
            let selection = try XCTUnwrap(layout.selection(forColumns: columns))
            XCTAssertEqual(selection.utf16Range, NSRange(location: boundaries[column], length: cells[column].utf16.count))
            XCTAssertEqual(Array(selection.sourceText.utf8), Array(cells[column].utf8))
            XCTAssertEqual(selection.logicalColumns, columns)
        }
        XCTAssertEqual(kinds.values.reduce(0, +), cells.count)
        let whole = try XCTUnwrap(layout.selection(forColumns: NSRange(location: 0, length: cells.count)))
        XCTAssertEqual(whole.sourceText, source)
        let edges = layout.nativeEdges.map { $0.utf16Index }
        XCTAssertEqual(edges, edges.sorted())
        XCTAssertFalse(edges.isEmpty)
    }

    // A native caret span can contain several Swift graphemes without merging terminal cells.
    func testHindiRephNativeSpanIsRedCase() throws {
        let source = "कर्म"
        XCTAssertEqual(source.unicodeScalars.map { $0.value }, [0x0915, 0x0930, 0x094D, 0x092E])
        let (layout, cells) = try hindiLayout(source)
        XCTAssertEqual(cells, ["क", "र्", "म"])
        let leading = layout.nativeEdges.filter { $0.leading && $0.utf16Index == 0 }
        let trailing = layout.nativeEdges.filter { !$0.leading && $0.utf16Index == 3 }
        XCTAssertEqual(leading.count, 1)
        XCTAssertEqual(trailing.count, 1)
        let anchor = try XCTUnwrap(leading.first)
        XCTAssertEqual(anchor.x, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(trailing.first).x, 26.806640625, accuracy: 0.001)
        XCTAssertFalse(layout.nativeEdges.contains { $0.leading && [1, 3].contains($0.utf16Index) })

        let start = try XCTUnwrap(layout.projection(atColumn: 0))
        XCTAssertEqual(start.kind, .nativeEdge)
        XCTAssertEqual(start.anchorUTF16Index, 0)
        for column in 1...2 {
            let projection = try XCTUnwrap(layout.projection(atColumn: column))
            XCTAssertEqual(projection.kind, .provisionalClusterStart)
            XCTAssertEqual(projection.anchorUTF16Index, 0)
            let edge = try XCTUnwrap(projection.nativeEdge)
            XCTAssertEqual(edge.x, anchor.x, accuracy: 0.001)
            XCTAssertEqual(edge.utf16Index, 0)
            XCTAssertEqual(edge.leading, anchor.leading)
            XCTAssertTrue(edge === anchor, "interiors share the real anchor, not an invented stop")
        }
        let end = try XCTUnwrap(layout.projection(atColumn: 3))
        XCTAssertEqual(end.kind, .nativeEdge)
        XCTAssertEqual(end.anchorUTF16Index, 4)
        XCTAssertEqual(end.utf16Index, 4, "row endpoint is past the last character")

        for first in cells.indices {
            for length in 1...(cells.count - first) {
                let columns = NSRange(location: first, length: length)
                let selection = try XCTUnwrap(layout.selection(forColumns: columns))
                let expected = cells[first..<(first + length)].joined()
                let offset = cells.prefix(first).joined().utf16.count
                XCTAssertEqual(selection.utf16Range, NSRange(location: offset, length: expected.utf16.count))
                XCTAssertEqual(Array(selection.sourceText.utf8), Array(expected.utf8))
                XCTAssertEqual(selection.logicalColumns, columns)
                XCTAssertEqual(selection.startsInsideCluster, first > 0)
                XCTAssertEqual(selection.endsInsideCluster, first + length < cells.count)
            }
        }
        let empty = try XCTUnwrap(layout.selection(forColumns: NSRange(location: 0, length: 0)))
        XCTAssertEqual(empty.sourceText, "")
        XCTAssertEqual(empty.logicalColumns, NSRange(location: 0, length: 0))
    }

    func testHindiRephFilledSelectionSpansNativeCluster() throws {
        let (layout, cells) = try hindiLayout("कर्म")
        XCTAssertEqual(cells, ["क", "र्", "म"])
        for columns in [IndexSet(integer: 0), IndexSet(integer: 1), IndexSet(integer: 2),
                        IndexSet(integersIn: 0..<2), IndexSet()] {
            XCTAssertEqual(layout.wholeSelectedColumns(columns), IndexSet(),
                           "partial native spans are outline-only, never expanded filled text")
        }
        let all = IndexSet(integersIn: 0..<3)
        XCTAssertEqual(layout.wholeSelectedColumns(all), all)
    }

    func testHindiRephDisplayEnclosureAndHitTest() throws {
        let (layout, cells) = try hindiLayout("कर्म")
        XCTAssertEqual(cells, ["क", "र्", "म"])
        let nativeSpan = NSRange(location: 0, length: 4)
        for first in cells.indices {
            for length in 1...(cells.count - first) {
                let columns = NSRange(location: first, length: length)
                let selection = try XCTUnwrap(layout.selection(forColumns: columns))
                let expected = cells[first..<(first + length)].joined()
                let sourceRange = NSRange(location: cells.prefix(first).joined().utf16.count,
                                          length: expected.utf16.count)
                XCTAssertEqual(selection.utf16Range, sourceRange)
                XCTAssertEqual(layout.displayEnclosure(forUTF16Range: sourceRange), nativeSpan)
                XCTAssertEqual(Array(selection.sourceText.utf8), Array(expected.utf8))
                XCTAssertEqual(selection.logicalColumns, columns)
            }
        }
        for index in [0, 4] {
            let empty = NSRange(location: index, length: 0)
            XCTAssertEqual(layout.displayEnclosure(forUTF16Range: empty), empty)
        }
        let hitXs: [CGFloat] = [-1, 0, 1, 5, 13, 26.806640625, 27]
        for x in hitXs {
            let hit = try XCTUnwrap(layout.hitTest(nativeX: x))
            XCTAssertTrue([0, 4].contains(hit.utf16Index), "only the outer source boundaries are native stops")
            XCTAssertTrue(layout.nativeEdges.contains { $0 === hit.nativeEdge })
            XCTAssertFalse([1, 2].contains(hit.nativeEdge.utf16Index))
        }
    }

    func testHindiRephGeometryEquivalence() throws {
        let (plain, cells) = try hindiLayout("कर्म x")
        XCTAssertEqual(cells, ["क", "र्", "म", " ", "x"])
        let text = NSMutableAttributedString(attributedString: plain.attributedString)
        let whole = NSRange(location: 0, length: text.length)
        // Recolor a whole native span, leaving adjacent text to exercise a real run split.
        text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 4))
        let colored = try XCTUnwrap(iTermMalayalamRowLayout(attributedString: text,
            cellUTF16Boundaries: plain.cellUTF16Boundaries))
        XCTAssertGreaterThan((CTLineGetGlyphRuns(colored.line) as NSArray).count,
                             (CTLineGetGlyphRuns(plain.line) as NSArray).count)
        XCTAssertTrue(plain.hasEquivalentGeometry(to: colored))
        XCTAssertTrue(colored.hasEquivalentGeometry(to: plain), "equivalence is symmetric")

        text.removeAttribute(.foregroundColor, range: whole)
        text.addAttribute(.font, value: try XCTUnwrap(NSFont(name: "DevanagariSangamMN", size: 32)), range: whole)
        let bigger = try XCTUnwrap(iTermMalayalamRowLayout(attributedString: text,
            cellUTF16Boundaries: plain.cellUTF16Boundaries))
        XCTAssertFalse(plain.hasEquivalentGeometry(to: bigger))
    }

    func testHindiRephSpanSurvivesNarrowWrap() throws {
        let (layout, cells) = try hindiLayout("कर्म कर्म")
        XCTAssertEqual(cells, ["क", "र्", "म", " ", "क", "र्", "म"])
        let map = try XCTUnwrap(iTermMalayalamDisplayMap(rows: [NSNumber(value: 0): layout],
            rowCount: 1, columns: cells.count, width: 10))
        XCTAssertGreaterThan(map.fragments.count, 1, "narrow viewport must fragment the row")
        for fragment in map.fragments {
            XCTAssertFalse([1, 2, 5, 6].contains(fragment.firstColumn), "do not split either native span")
            XCTAssertFalse([1, 2, 5, 6].contains(fragment.endColumn), "do not split either native span")
        }
    }

    func testHindiNaturalRowsDefaultsOffAndPreservesParserCells() async throws {
        var declaredDefault: NSNumber?
        iTermAdvancedSettingsModel.enumerateDictionaries { setting in
            if setting?[kAdvancedSettingIdentifier] as? String == "HindiNaturalRows" {
                declaredDefault = setting?[kAdvancedSettingDefaultValue] as? NSNumber
            }
        }
        XCTAssertFalse(try XCTUnwrap(declaredDefault, "Hindi needs its own registered setting").boolValue)
        let source = "कि क्ष कर्म काँ കേ"
        for malayalam in [false, true] {
            for hindi in [false, true] {
                let defaults = iTermUserDefaults.userDefaults()
                defaults.set(true, forKey: "MalayalamNaturalRows")
                iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
                let (session, _, text, _) = try fixture(initialText: "")
                session.screen.performBlock(joinedThreads: { _, state, _ in
                    state.terminalEnabled = true
                    state.terminal?.encoding = String.Encoding.utf8.rawValue
                })
                defaults.set(malayalam, forKey: "MalayalamNaturalRows")
                defaults.set(hindi, forKey: "HindiNaturalRows")
                iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
                let expected = (hindi ? ["कि", " ", "क्", "ष", " ", "क", "र्", "म", " ", "काँ"] :
                    ["क", "ि", " ", "क्", "ष", " ", "क", "र्", "म", " ", "क", "ाँ"]) +
                    [" "] + (malayalam ? ["കേ"] : ["ക", "േ"])
                // Each scalar boundary, including between a base and its spacing mark.
                for split in Array(source.unicodeScalars.indices) + [source.endIndex] {
                    for chunk in ["\u{1b}[H\u{1b}[2K" + String(source[..<split]), String(source[split...])] where !chunk.isEmpty {
                        let bytes = Array(chunk.utf8)
                        await feedBytes(bytes, to: session, expectingExecutedBytes: session.executedBytes + bytes.count)
                    }
                    let row = try XCTUnwrap(session.screen.screenCharArray(forLine: 0))
                    XCTAssertEqual(hindiSourceCells(row).map { Array($0.utf8) }, expected.map { Array($0.utf8) },
                                   "only enabled-script attached marks share the base cell")
                    XCTAssertEqual(session.screen.cursorX(), Int32(expected.count + 1))
                    XCTAssertEqual(session.screen.cursorY(), 1)
                    XCTAssertEqual(text.drawingHelper.malayalamLayout(atLine: 0) != nil, hindi && malayalam,
                                   "the mixed row needs both script switches")
                }
                let standalone = Array("\u{1b}[H\u{1b}[2Kि".utf8)
                await feedBytes(standalone, to: session, expectingExecutedBytes: session.executedBytes + standalone.count)
                XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: 0)), hindi ? [" ि"] : ["ि"],
                               "a standalone mark owns one cell; enabled marks use the existing synthetic base")
                XCTAssertEqual(session.screen.cursorX(), 2)
                let otherScript = Array("\u{1b}[H\u{1b}[2Kকা".utf8)
                await feedBytes(otherScript, to: session, expectingExecutedBytes: session.executedBytes + otherScript.count)
                XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: 0)), ["ক", "া"],
                               "other scripts retain their existing cell policy")
                XCTAssertTrue(session.writes.isEmpty)
            }
        }
    }

    func testHindiNaturalRowsModeTransitionsInvalidateAdmission() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["MalayalamVisualWrap", "MalayalamParagraphFlow"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        defaults.set(true, forKey: keys[0])
        defaults.set(true, forKey: keys[1])
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let (session, _, text, _) = try fixture(initialText: "")
        feed("\u{1b}[?1049hകേ\r\nकि क्ष कर्म काँ\r\nകേ कि", to: session)
        let originals = (0..<3).map { session.screen.screenCharArray(forLine: Int32($0)).data }
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let requiredModes = [1, 2, 3] // Malayalam, Hindi, both.
        let helper = try XCTUnwrap(text.drawingHelper)

        // Every pair of setting events, including repeat, disable and re-enable, with unchanged rows.
        for first in 0..<4 {
            for second in 0..<4 {
                for mode in [0, first, second] {
                    defaults.set(mode & 1 != 0, forKey: "MalayalamNaturalRows")
                    defaults.set(mode & 2 != 0, forKey: "HindiNaturalRows")
                    iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
                    // Hit the warmed row entry before setup/refresh can hide stale admission.
                    for (row, required) in requiredModes.enumerated() {
                        XCTAssertEqual(helper.malayalamLayout(atLine: Int32(row)) != nil, mode & required == required,
                                       "direct cached entry, mode \(mode), row \(row)")
                    }
                    _ = text.refresh()
                    XCTAssertEqual(helper.malayalamDisplayMap != nil, mode != 0)
                    for (row, required) in requiredModes.enumerated() {
                        let expected = mode & required == required
                        XCTAssertEqual(helper.malayalamLayout(atLine: Int32(row)) != nil, expected,
                                       "mode \(mode), row \(row), events \([first, second])")
                        if let map = helper.malayalamDisplayMap {
                            XCTAssertEqual(map.sourceLayout(forRow: row) != nil, expected)
                        }
                        XCTAssertEqual(session.screen.screenCharArray(forLine: Int32(row)).data, originals[row])
                    }
                    let prepared = helper.malayalamRowLayoutPreparationCount
                    _ = text.refresh()
                    XCTAssertEqual(helper.malayalamRowLayoutPreparationCount, prepared,
                                   "unchanged mode and rows retain the unselected cache fast path")
                    XCTAssertEqual(session.screen.cursorX(), cursor.0)
                    XCTAssertEqual(session.screen.cursorY(), cursor.1)
                    XCTAssertTrue(session.writes.isEmpty)
                }
            }
        }
    }

    func testHindiNaturalRowsOptInUsesIntegratedWrapAndCopy() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": false,
            "CopySelection": false, "CopyLastNewline": false, "TrimWhitespaceOnCopy": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        let (session, view, text, _) = try fixture(initialText: "")
        for (key, value) in settings { defaults.set(value, forKey: key) }
        defaults.set(false, forKey: "MalayalamNaturalRows")
        defaults.set(true, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        session.setSize(VT100GridSizeMake(110, 6))
        let source = "कि क्ष कर्म काँ 🙂 " + String(repeating: "कर्म ", count: 12)
        feed("\u{1b}[?1049h" + source, to: session)
        let original = try XCTUnwrap(session.screen.screenCharArray(forLine: 0))
        let cells = original.data
        let endColumn = session.screen.cursorX() - 1
        XCTAssertEqual(session.screen.cursorY(), 1, "fixture must fit one logical source row")
        XCTAssertEqual(Array(hindiSourceCells(original).joined().utf8), Array(source.utf8))
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        view.setFrameSize(NSSize(width: 260, height: view.compactFrame().height))
        _ = text.refresh()

        // This must come through real admission and map construction, not the direct-layout lab helper.
        let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap, "Hindi-only mode must build the map")
        let layout = try XCTUnwrap(map.sourceLayout(forRow: 0), "Hindi-only mode must admit the real row")
        XCTAssertEqual(Array(layout.attributedString.string.utf8), Array(source.utf8))
        XCTAssertGreaterThan(map.fragments(forSourceRow: 0).count, 1, "natural text must really wrap")
        let utf16 = source as NSString
        for token in ["कि", "क्ष", "कर्म", "काँ", "🙂"] {
            let tokenRange = utf16.range(of: token)
            for piece in map.fragments(forSourceRow: 0) {
                let overlap = NSIntersectionRange(tokenRange, piece.sourceRange)
                XCTAssertTrue(overlap.length == 0 || overlap == tokenRange, "wrap must not split \(token)")
            }
        }
        let absolute = session.screen.totalScrollbackOverflow()
        text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
            VT100GridAbsCoordRangeMake(0, absolute, endColumn, absolute), 0, 0), mode: .kiTermSelectionModeCharacter)
        XCTAssertEqual(Array(try XCTUnwrap(text.selectedText).utf8), Array(source.utf8))
        text.selection.clear()
        XCTAssertEqual(session.screen.screenCharArray(forLine: 0).data, cells)
        XCTAssertEqual(session.screen.cursorX(), cursor.0)
        XCTAssertEqual(session.screen.cursorY(), cursor.1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testHindiOffscreenMapTransferAndGetterModeFence() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["MalayalamVisualWrap", "MalayalamParagraphFlow"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        let (session, view, text, _) = try fixture(initialText: "")
        defaults.set(true, forKey: keys[0]); defaults.set(false, forKey: keys[1])
        defaults.set(false, forKey: "MalayalamNaturalRows")
        defaults.set(true, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        feed("\u{1b}[?1049h" + String(repeating: "कर्म ", count: 8), to: session)
        view.setFrameSize(NSSize(width: 260, height: view.compactFrame().height))
        _ = text.refresh()
        let helper = try XCTUnwrap(text.drawingHelper)
        let map = try XCTUnwrap(helper.malayalamDisplayMap)
        XCTAssertGreaterThan(map.fragments(forSourceRow: 0).count, 1)
        let prepared = helper.malayalamRowLayoutPreparationCount
        let built = helper.malayalamRowLayoutBuildCount
        let cold = try XCTUnwrap(text.perform(NSSelectorFromString("newDrawingHelperForOffscreenRendering"))?
            .takeRetainedValue() as? iTermTextDrawingHelper)
        XCTAssertTrue(cold.malayalamDisplayMap === map, "fresh helper inherits current geometry")
        let frame = NSRect(x: 0, y: 0, width: text.frame.width,
                           height: CGFloat(map.firstDisplayRow(forSourceRow: 1)) * text.lineHeight)
        cold.configureForOffscreenRendering(withFrame: frame, visibleRect: frame,
                                           renderedRows: NSRange(location: 0, length: 1))
        XCTAssertTrue(cold.malayalamDisplayMap === map, "setup must not erase a valid transferred map")
        let image = try XCTUnwrap(text.renderLines(toImage: NSRange(location: 0, length: 1)))
        XCTAssertEqual(image.size.height, frame.height)
        _ = text.refresh()
        XCTAssertTrue(helper.malayalamDisplayMap === map)
        XCTAssertEqual(helper.malayalamRowLayoutPreparationCount, prepared)
        XCTAssertEqual(helper.malayalamRowLayoutBuildCount, built)

        defaults.set(false, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        // These getters are the first cache access after the mode change, before row lookup or setup.
        XCTAssertNil(helper.malayalamDisplayMap)
        XCTAssertNil(cold.malayalamDisplayMap)
        _ = text.refresh()
        XCTAssertNil(helper.malayalamLayout(atLine: 0))
        defaults.set(true, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        XCTAssertNil(helper.malayalamDisplayMap)
        _ = text.refresh()
        XCTAssertNotNil(try XCTUnwrap(helper.malayalamDisplayMap).sourceLayout(forRow: 0))
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testHindiProseTableSelectionPaintAndFallbackFonts() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings = ["MalayalamVisualWrap": true, "MalayalamParagraphFlow": true,
                        "CopySelection": false, "CopyLastNewline": false, "TrimWhitespaceOnCopy": false]
        let saved = Dictionary(uniqueKeysWithValues: settings.keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in settings.keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        let suppliedOutput = ProcessInfo.processInfo.environment["ITERM2_HINDI_REPLAY_OUT"]
        let output = suppliedOutput.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("iterm2-hindi-replay-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer {
            if suppliedOutput == nil { try? FileManager.default.removeItem(at: output) }
        }
        let (session, view, text, _) = try fixture(initialText: "")
        for (key, value) in settings { defaults.set(value, forKey: key) }
        defaults.set(false, forKey: "MalayalamNaturalRows"); defaults.set(true, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_USE_SELECTED_TEXT_COLOR] = true
        profile[KEY_USE_SEPARATE_COLORS_FOR_LIGHT_AND_DARK_MODE] = false
        session.profile = profile
        session.setPreferencesFromAddressBookEntry(profile)
        session.screen.performBlock(joinedThreads: { _, state, _ in
            state.mutateColorMap { colors in
                colors.setColor(.white, forKey: Int32(kColorMapForeground))
                colors.setColor(.black, forKey: Int32(kColorMapBackground))
                colors.setColor(.blue, forKey: Int32(kColorMapSelection))
                colors.setColor(.red, forKey: Int32(kColorMapSelectedText))
                colors.minimumContrast = 0
            }
        })
        session.sync()
        session.setSize(VT100GridSizeMake(40, 8))
        let rows = ["  कर्म करते रहना ही जीवन की सही दिशा है। यह सच है", "  कर्म से सीखो और आगे बढ़ो।", "",
                    "  ┌" + String(repeating: "─", count: 18) + "┬──────┐",
                    "  │ कर्म" + String(repeating: " ", count: 14) + "│ 42   │",
                    "  └" + String(repeating: "─", count: 18) + "┴──────┘"]
        feed("\u{1b}[?1049h" + rows.joined(separator: "\r\n"), to: session)
        XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: 0)).count, 38,
                       "next three-cell word cannot fit in the remaining two columns")
        let original = rows.indices.map { session.screen.screenCharArray(forLine: Int32($0)).data }
        let cursor = (session.screen.cursorX(), session.screen.cursorY())
        let helper = try XCTUnwrap(text.drawingHelper)
        var fonts = Set<String>()
        func paint(_ row: Int32, _ name: String) throws -> Data {
            let bitmap = try renderedBitmap(text, row: row, includeSelection: true, name: name)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name + ".png"))
            return png
        }
        for width: CGFloat in [260, 800] {
            view.setFrameSize(NSSize(width: width, height: view.compactFrame().height))
            _ = text.refresh()
            let image = try XCTUnwrap(text.renderImage(withLines: NSRange(location: 0, length: rows.count),
                includeMargins: false, backgroundColor: .black, showCursor: false, includeSelection: true))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("hindi-\(Int(width))-overview.png"))
            let map = try XCTUnwrap(helper.malayalamDisplayMap)
            let paragraph = try XCTUnwrap(map.fragments(forSourceRow: 0).first?.paragraph)
            XCTAssertEqual(paragraph.rows.first?.usedColumns, 38)
            XCTAssertEqual(paragraph.rows.count, 2, "the hard-ended Hindi continuation must really join")
            XCTAssertTrue(map.fragments(forSourceRow: 1).first?.paragraph === paragraph)
            XCTAssertNotNil(map.tableRow(forSourceRow: 4), "boxed Hindi must use responsive table geometry")
            for (row, column) in [(0, 2), (4, 4)] {
                let before = try XCTUnwrap(helper.malayalamLayout(atLine: Int32(row)))
                for run in CTLineGetGlyphRuns(before.line) as! [CTRun] {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    let font = try XCTUnwrap(attributes[kCTFontAttributeName]) as! CTFont
                    fonts.insert(CTFontCopyPostScriptName(font) as String)
                    var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    XCTAssertFalse(glyphs.contains(0), "actual fallback run must not contain missing glyphs")
                }
                let prefix = "hindi-\(Int(width))-row\(row)"
                let clean = try paint(Int32(row), prefix + "-clean")
                for partial in [true, false] {
                    let columns = NSRange(location: column + (partial ? 1 : 0), length: partial ? 1 : 3)
                    let absolute = session.screen.totalScrollbackOverflow() + Int64(row)
                    text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                        VT100GridAbsCoordRangeMake(Int32(columns.location), absolute, Int32(NSMaxRange(columns)), absolute),
                        0, 0), mode: .kiTermSelectionModeCharacter)
                    _ = text.refresh()
                    XCTAssertEqual(text.selectedText, partial ? "र्" : "कर्म", "copy keeps exact parser cells")
                    let selected = try XCTUnwrap(helper.malayalamLayout(atLine: Int32(row)))
                    XCTAssertTrue(selected.hasEquivalentGeometry(to: before))
                    XCTAssertEqual(selected.wholeSelectedColumns(IndexSet(integersIn: columns.location..<NSMaxRange(columns))),
                                   partial ? IndexSet() : IndexSet(integersIn: columns.location..<NSMaxRange(columns)))
                    var outline: ObjCBool = false
                    let rects = try XCTUnwrap(helper.malayalamSelectionRects(columns, layout: selected,
                        line: Int32(row), partial: &outline))
                    XCTAssertEqual(outline.boolValue, partial)
                    XCTAssertFalse(rects.isEmpty)
                    XCTAssertTrue(rects.allSatisfy { $0.rectValue.width > 0 })
                    let start = selected.cellUTF16Boundaries[column].intValue
                    let color = try foregroundColor(selected, at: start)
                    XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
                    XCTAssertEqual(color.greenComponent, partial ? 1 : 0, accuracy: 0.001)
                    XCTAssertEqual(color.blueComponent, partial ? 1 : 0, accuracy: 0.001)
                    XCTAssertNotEqual(try paint(Int32(row), prefix + (partial ? "-partial" : "-whole")), clean)
                    text.selection.clear()
                    _ = text.refresh()
                    XCTAssertEqual(try paint(Int32(row), prefix + "-cleared"), clean)
                }
            }
            for row in rows.indices {
                XCTAssertEqual(session.screen.screenCharArray(forLine: Int32(row)).data, original[row])
                XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: Int32(row))).joined(), rows[row])
            }
            XCTAssertEqual(session.screen.cursorX(), cursor.0); XCTAssertEqual(session.screen.cursorY(), cursor.1)
        }
        XCTAssertFalse(fonts.isEmpty)
        try (fonts.sorted().joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("actual-run-fonts.txt"),
                                                               atomically: true, encoding: .utf8)
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testHindiPositionedClientWritesPreserveSourceAndCopy() async throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["HindiNaturalRows": true, "MalayalamNaturalRows": false,
            "MalayalamVisualWrap": true, "MalayalamParagraphFlow": false,
            "CopySelection": false, "CopyLastNewline": false, "TrimWhitespaceOnCopy": false]
        let saved = settings.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        let (session, view, text, _) = try fixture(initialText: "")
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_NORMAL_FONT] = "Monaco 18"
        profile[KEY_NON_ASCII_FONT] = "NotoSansMalayalam-Regular 18"
        profile["ASCII Anti Aliased"] = false
        profile["Non-ASCII Anti Aliased"] = false
        session.profile = profile
        session.setPreferencesFromAddressBookEntry(profile)
        session.setSize(VT100GridSizeMake(173, 43))
        // Exact row payload captured from a real Claude reply; CSI G addresses logical columns.
        let payload = "हमारा\u{1b}[7Gभारत\u{1b}[11Gमहान\u{1b}[15Gहै।\u{1b}[18Gबारिश\u{1b}[22Gके\u{1b}[24Gबाद\u{1b}[27Gआशीर्वाद\u{1b}[33Gमिला,\u{1b}[38G  \u{1b}[37Gस्त्री\u{1b}[41Gऔर\u{1b}[44Gक्षत्रिय\u{1b}[50Gदोनों\u{1b}[53Gआए।"
        let expected = "  हमारा भारत महान है। बारिश के बाद आशीर्वाद मिला, स्त्री और क्षत्रिय दोनों आए।"
        feed("\u{1b}[?1049h\u{1b}[1;3H" + payload, to: session)
        let row = try XCTUnwrap(session.screen.screenCharArray(forLine: 0))
        XCTAssertEqual(Array(hindiSourceCells(row).joined().utf8), Array(expected.utf8))
        XCTAssertEqual(session.screen.cursorX(), 56)
        XCTAssertEqual(session.screen.cursorY(), 1)
        for width: CGFloat in [1600, 260] {
            view.setFrameSize(NSSize(width: width, height: 560))
            _ = text.refresh()
            let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
            let layout = try XCTUnwrap(map.sourceLayout(forRow: 0))
            XCTAssertEqual(Array(layout.attributedString.string.utf8), Array(expected.utf8))
            if width == 260 { XCTAssertGreaterThan(map.fragments(forSourceRow: 0).count, 1) }
            for (first, end, copied) in [(3, 4, "मा"), (0, 55, expected)] {
                let absolute = session.screen.totalScrollbackOverflow()
                text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                    VT100GridAbsCoordRangeMake(Int32(first), absolute, Int32(end), absolute), 0, 0),
                    mode: .kiTermSelectionModeCharacter)
                _ = text.refresh()
                XCTAssertEqual(Array(try XCTUnwrap(text.selectedText).utf8), Array(copied.utf8))
                let selected = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0))
                XCTAssertTrue(selected.hasEquivalentGeometry(to: layout))
                XCTAssertNotNil(text.renderImage(withLines: NSRange(location: 0, length: 1),
                    includeMargins: false, backgroundColor: .black, showCursor: false, includeSelection: true))
                text.selection.clear()
                _ = text.refresh()
            }
            XCTAssertEqual(session.screen.screenCharArray(forLine: 0).data, row.data)
            XCTAssertEqual(session.screen.cursorX(), 56)
            XCTAssertEqual(session.screen.cursorY(), 1)
        }
        // Literal rows cover every reported anthem/mixed line; the CSI-G row above exercises client positioning.
        defaults.set(true, forKey: "MalayalamNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let anthem = ["जन-गण-मन अधिनायक जय हे", "भारत-भाग्य-विधाता।", "पंजाब-सिंधु-गुजरात-मराठा",
            "द्राविड़-उत्कल-बंग", "विंध्य-हिमाचल-यमुना-गंगा", "उच्छल-जलधि-तरंग", "तव शुभ नामे जागे,",
            "तव शुभ आशिष मांगे,", "गाहे तव जय-गाथा।", "जन-गण-मंगलदायक जय हे",
            "हमारा भारत महान है। बारिश के बाद आशीर्वाद मिला, स्त्री और क्षत्रिय दोनों आए।",
            "ഇമ്മടെ കേരളം, हमारा भारत: രണ്ടും ഒരേ വരീല്.", "ഇനിമ്മള് പൊളിക്കും ട്ടാ, अब हम धमाल करेंगे।"]
        for line in anthem {
            let bytes = Array(("\u{1b}[H\u{1b}[2K" + line).utf8)
            await feedBytes(bytes, to: session, expectingExecutedBytes: session.executedBytes + bytes.count)
            _ = text.refresh()
            XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: 0)).joined(), line)
            let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap)
            XCTAssertEqual(try XCTUnwrap(map.sourceLayout(forRow: 0)).attributedString.string, line)
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testHindiFontDefaultUsesNativeTraitsAndPreservesOtherScripts() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let key = "HindiNaturalRowsFont"
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        defaults.removeObject(forKey: key)
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        var declared: String?
        iTermAdvancedSettingsModel.enumerateDictionaries { setting in
            if setting?[kAdvancedSettingIdentifier] as? String == key {
                declared = setting?[kAdvancedSettingDefaultValue] as? String
            }
        }
        XCTAssertEqual(declared, "DevanagariSangamMN")
        let (session, _, text, _) = try fixture(initialText: "")
        defaults.set(true, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let source = "कि कर्म काँ A കേ"
        feed("\u{1b}[?1049h" + ["0", "1", "3", "1;3"].map {
            "\u{1b}[\($0)m" + source + "\u{1b}[0m"
        }.joined(separator: "\r\n"), to: session)
        _ = text.refresh()
        for row in 0..<4 {
            let layout = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: Int32(row)))
            XCTAssertEqual(layout.attributedString.string, source)
            XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: Int32(row))).joined(), source)
            for run in CTLineGetGlyphRuns(layout.line) as! [CTRun] {
                let range = CTRunGetStringRange(run)
                let font = try XCTUnwrap((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName]) as! CTFont
                let name = CTFontCopyPostScriptName(font) as String
                let runText = (source as NSString).substring(with: NSRange(location: range.location, length: range.length))
                if runText.unicodeScalars.contains(where: { (0x0900...0x097f).contains($0.value) }) {
                    XCTAssertTrue(name.hasPrefix("DevanagariSangamMN"), name)
                    XCTAssertEqual(CTFontGetSymbolicTraits(font).contains(.traitBold), row == 1 || row == 3)
                    XCTAssertEqual(layout.attributedString.attribute(NSAttributedString.Key("iTermFakeBoldAttribute"),
                        at: range.location, effectiveRange: nil) as? Bool, false, "native bold must not be struck twice")
                    if row >= 2 {
                        XCTAssertTrue(CTFontGetSymbolicTraits(font).contains(.traitItalic) ||
                                      abs(CTFontGetMatrix(font).c - 0.2) < 0.001)
                    }
                    var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    XCTAssertFalse(glyphs.contains(0), "Hindi must not lose glyphs")
                } else {
                    XCTAssertFalse(name.hasPrefix("DevanagariSangamMN"), "ASCII and Malayalam keep their provider")
                }
            }
        }
        // An explicitly italic face must not receive the synthetic shear a second time.
        let italic = try XCTUnwrap(NSFont(name: "Helvetica-Oblique", size: 20))
        defaults.set(italic.fontName, forKey: key)
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        for row in [2, 3] {
            let layout = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: Int32(row)))
            let font = try XCTUnwrap(layout.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(CTFontGetSymbolicTraits(font).contains(.traitItalic))
            XCTAssertEqual(CTFontGetMatrix(font).c, CTFontGetMatrix(italic).c, accuracy: 0.001)
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testHindiFontChangesInvalidateWarmRowsAndMap() throws {
        let defaults = iTermUserDefaults.userDefaults()
        let keys = ["HindiNaturalRowsFont", "MalayalamVisualWrap", "MalayalamParagraphFlow"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        let (session, _, text, _) = try fixture(initialText: "")
        defaults.set(true, forKey: "HindiNaturalRows")
        defaults.set(true, forKey: "MalayalamVisualWrap")
        defaults.set(false, forKey: "MalayalamParagraphFlow")
        defaults.set("", forKey: keys[0])
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        feed("\u{1b}[?1049hकि कर्म काँ", to: session)
        _ = text.refresh()
        let helper = try XCTUnwrap(text.drawingHelper)
        let original = session.screen.screenCharArray(forLine: 0).data
        let cursor = session.screen.cursorX()
        let automatic = try XCTUnwrap(helper.malayalamLayout(atLine: 0)).attributedString
        let names = ["", "DevanagariSangamMN", "NoSuchHindiFont-Regression"]
        var previous = ""
        for first in names {
            for second in names {
                for name in [first, second] {
                    defaults.set(name, forKey: keys[0])
                    iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
                    if name != previous {
                        XCTAssertNil(helper.malayalamDisplayMap, "getter must fence stale font geometry before setup")
                    }
                    // Direct warm-row lookup must also observe the setting before refresh/setup.
                    let layout = try XCTUnwrap(helper.malayalamLayout(atLine: 0))
                    let font = try XCTUnwrap(layout.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                    if name == "DevanagariSangamMN" {
                        XCTAssertEqual(font.fontName, name)
                    } else {
                        XCTAssertEqual(layout.attributedString, automatic, "empty or missing font uses the original provider")
                    }
                    _ = text.refresh()
                    XCTAssertNotNil(helper.malayalamDisplayMap)
                    let count = helper.malayalamRowLayoutPreparationCount
                    _ = text.refresh()
                    XCTAssertEqual(helper.malayalamRowLayoutPreparationCount, count)
                    XCTAssertEqual(session.screen.screenCharArray(forLine: 0).data, original)
                    XCTAssertEqual(session.screen.cursorX(), cursor)
                    previous = name
                }
            }
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testAccentedLatinKeepsReportedIndicRowsNatural() async throws {
        let defaults = iTermUserDefaults.userDefaults()
        let settings: [String: Any] = ["HindiNaturalRows": true, "MalayalamNaturalRows": true,
            "MalayalamVisualWrap": true, "MalayalamParagraphFlow": false,
            "CopySelection": false, "CopyLastNewline": false, "TrimWhitespaceOnCopy": false]
        let saved = settings.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        }
        let (session, view, text, _) = try fixture(initialText: "")
        for (key, value) in settings { defaults.set(value, forKey: key) }
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        var profile = try XCTUnwrap(session.profile)
        profile[KEY_NORMAL_FONT] = "Monaco 18"
        profile[KEY_NON_ASCII_FONT] = "NotoSansMalayalam-Regular 18"
        session.profile = profile
        session.setPreferencesFromAddressBookEntry(profile)
        session.setSize(VT100GridSizeMake(300, 43))
        let rows = [
            "മലയാളം (nāma), labels ṅ and ḥ on the library shelf.",
            "- The shelf label: the red card shows a sample title, and the green card lists its code: उत्पादः (nāma ḥ).",
            "- The display: beside the label कर्म, a red ः marks the sample card, and उत्पादः names another card. The final अः is printed on a separate red label.",
            "- The catalogue: each small card has a number and a colour. The printed title is कर्म, the next card reads उत्पादः, and the last one shows nāma with ṅ and ḥ beside a library shelf.",
            "- Green label: कर्म (nāma ṅa ḥ), three samples.",
            "कर्म (a\u{0304}\u{0301}), stacked Latin accents."
        ]
        feed("\u{1b}[?1049h", to: session)
        for (index, row) in rows.enumerated() {
            for source in [row, row.decomposedStringWithCanonicalMapping] {
                let bytes = Array(("\u{1b}[H\u{1b}[2K" + source).utf8)
                await feedBytes(bytes, to: session, expectingExecutedBytes: session.executedBytes + bytes.count)
                let original = try XCTUnwrap(session.screen.screenCharArray(forLine: 0))
                XCTAssertEqual(Array(hindiSourceCells(original).joined().utf8), Array(source.utf8))
                let end = session.screen.cursorX() - 1
                XCTAssertEqual(session.screen.cursorY(), 1)
                for width: CGFloat in [1800, 300] {
                    view.setFrameSize(NSSize(width: width, height: 700))
                    _ = text.refresh()
                    let map = try XCTUnwrap(text.drawingHelper.malayalamDisplayMap, "reported row \(index) needs natural admission")
                    let layout = try XCTUnwrap(map.sourceLayout(forRow: 0))
                    XCTAssertEqual(Array(layout.attributedString.string.utf8), Array(source.utf8))
                    if width == 300 { XCTAssertGreaterThan(map.fragments(forSourceRow: 0).count, 1) }
                    let absolute = session.screen.totalScrollbackOverflow()
                    text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
                        VT100GridAbsCoordRangeMake(0, absolute, end, absolute), 0, 0), mode: .kiTermSelectionModeCharacter)
                    _ = text.refresh()
                    XCTAssertEqual(Array(try XCTUnwrap(text.selectedText).utf8), Array(source.utf8))
                    XCTAssertTrue(try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0)).hasEquivalentGeometry(to: layout))
                    _ = try renderedBitmap(text, row: 0, includeSelection: true, name: "latin-row\(index)-\(Int(width))")
                    text.selection.clear()
                    XCTAssertEqual(session.screen.screenCharArray(forLine: 0).data, original.data)
                    XCTAssertEqual(session.screen.cursorX(), end + 1)
                }
            }
        }
        for source in ["कर्म ά", "കേ а", "कर्म \u{0301}", "कर्म a\u{fe0f}", "कर्म a\u{034f}", "nāmaḥ"] {
            let bytes = Array(("\u{1b}[H\u{1b}[2K" + source).utf8)
            await feedBytes(bytes, to: session, expectingExecutedBytes: session.executedBytes + bytes.count)
            XCTAssertNil(text.drawingHelper.malayalamLayout(atLine: 0), "do not admit unrelated scripts, lone marks, invalid selectors or Latin-only rows")
        }
        defaults.set(false, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        let disabled = Array("\u{1b}[H\u{1b}[2Kकर्म ā".utf8)
        await feedBytes(disabled, to: session, expectingExecutedBytes: session.executedBytes + disabled.count)
        XCTAssertNil(text.drawingHelper.malayalamLayout(atLine: 0), "Latin does not enable a disabled Indic script")
        XCTAssertTrue(session.writes.isEmpty)
    }

    func testHindiAndMalayalamVisargaSourceAndNaturalLayout() async throws {
        let defaults = iTermUserDefaults.userDefaults()
        let (session, _, text, _) = try fixture(initialText: "")
        defaults.set(true, forKey: "HindiNaturalRows")
        iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
        session.setSize(VT100GridSizeMake(300, 43))
        feed("\u{1b}[?1049h", to: session)
        let cases: [(String, [String])] = [
            ("ः", ["ः"]), ("अः", ["अ", "ः"]), ("उत्पादः", ["उ", "त्", "पा", "द", "ः"]),
            ("ഃ", [" ഃ"]), ("അഃ", ["അഃ"]), ("ഉത്പാദഃ", ["ഉ", "ത്", "പാ", "ദഃ"]),
            ("x \u{1b}[31mः\u{1b}[0m y \u{1b}[34mअः\u{1b}[0m.", ["x", " ", "ः", " ", "y", " ", "अ", "ः", "."])
        ]
        for (wire, expectedCells) in cases {
            let bytes = Array(("\u{1b}[H\u{1b}[2K" + wire).utf8)
            await feedBytes(bytes, to: session, expectingExecutedBytes: session.executedBytes + bytes.count)
            let row = try XCTUnwrap(session.screen.screenCharArray(forLine: 0))
            XCTAssertEqual(hindiSourceCells(row), expectedCells)
            XCTAssertEqual(session.screen.cursorX(), Int32(expectedCells.count + 1))
            let layout = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0))
            XCTAssertEqual(Array(layout.attributedString.string.utf8), Array(expectedCells.joined().utf8))
            _ = try renderedBitmap(text, row: 0, name: "visarga-\(expectedCells.joined())")
        }
        let source = "- The display: beside the label कर्म, a red ः marks the sample card, and उत्पादः names another card. The final अः is printed on a separate red label."
        let bytes = Array(("\u{1b}[H\u{1b}[2K" + source).utf8)
        await feedBytes(bytes, to: session, expectingExecutedBytes: session.executedBytes + bytes.count)
        XCTAssertEqual(Array(hindiSourceCells(session.screen.screenCharArray(forLine: 0)).joined().utf8), Array(source.utf8))
        let layout = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0))
        XCTAssertEqual(Array(layout.attributedString.string.utf8), Array(source.utf8))
        _ = try renderedBitmap(text, row: 0, name: "reported-visarga-row3")
        // A shorter client repaint must erase the previous ASCII tail, not retain a cached row.
        let shorter = "ഉത്പാദഃ അക്ഷരം മാറും ഇനി."
        for (wire, expected) in [("\u{1b}[H\u{1b}[2K" + shorter + "s", shorter + "s"),
                                 ("\r" + shorter + "\u{1b}[K", shorter)] {
            let bytes = Array(wire.utf8)
            await feedBytes(bytes, to: session, expectingExecutedBytes: session.executedBytes + bytes.count)
            _ = text.refresh()
            XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: 0)).joined(), expected)
            XCTAssertEqual(try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0)).attributedString.string, expected)
        }
        let repainted = try renderedBitmap(text, row: 0, name: "visarga-shorter-repaint").representation(using: .png, properties: [:])
        let clean = Array(("\u{1b}[H\u{1b}[2K" + shorter).utf8)
        await feedBytes(clean, to: session, expectingExecutedBytes: session.executedBytes + clean.count)
        _ = text.refresh()
        XCTAssertEqual(try renderedBitmap(text, row: 0, name: "visarga-shorter-cold").representation(using: .png, properties: [:]), repainted)
        // Actual client CSI-G positions: final visarga must replace the old cell, not leave its glyph.
        let positioned = "\u{1b}[H\u{1b}[2K\u{1b}[47Gg\u{1b}[41Gfinal ः\u{1b}[49Gfalls\u{1b}[55Gaway,"
        feed(positioned, to: session)
        let expected = String(repeating: " ", count: 40) + "final ः falls away,"
        XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: 0)).joined(), expected)
        XCTAssertEqual(session.screen.cursorX(), 60)
        XCTAssertEqual(try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0)).attributedString.string, expected)
        let beforeSelection = try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0))
        let absolute = session.screen.totalScrollbackOverflow()
        text.selection.setSelectedLogicalRange(VT100GridAbsWindowedRangeMake(
            VT100GridAbsCoordRangeMake(46, absolute, 47, absolute), 0, 0), mode: .kiTermSelectionModeCharacter)
        _ = text.refresh()
        XCTAssertEqual(text.selectedText, "ः", "the independent visarga cell is copied without its preceding space")
        XCTAssertTrue(try XCTUnwrap(text.drawingHelper.malayalamLayout(atLine: 0)).hasEquivalentGeometry(to: beforeSelection))
        _ = try renderedBitmap(text, row: 0, includeSelection: true, name: "visarga-cell-selection")
        text.selection.clear()
        let mixed = "अः कि അഃ"
        for malayalam in [false, true] {
            for hindi in [false, true] {
                defaults.set(malayalam, forKey: "MalayalamNaturalRows")
                defaults.set(hindi, forKey: "HindiNaturalRows")
                iTermAdvancedSettingsModel.loadAdvancedSettingsFromUserDefaults()
                let cells = ["अ", "ः", " "] + (hindi ? ["कि"] : ["क", "ि"]) +
                    [" "] + (malayalam ? ["അഃ"] : ["അ", "ഃ"])
                for split in Array(mixed.unicodeScalars.indices) + [mixed.endIndex] {
                    for chunk in ["\u{1b}[H\u{1b}[2K" + String(mixed[..<split]), String(mixed[split...])] where !chunk.isEmpty {
                        let bytes = Array(chunk.utf8)
                        await feedBytes(bytes, to: session, expectingExecutedBytes: session.executedBytes + bytes.count)
                    }
                    XCTAssertEqual(hindiSourceCells(session.screen.screenCharArray(forLine: 0)), cells)
                    XCTAssertEqual(session.screen.cursorX(), Int32(cells.count + 1))
                }
            }
        }
        XCTAssertTrue(session.writes.isEmpty)
    }

}
