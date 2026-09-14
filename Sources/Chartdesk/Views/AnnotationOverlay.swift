import AppKit

/// Sits on top of the chart image, inside the same scroll view, so marks magnify and pan with
/// the plate for free.
///
/// The view is transparent to the mouse unless annotate mode is on — `hitTest` returns nil —
/// which is what keeps panning, pinch-zoom and double-click-to-fit behaving exactly as they
/// did before there was an overlay at all.
final class AnnotationOverlayView: NSView, NSTextFieldDelegate {

    override var isFlipped: Bool { true }

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

    /// A route being assembled: drawn live so each button press extends the line on the
    /// plate, rather than only appearing once it is committed.
    var preview: [[CGPoint]] = [] {
        didSet { if preview != oldValue { needsDisplay = true } }
    }

    /// The whole imported taxi network, faintly. The only honest way to check a calibration
    /// is to see whether the data lands on the pavement printed underneath it.
    var reference: [[CGPoint]] = [] {
        didSet { if reference != oldValue { needsDisplay = true } }
    }

    /// While calibrating, a click reports where it landed instead of drawing anything.
    var isCalibrating = false {
        didSet {
            guard isCalibrating != oldValue else { return }
            if isCalibrating { cancelTextEditor() }
            refreshCursor()
        }
    }

    var onCalibrationClick: ((CGPoint) -> Void)?

    /// Dragging the whole overlay into place, rather than clicking points for it to fit.
    var isAligning = false {
        didSet {
            guard isAligning != oldValue else { return }
            if isAligning { cancelTextEditor() }
            refreshCursor()
        }
    }

    var onAlignDrag: ((CGPoint) -> Void)?
    var onAlignTurn: ((Double, CGPoint) -> Void)?
    var onAlignZoom: ((Double, CGPoint) -> Void)?

    private var alignAnchor: NSPoint?

    /// The stroke under the pointer right now. Held here rather than in the store so a drag
    /// in progress costs no SwiftUI updates and no disk writes.
    private var live: Annotation?
    private var editor: NSTextField?
    private var editorOrigin: CGPoint = .zero

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        (isActive || isCalibrating || isAligning) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        if isAligning {
            alignAnchor = convert(event.locationInWindow, from: nil)
            return
        }
        if isCalibrating {
            onCalibrationClick?(stored(convert(event.locationInWindow, from: nil)))
            return
        }
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
        if isAligning {
            guard let previous = alignAnchor else { return }
            let current = convert(event.locationInWindow, from: nil)
            alignAnchor = current
            align(from: previous, to: current, modifiers: event.modifierFlags)
            return
        }
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
        if isAligning { alignAnchor = nil; return }
        guard isActive else { return super.mouseUp(with: event) }
        guard let current = live else { return }
        live = nil
        needsDisplay = true
        guard !current.isEmpty else { return }
        onDraw?(current)
    }

    /// Grab-and-turn rather than a slider: the point under the pointer follows it round the
    /// middle of what you are looking at, which is the same gesture as rotating a paper chart.
    private func align(from previous: NSPoint, to current: NSPoint, modifiers: NSEvent.ModifierFlags) {
        let pivot = visibleCentre()

        if modifiers.contains(.option) {
            let was = atan2(previous.y - pivot.y, previous.x - pivot.x)
            let now = atan2(current.y - pivot.y, current.x - pivot.x)
            // The view is flipped, so a growing angle here is clockwise on screen.
            onAlignTurn?(Double(now - was), unclamped(pivot))
            return
        }

        if modifiers.contains(.shift) {
            let was = hypot(previous.x - pivot.x, previous.y - pivot.y)
            let now = hypot(current.x - pivot.x, current.y - pivot.y)
            guard was > max(bounds.width * 0.002, 1) else { return }
            onAlignZoom?(Double(now / was), unclamped(pivot))
            return
        }

        let from = unclamped(previous), to = unclamped(current)
        onAlignDrag?(CGPoint(x: to.x - from.x, y: to.y - from.y))
    }

    override func magnify(with event: NSEvent) {
        guard isAligning else { return super.magnify(with: event) }
        onAlignZoom?(1 + Double(event.magnification), unclamped(visibleCentre()))
    }

    override func rotate(with event: NSEvent) {
        guard isAligning else { return super.rotate(with: event) }
        // AppKit reports anticlockwise degrees.
        onAlignTurn?(Double(-event.rotation) * .pi / 180, unclamped(visibleCentre()))
    }

    private func visibleCentre() -> NSPoint {
        guard let visible = enclosingScrollView?.documentVisibleRect, !visible.isEmpty else {
            return NSPoint(x: bounds.midX, y: bounds.midY)
        }
        return NSPoint(x: visible.midX, y: visible.midY)
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
        drawReference()
        AnnotationRenderer.draw(annotations, size: bounds.size, rotation: rotation)
        if let live = live, !live.isEmpty {
            AnnotationRenderer.draw(live, size: bounds.size, rotation: rotation)
        }
        drawPreview()
    }

    /// Normalised, unrotated points — the same convention marks use — turned into view
    /// coordinates for the plate as it is currently shown.
    private func viewPath(_ line: [CGPoint]) -> NSBezierPath? {
        guard line.count > 1 else { return nil }
        let path = NSBezierPath()
        for (index, point) in line.enumerated() {
            let shown = AnnotationGeometry.display(point, rotation: rotation)
            let where_ = NSPoint(x: shown.x * bounds.width, y: shown.y * bounds.height)
            index == 0 ? path.move(to: where_) : path.line(to: where_)
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private func drawReference() {
        guard !reference.isEmpty else { return }
        let width = max(bounds.width * 0.0012, 0.6)
        NSColor(srgbRed: 0.19, green: 0.72, blue: 0.94, alpha: 0.30).setStroke()
        for line in reference {
            guard let path = viewPath(line) else { continue }
            path.lineWidth = width
            path.stroke()
        }
    }

    private func drawPreview() {
        guard !preview.isEmpty else { return }
        let width = max(bounds.width * 0.0045, 1.5)
        for line in preview {
            guard let path = viewPath(line) else { continue }
            path.lineWidth = width * 5
            NSColor(srgbRed: 1.0, green: 0.82, blue: 0.12, alpha: 0.34).setStroke()
            path.stroke()
            path.lineWidth = width
            NSColor(srgbRed: 1.0, green: 0.72, blue: 0.05, alpha: 0.95).setStroke()
            path.stroke()
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
        if isAligning { return addCursorRect(bounds, cursor: .openHand) }
        if isCalibrating { return addCursorRect(bounds, cursor: .crosshair) }
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
