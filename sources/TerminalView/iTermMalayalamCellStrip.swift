import AppKit

/// Separate logical-cell selection control. It never moves the terminal client's cursor.
@objc(iTermMalayalamCellStrip)
final class iTermMalayalamCellStrip: NSView {
    @objc var columnCount = 0 { didSet { needsDisplay = true } }
    @objc var cursorColumn = 0 { didSet { needsDisplay = true } }
    @objc var focusColumn = 0 {
        didSet {
            if focusColumn != oldValue { scrollOffset = nil }
            needsDisplay = true
        }
    }
    @objc var selectedColumns = IndexSet() { didSet { needsDisplay = true } }
    @objc var statusText = "" {
        didSet {
            toolTip = String(localized: "MalayalamCellStrip.ScrollHint",
                defaultValue: "Scroll horizontally or use the mouse wheel to reveal source columns.",
                comment: "Tooltip explaining how to navigate the exact source-column strip below the terminal")
            needsDisplay = true
        }
    }
    @objc var didSelectColumn: ((Int) -> Void)?
    @objc private(set) var drawCount = 0
    private let slotWidth: CGFloat = 24
    private var scrollOffset: CGFloat?
    private var captionWidth: CGFloat { min(160, bounds.width) }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc var visibleColumns: NSRange {
        guard columnCount > 0 else { return NSRange(location: 0, length: 0) }
        let slots = min(columnCount, max(0, Int((bounds.width - captionWidth) / slotWidth)))
        guard slots > 0 else { return NSRange(location: 0, length: 0) }
        let focus = min(columnCount - 1, max(0, focusColumn))
        let first = scrollOffset.map { Int($0 / slotWidth) } ?? max(0, focus + 1 - slots)
        return NSRange(location: min(columnCount - slots, max(0, first)), length: slots)
    }

    @objc func rect(forColumn column: Int) -> NSRect {
        let visible = visibleColumns
        guard column >= visible.location && column < NSMaxRange(visible) else { return .zero }
        return NSRect(x: captionWidth + CGFloat(column - visible.location) * slotWidth,
                      y: 0, width: slotWidth, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let caption = NSRect(x: 4, y: 4, width: max(0, captionWidth - 8), height: bounds.height - 4)
        (statusText as NSString).draw(in: caption, withAttributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
        let visible = visibleColumns
        for column in visible.location..<NSMaxRange(visible) {
            let rect = rect(forColumn: column).insetBy(dx: 1, dy: 2)
            if selectedColumns.contains(column) {
                NSColor.selectedContentBackgroundColor.setFill()
                rect.fill()
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: rect).stroke()
            // Localization unneeded: exact zero-based terminal-column identifiers.
            (String(column) as NSString).draw(at: NSPoint(x: rect.minX + 3, y: 6), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.labelColor])
            if column == cursorColumn {
                NSColor.systemOrange.setStroke()
                let marker = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                marker.lineWidth = 2
                marker.stroke()
            }
        }
        if cursorColumn == columnCount && NSMaxRange(visible) == columnCount && visible.length > 0 {
            // A pending-wrap cursor is at the row endpoint, not inside the final source cell.
            let end = rect(forColumn: columnCount - 1).maxX - 2
            NSColor.systemOrange.setStroke()
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: end, y: 2))
            marker.line(to: NSPoint(x: end, y: bounds.height - 2))
            marker.lineWidth = 2
            marker.stroke()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let visible = visibleColumns
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        guard visible.length > 0, delta.isFinite else { return }
        // Trackpads supply points; ordinary wheel ticks navigate whole source columns.
        let movement = delta * (event.hasPreciseScrollingDeltas ? 1 : slotWidth)
        let current = scrollOffset ?? CGFloat(visible.location) * slotWidth
        let maximum = CGFloat(columnCount - visible.length) * slotWidth
        scrollOffset = min(maximum, max(0, current - movement))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x - captionWidth
        let visible = visibleColumns
        guard x.isFinite, x >= 0, x < CGFloat(visible.length) * slotWidth else { return }
        didSelectColumn?(visible.location + Int(x / slotWidth))
    }
}
