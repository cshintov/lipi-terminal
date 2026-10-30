import AppKit
import CoreText

final class LayoutLabView: NSView {
    private(set) var buffer = CellBuffer(cells: CellFixture.examples[0].cells, cursor: 0)
    private(set) var fixtureIndex = 0
    private(set) var drawCount = 0
    private(set) var mouseEventCount = 0
    private(set) var drawnDisplayPosition: CellDisplayPosition?
    private(set) var drawnMarkerBounds: NSRect?
    private var selectionAnchor: Int?
    private var note = "Experiment: native cluster-edge caret plus exact-column marker; not a final terminal policy."
    private(set) var actionButtons: [NSButton] = []

    var cursor: Int { buffer.cursor }
    var visibleColumns: Range<Int> {
        let count = max(1, Int((bounds.width - 32) / 126))
        let start = max(0, cursor - count + 1)
        return start..<min(buffer.cells.count + 1, start + count)
    }
    var selectedText: String {
        guard let anchor = selectionAnchor else { return "" }
        return buffer.cells[min(anchor, cursor)..<max(anchor, cursor)].joined()
    }
    var layout: CellLayout? { try? CellLayout(cells: buffer.cells, fontSize: 36) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let actions: [(String, Selector)] = [
            ("Next example", #selector(nextFixture)), ("Previous cell", #selector(previousCell)),
            ("Next cell", #selector(nextCell)), ("Overwrite with A", #selector(writeA)),
            ("Erase to end", #selector(eraseToEnd)), ("Delete cell", #selector(deleteCell))
        ]
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.0, target: self, action: action.1)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 28 + index * 166, y: 510, width: 158, height: 32)
            addSubview(button)
            actionButtons.append(button)
        }
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        drawnDisplayPosition = nil
        drawnMarkerBounds = nil
        NSColor.white.setFill()
        bounds.fill()
        label("Malayalam layout laboratory", x: 32, y: 20, size: 24)
        label("First-party diagnostic, not iTerm2. Cell partitions are source-derived fixtures, not captured client traces.", x: 32, y: 54)
        let samples = ["Garden-2 പൂക്കൾ വിരിയുന്നു, River-യിലേക്ക് ചെറിയ sample പാത നീളുന്നു.",
                       "കൊണ്ടുപോകും ഒരു ആഴ്ച ക്ഷമ സ്ത്രീ"]
        for (index, sample) in samples.enumerated() {
            if let reference = try? LineGeometry(text: sample) { drawLine(reference.line, x: 32, baseline: CGFloat(94 + index * 24)) }
        }
        guard let layout = layout else {
            label("Cannot resolve the required fonts. This is not a successful rendering.", x: 32, y: 160, color: .red)
            return
        }
        label("\(CellFixture.examples[fixtureIndex].title): natural 36-point shaping, no stretch or fitting", x: 32, y: 146)
        drawLine(layout.geometry.line, x: 40, baseline: 212)
        let position = layout.positions[cursor]
        let display = layout.displayPosition(at: cursor)
        drawnDisplayPosition = display
        if let x = display.nativeCaretX {
            NSColor.systemBlue.setStroke()
            let caret = NSBezierPath()
            caret.lineWidth = 2
            caret.move(to: NSPoint(x: 40 + x, y: 166))
            caret.line(to: NSPoint(x: 40 + x, y: 220))
            caret.stroke()
        }
        let mapping = "Exact column \(display.exactColumn), source UTF-16 \(position.utf16Index): \(position.kind.rawValue). Raw probes only: \(String(format: "%.3f / %.3f", position.rawPrimaryX, position.rawSecondaryX))."
        label(mapping, x: 32, y: 236)
        let anchorNote = display.isProvisionalAnchor
            ? "Provisional cluster-start display anchor UTF-16 \(display.anchorUTF16Index), NOT exact insertion position or final snapping policy."
            : "Native edge at source boundary \(display.anchorUTF16Index); orange marker identifies the exact logical column."
        let unresolvedNote = "Native anchor unresolved at UTF-16 \(display.anchorUTF16Index): no blue caret; exact column stays \(display.exactColumn)."
        label(display.nativeCaretX == nil ? unresolvedNote : anchorNote,
              x: 32, y: 260, color: display.nativeCaretX == nil ? .systemRed : .systemBlue)
        let marker = NSBezierPath()
        let stripColumns = visibleColumns
        let markerX = CGFloat(32 + (display.exactColumn - stripColumns.lowerBound) * 126 + 58)
        marker.move(to: NSPoint(x: markerX - 8, y: 286))
        marker.line(to: NSPoint(x: markerX + 8, y: 286))
        marker.line(to: NSPoint(x: markerX, y: 300))
        marker.close()
        NSColor.systemOrange.setFill()
        marker.fill()
        drawnMarkerBounds = marker.bounds
        let font = NSFont(name: "NotoSansMalayalam-Regular", size: 20) ?? NSFont.systemFont(ofSize: 20)
        for column in stripColumns {
            let rect = NSRect(x: 32 + (column - stripColumns.lowerBound) * 126, y: 302, width: 116, height: 72)
            (column == display.exactColumn ? NSColor.systemOrange.withAlphaComponent(0.18) : NSColor(white: 0.96, alpha: 1)).setFill()
            rect.fill()
            NSColor.lightGray.setStroke()
            NSBezierPath(rect: rect).stroke()
            label("column \(column)", x: rect.minX + 8, y: rect.minY + 8)
            let content = column < buffer.cells.count ? buffer.cells[column] : "end"
            (content as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 34),
                                      withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
        label("Orange triangle = exact logical column in the cell strip, NOT shaped-text geometry. Left/Right moves cells; Shift selects.", x: 32, y: 390)
        if selectionAnchor != nil {
            label("Exact selected cell text: \(selectedText.debugDescription). Not widened to a whole glyph or grapheme.", x: 32, y: 418)
        }
        label(note, x: 32, y: 452, color: .darkGray)
        label("Interior logical positions share a provisional native cluster-start anchor; logical cursor and selected bytes do not snap.", x: 32, y: 568, color: .darkGray)
        label("No terminal protocol, IME, wrapping, real client editing or stale-pixel compatibility is claimed by this window.", x: 32, y: 594, color: .darkGray)
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 13, color: NSColor = .black) {
        (text as NSString).draw(at: NSPoint(x: x, y: y),
                               withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }

    private func drawLine(_ line: CTLine, x: CGFloat, baseline: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        context.setFillColor(NSColor.black.cgColor)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 123 || event.keyCode == 124 else { return }
        if event.modifierFlags.contains(.shift) {
            if selectionAnchor == nil { selectionAnchor = cursor }
        } else { selectionAnchor = nil }
        buffer.apply(event.keyCode == 123 ? .left : .right)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseEventCount += 1
        let point = convert(event.locationInWindow, from: nil)
        if point.y >= 302 && point.y <= 374 && point.x >= 32 {
            let stripColumns = visibleColumns
            let column = stripColumns.lowerBound + Int((point.x - 32) / 126)
            guard stripColumns.contains(column) else { return }
            selectionAnchor = event.modifierFlags.contains(.shift) ? (selectionAnchor ?? cursor) : nil
            while cursor > column { buffer.apply(.left) }
            while cursor < column { buffer.apply(.right) }
        } else if point.y >= 160 && point.y <= 220, let layout = layout {
            let candidates = layout.geometry.nearestStops(to: point.x - 40)
            if candidates.count == 1,
               let column = layout.positions.first(where: { $0.utf16Index == candidates[0].utf16Index })?.column {
                selectionAnchor = nil
                while cursor > column { buffer.apply(.left) }
                while cursor < column { buffer.apply(.right) }
            } else { note = "Ambiguous hit: \(candidates.map(\.utf16Index)). No column was selected automatically." }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    @objc private func nextFixture() {
        fixtureIndex = (fixtureIndex + 1) % CellFixture.examples.count
        buffer = CellBuffer(cells: CellFixture.examples[fixtureIndex].cells, cursor: 0)
        selectionAnchor = nil
        note = "Source-derived fixture; actual iTerm2/client traces remain to be measured."
        finishAction()
    }
    @objc private func previousCell() { selectionAnchor = nil; buffer.apply(.left); finishAction() }
    @objc private func nextCell() { selectionAnchor = nil; buffer.apply(.right); finishAction() }
    @objc private func writeA() { selectionAnchor = nil; buffer.apply(.write("A")); finishAction() }
    @objc private func eraseToEnd() { selectionAnchor = nil; buffer.apply(.eraseToEnd); finishAction() }
    @objc private func deleteCell() { selectionAnchor = nil; buffer.apply(.deleteCell); finishAction() }
    private func finishAction() { needsDisplay = true; window?.makeFirstResponder(self) }
}

final class LayoutLabDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = LayoutLabView(frame: NSRect(x: 0, y: 0, width: 1100, height: 650))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Malayalam Layout Laboratory"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        if CommandLine.arguments.contains("--self-check") {
            // Let AppKit finish launch before checking an actual backing-store draw.
            DispatchQueue.main.async {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                                                   isARepeat: false, keyCode: 124) else {
                    print("FAIL: could not construct owned-window key event")
                    exit(1)
                }
                window.sendEvent(event)
                guard view.cursor == 1 else {
                    print("FAIL: owned-window Right event must move the logical cell cursor")
                    exit(1)
                }
                print("PASS: owned-window Right event moved the logical cell cursor")
                guard view.layout?.positions[1].kind == .insideGrapheme else {
                    print("FAIL: interior logical cursor must remain classified")
                    exit(1)
                }
                view.displayIfNeeded()
                guard let display = view.drawnDisplayPosition,
                      display.exactColumn == 1 && display.anchorUTF16Index == 0 && display.isProvisionalAnchor &&
                      display.nativeCaretX.map({ abs($0) < 0.000001 }) == true else {
                    print("FAIL: drawn native cluster-start anchor must remain separate from exact column one; draws=\(view.drawCount), drawn=\(String(describing: view.drawnDisplayPosition)), measured=\(String(describing: view.layout?.displayPosition(at: view.cursor)))")
                    exit(1)
                }
                print("PASS: draw dispatch retained column one with a provisional native cluster-start anchor")
                let point = view.convert(NSPoint(x: 80, y: 334), to: nil)
                guard let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                      let shiftRight = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                                                       isARepeat: false, keyCode: 124) else {
                    print("FAIL: could not construct owned-window selection events")
                    exit(1)
                }
                window.sendEvent(mouse)
                guard view.cursor == 0 else {
                    print("FAIL: mouse must select source column zero; received=\(view.mouseEventCount), windowKey=\(window.isKeyWindow), appActive=\(NSApp.isActive), point=\(point)")
                    exit(1)
                }
                window.sendEvent(shiftRight)
                guard view.selectedText.utf8.elementsEqual("ക്".utf8) else {
                    print("FAIL: partial-cell selection must retain exact source text"); exit(1)
                }
                view.actionButtons[3].performClick(nil)
                guard view.buffer.cells.joined() == "ക്A" else {
                    print("FAIL: real button dispatch must overwrite the cursor cell"); exit(1)
                }
                view.needsDisplay = true
                view.displayIfNeeded()
                guard view.drawCount > 0 else { print("FAIL: actual view drawing was not dispatched"); exit(1) }
                print("PASS: owned-window mouse, Shift+Right selection, button overwrite and draw dispatch")
                for _ in 0..<9 { view.actionButtons[3].performClick(nil) }
                view.displayIfNeeded()
                guard let markerBounds = view.drawnMarkerBounds,
                      view.bounds.contains(markerBounds), view.visibleColumns.contains(view.cursor),
                      view.drawnDisplayPosition?.exactColumn == view.cursor else {
                    print("FAIL: repeated editing must keep the exact-column marker inside the window"); exit(1)
                }
                let expectedColumn = view.visibleColumns.lowerBound
                window.sendEvent(mouse)
                guard view.cursor == expectedColumn else {
                    print("FAIL: scrolled cell-strip mouse hit must retain its logical column"); exit(1)
                }
                print("PASS: repeated editing retained visible exact-column marker and translated mouse hit")
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--demo-interior") { view.actionButtons[2].performClick(nil) }
        print("READY: window=\(window.windowNumber) pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LayoutLabMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = LayoutLabDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
