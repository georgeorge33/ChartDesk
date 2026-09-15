import AppKit

/// Sits on top of the chart image, inside the same scroll view, so marks magnify and pan with
/// the plate for free.
///
/// The view is transparent to the mouse unless annotate mode is on — `hitTest` returns nil —
/// which is what keeps panning, pinch-zoom and double-click-to-fit behaving exactly as they
/// did before there was an overlay at all.
final class AnnotationOverlayView: NSView, NSTextFieldDelegate {

    override var isFlipped: Bool { true }

    /// A drag here draws, erases or aligns; it must never move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    var annotations: [Annotation] = [] {
        didSet { if annotations != oldValue { needsDisplay = true } }
    }

    var rotation: Int = 0 {
        didSet { if rotation != oldValue { needsDisplay = true } }
    }

    /// Which chart is underneath. A half-typed label belongs to the plate it was started on,
    /// so switching charts throws it away rather than moving it.
    var chartKey: String = "" {
        didSet { if chartKey != oldValue { cancelTextEditor() } }
    }

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive { cancelTextEditor() }
            refreshCursor()
        }
    }

    var tool: AnnotationTool = .pen {
        didSet { if tool != oldValue { refreshCursor() } }
    }

    var color: AnnotationColor = .red
    var width: AnnotationWidth = .medium

    var onDraw: ((Annotation) -> Void)?
    var onErase: ((UUID) -> Void)?

    /// The stroke under the pointer right now. Held here rather than in the store so a drag
    /// in progress costs no SwiftUI updates and no disk writes.
    private var live: Annotation?
    private var editor: NSTextField?
    private var editorOrigin: CGPoint = .zero

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return super.mouseDown(with: event) }

        // Clicking away from a label being typed keeps it, the way a text box usually behaves.
        commitTextEditor()

        let point = convert(event.locationInWindow, from: nil)

        switch tool {
        case .eraser:
            erase(at: point)

        case .text:
            beginTextEditor(at: point)

        default:
            live = Annotation(tool: tool,
                              color: color,
                              width: width,
                              points: [stored(point)],
                              text: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isActive else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)

        if tool == .eraser {
            erase(at: point)
            return
        }

        guard var current = live else { return }

        if current.tool.isDragged {
            // Arrows and boxes are always exactly two points: where the drag began and where
            // it is now.
            if current.points.count < 2 {
                current.points.append(stored(point))
            } else {
                current.points[1] = stored(point)
            }
        } else {
            // Freehand at high magnification produces far more samples than the line needs.
            if let last = current.points.last {
                let previous = pixel(last)
                if hypot(previous.x - point.x, previous.y - point.y) < minimumSampleGap { return }
            }
            current.points.append(stored(point))
        }

        live = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isActive else { return super.mouseUp(with: event) }
        guard let current = live else { return }
        live = nil
        needsDisplay = true
        guard !current.isEmpty else { return }
        onDraw?(current)
    }

    private func erase(at point: NSPoint) {
        guard let id = AnnotationRenderer.hit(annotations,
                                              at: point,
                                              size: bounds.size,
                                              rotation: rotation,
                                              slack: eraserReach) else { return }
        onErase?(id)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        AnnotationRenderer.draw(annotations, size: bounds.size, rotation: rotation)
        if let live = live, !live.isEmpty {
            AnnotationRenderer.draw(live, size: bounds.size, rotation: rotation)
        }
    }

    // MARK: - Text

    private func beginTextEditor(at point: NSPoint) {
        cancelTextEditor()

        let fontSize = max(width.textFraction * bounds.width, 8)
        let field = NSTextField(frame: NSRect(x: point.x - fontSize * 0.25,
                                              y: point.y - fontSize * 0.25,
                                              width: max(fontSize * 12, 120),
                                              height: fontSize * 1.9))
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = color.nsColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Note"
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        addSubview(field)
        editor = field
        editorOrigin = point
        window?.makeFirstResponder(field)
    }

    /// Keeps whatever has been typed, if anything.
    func commitTextEditor() {
        guard let field = editor else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editor = nil
        field.removeFromSuperview()

        guard !text.isEmpty else { return }
        onDraw?(Annotation(tool: .text,
                           color: color,
                           width: width,
                           points: [stored(editorOrigin)],
                           text: text))
    }

    func cancelTextEditor() {
        editor?.removeFromSuperview()
        editor = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitTextEditor()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelTextEditor()
            return true
        default:
            return false
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        guard isActive else { return super.resetCursorRects() }
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    private func refreshCursor() {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Coordinates

    /// Screen magnification, so hit slop and sampling gaps stay constant to the eye rather
    /// than growing as the plate is zoomed in.
    private var magnification: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.01)
    }

    private var eraserReach: CGFloat { 9 / magnification }

    private var minimumSampleGap: CGFloat { 1.2 / magnification }

    /// Like `stored`, without the clamp. A drag near the edge of the plate must still report
    /// its true delta, and a clamped one would quietly shrink it.
    private func unclamped(_ point: NSPoint) -> CGPoint {
        AnnotationGeometry.source(CGPoint(x: point.x / max(bounds.width, 1),
                                          y: point.y / max(bounds.height, 1)),
                                  rotation: rotation)
    }

    private func stored(_ point: NSPoint) -> CGPoint {
        let shown = CGPoint(x: clamp(point.x / max(bounds.width, 1)),
                            y: clamp(point.y / max(bounds.height, 1)))
        return AnnotationGeometry.source(shown, rotation: rotation)
    }

    private func pixel(_ point: CGPoint) -> CGPoint {
        let shown = AnnotationGeometry.display(point, rotation: rotation)
        return CGPoint(x: shown.x * bounds.width, y: shown.y * bounds.height)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
