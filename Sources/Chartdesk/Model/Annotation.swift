import AppKit
import Foundation

// MARK: - Tools

/// What a mark is made with. `eraser` removes marks rather than making one, so it is the one
/// case that never appears on a stored `Annotation`.
enum AnnotationTool: String, Codable, CaseIterable, Identifiable {
    case pen
    case highlighter
    case arrow
    case box
    case text
    case eraser

    var id: String { rawValue }

    /// Tools that produce a mark, in palette order.
    static let drawing: [AnnotationTool] = [.pen, .highlighter, .arrow, .box, .text]

    var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .arrow: return "Arrow"
        case .box: return "Box"
        case .text: return "Text"
        case .eraser: return "Eraser"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        case .text: return "character.textbox"
        case .eraser: return "eraser"
        }
    }

    /// Drawn with one drag between two corners rather than following the pointer.
    var isDragged: Bool {
        self == .arrow || self == .box
    }
}

// MARK: - Colours

/// A small fixed palette. These are picked to stay legible on a white plate and to survive
/// night mode, which inverts the chart underneath but not the marks drawn on top of it.
enum AnnotationColor: String, Codable, CaseIterable, Identifiable {
    case red
    case orange
    case yellow
    case green
    case blue
    case magenta
    case black
    case white

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .red:     return NSColor(srgbRed: 0.92, green: 0.20, blue: 0.20, alpha: 1)
        case .orange:  return NSColor(srgbRed: 0.98, green: 0.58, blue: 0.10, alpha: 1)
        case .yellow:  return NSColor(srgbRed: 0.99, green: 0.85, blue: 0.15, alpha: 1)
        case .green:   return NSColor(srgbRed: 0.16, green: 0.76, blue: 0.36, alpha: 1)
        case .blue:    return NSColor(srgbRed: 0.18, green: 0.55, blue: 0.95, alpha: 1)
        case .magenta: return NSColor(srgbRed: 0.85, green: 0.24, blue: 0.75, alpha: 1)
        case .black:   return NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        case .white:   return NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
        }
    }
}

// MARK: - Weights

enum AnnotationWidth: String, Codable, CaseIterable, Identifiable {
    case fine
    case medium
    case bold

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    /// Stroke width as a fraction of the chart's width rather than a pixel count, so the same
    /// setting looks equally thick on a 900-pixel plate and a 4000-pixel one.
    var strokeFraction: CGFloat {
        switch self {
        case .fine:   return 0.0022
        case .medium: return 0.0042
        case .bold:   return 0.0078
        }
    }

    /// Text is sized from the same setting so the palette stays a single choice.
    var textFraction: CGFloat {
        switch self {
        case .fine:   return 0.018
        case .medium: return 0.028
        case .bold:   return 0.042
        }
    }
}

// MARK: - A mark

struct Annotation: Identifiable, Codable, Equatable {

    var id: UUID = UUID()
    var tool: AnnotationTool
    var color: AnnotationColor
    var width: AnnotationWidth
    /// Normalised 0…1 against the *unrotated* chart, so marks stay where they were put when
    /// the plate is rotated, and keep working if the same file is re-scanned.
    var points: [CGPoint]
    var text: String?

    var isEmpty: Bool {
        switch tool {
        case .text: return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return points.count < 2
        }
    }
}

// MARK: - Rotation

/// Marks are stored against the unrotated plate; the viewer shows a rotated one. These two
/// functions are the only place that difference is resolved.
enum AnnotationGeometry {

    /// Stored point → where it belongs on the chart as currently displayed.
    static func display(_ point: CGPoint, rotation: Int) -> CGPoint {
        switch ((rotation % 360) + 360) % 360 {
        case 90:  return CGPoint(x: 1 - point.y, y: point.x)
        case 180: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: return CGPoint(x: point.y, y: 1 - point.x)
        default:  return point
        }
    }

    /// Point on the displayed chart → the value to store.
    static func source(_ point: CGPoint, rotation: Int) -> CGPoint {
        switch ((rotation % 360) + 360) % 360 {
        case 90:  return CGPoint(x: point.y, y: 1 - point.x)
        case 180: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: return CGPoint(x: 1 - point.y, y: point.x)
        default:  return point
        }
    }
}

// MARK: - Drawing

/// Draws marks into whatever context is current, in a *top-left origin* space of `size`.
///
/// Both callers already work that way: the overlay view is flipped, and the export path draws
/// into `NSImage(size:flipped:)`. Keeping one coordinate convention means text comes out the
/// right way up in both without a special case.
enum AnnotationRenderer {

    static func draw(_ annotations: [Annotation], size: CGSize, rotation: Int) {
        guard size.width > 1, size.height > 1 else { return }
        for annotation in annotations {
            draw(annotation, size: size, rotation: rotation)
        }
    }

    static func draw(_ annotation: Annotation, size: CGSize, rotation: Int) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }

        let points = pixelPoints(annotation, size: size, rotation: rotation)
        let stroke = max(annotation.width.strokeFraction * size.width, 1)

        switch annotation.tool {
        case .text:
            drawText(annotation, at: points.first, size: size)

        case .highlighter:
            guard let path = strokePath(annotation, points: points) else { return }
            path.lineWidth = stroke * 5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            annotation.color.nsColor.withAlphaComponent(0.32).setStroke()
            path.stroke()

        case .pen, .arrow, .box, .eraser:
            guard let path = strokePath(annotation, points: points) else { return }
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            annotation.color.nsColor.setStroke()
            path.stroke()

            if annotation.tool == .arrow, points.count >= 2 {
                let head = arrowHead(from: points[0], to: points[points.count - 1], stroke: stroke)
                head.lineWidth = stroke
                head.lineCapStyle = .round
                head.lineJoinStyle = .round
                annotation.color.nsColor.setStroke()
                head.stroke()
            }
        }
    }

    // MARK: Geometry

    static func pixelPoints(_ annotation: Annotation, size: CGSize, rotation: Int) -> [CGPoint] {
        annotation.points.map { point in
            let shown = AnnotationGeometry.display(point, rotation: rotation)
            return CGPoint(x: shown.x * size.width, y: shown.y * size.height)
        }
    }

    private static func strokePath(_ annotation: Annotation, points: [CGPoint]) -> NSBezierPath? {
        guard points.count >= 2 else { return nil }

        switch annotation.tool {
        case .box:
            let rect = NSRect(x: min(points[0].x, points[1].x),
                              y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x),
                              height: abs(points[1].y - points[0].y))
            return NSBezierPath(rect: rect)

        case .arrow:
            let path = NSBezierPath()
            path.move(to: points[0])
            path.line(to: points[points.count - 1])
            return path

        default:
            return smoothed(points)
        }
    }

    /// Freehand points arrive as a dense polyline. Rounding the corners through the midpoints
    /// costs nothing and stops a slow, careful pen stroke looking like a staircase.
    private static func smoothed(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0])

        guard points.count > 2 else {
            path.line(to: points[1])
            return path
        }

        for index in 1..<(points.count - 1) {
            let control = points[index]
            let end = CGPoint(x: (control.x + points[index + 1].x) / 2,
                              y: (control.y + points[index + 1].y) / 2)
            let start = path.currentPoint
            // NSBezierPath has no quadratic segment on macOS 13, so raise it to a cubic.
            let first = CGPoint(x: start.x + 2.0 / 3.0 * (control.x - start.x),
                                y: start.y + 2.0 / 3.0 * (control.y - start.y))
            let second = CGPoint(x: end.x + 2.0 / 3.0 * (control.x - end.x),
                                 y: end.y + 2.0 / 3.0 * (control.y - end.y))
            path.curve(to: end, controlPoint1: first, controlPoint2: second)
        }

        path.line(to: points[points.count - 1])
        return path
    }

    private static func arrowHead(from start: CGPoint, to end: CGPoint, stroke: CGFloat) -> NSBezierPath {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(stroke * 5.5, 6)
        let spread = CGFloat.pi / 7

        let path = NSBezierPath()
        for direction in [angle + .pi - spread, angle + .pi + spread] {
            path.move(to: end)
            path.line(to: CGPoint(x: end.x + cos(direction) * length,
                                  y: end.y + sin(direction) * length))
        }
        return path
    }

    // MARK: Text

    private static func drawText(_ annotation: Annotation, at point: CGPoint?, size: CGSize) {
        guard let point = point,
              let text = annotation.text,
              !text.isEmpty else { return }

        (text as NSString).draw(at: point, withAttributes: textAttributes(annotation, size: size))
    }

    static func textAttributes(_ annotation: Annotation, size: CGSize) -> [NSAttributedString.Key: Any] {
        let fontSize = max(annotation.width.textFraction * size.width, 8)
        let shadow = NSShadow()
        // Chart backgrounds vary from white paper to a dark inverted plate, so every label
        // carries its own halo rather than relying on contrast with what is underneath.
        shadow.shadowColor = (annotation.color == .white || annotation.color == .yellow
                              ? NSColor.black : NSColor.white).withAlphaComponent(0.85)
        shadow.shadowBlurRadius = fontSize * 0.28
        shadow.shadowOffset = .zero

        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: annotation.color.nsColor,
            .shadow: shadow
        ]
    }

    static func textSize(_ annotation: Annotation, size: CGSize) -> CGSize {
        guard let text = annotation.text, !text.isEmpty else { return .zero }
        return (text as NSString).size(withAttributes: textAttributes(annotation, size: size))
    }

    // MARK: Burning in

    /// Returns a copy of the plate with the marks painted into it, at its full pixel size.
    ///
    /// The bitmap is built by hand rather than left to `tiffRepresentation` so the output is
    /// always one bitmap pixel per chart pixel, whatever the screen's scale factor. The
    /// context is flagged flipped *and* given the matching transform, which is the state a
    /// flipped view draws in — so the same `draw` above serves both the screen and this.
    static func burnIn(_ annotations: [Annotation], over base: NSImage, rotation: Int) -> NSImage {
        guard !annotations.isEmpty else { return base }

        let size = base.size
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return base }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width,
                                         pixelsHigh: height,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let bitmap = NSGraphicsContext(bitmapImageRep: rep) else { return base }

        rep.size = size
        let context = NSGraphicsContext(cgContext: bitmap.cgContext, flipped: true)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)

        base.draw(in: NSRect(origin: .zero, size: size))
        draw(annotations, size: size, rotation: rotation)

        NSGraphicsContext.restoreGraphicsState()

        let composed = NSImage(size: size)
        composed.addRepresentation(rep)
        return composed
    }

    // MARK: Hit testing

    /// Topmost mark within `slack` pixels of `point`, used by the eraser. Later marks are
    /// drawn on top, so they are tested first.
    static func hit(_ annotations: [Annotation],
                    at point: CGPoint,
                    size: CGSize,
                    rotation: Int,
                    slack: CGFloat) -> UUID? {

        for annotation in annotations.reversed() {
            let points = pixelPoints(annotation, size: size, rotation: rotation)
            guard let first = points.first else { continue }

            let reach = max(slack, annotation.width.strokeFraction * size.width
                            * (annotation.tool == .highlighter ? 3 : 1))

            switch annotation.tool {
            case .text:
                let bounds = textSize(annotation, size: size)
                let frame = NSRect(x: first.x, y: first.y, width: bounds.width, height: bounds.height)
                    .insetBy(dx: -reach, dy: -reach)
                if frame.contains(point) { return annotation.id }

            case .box:
                guard points.count >= 2 else { continue }
                let rect = NSRect(x: min(points[0].x, points[1].x),
                                  y: min(points[0].y, points[1].y),
                                  width: abs(points[1].x - points[0].x),
                                  height: abs(points[1].y - points[0].y))
                let corners = [
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.minY)
                ]
                if nearPolyline(corners, point: point, reach: reach) { return annotation.id }

            default:
                if nearPolyline(points, point: point, reach: reach) { return annotation.id }
            }
        }
        return nil
    }

    private static func nearPolyline(_ points: [CGPoint], point: CGPoint, reach: CGFloat) -> Bool {
        guard points.count >= 2 else {
            guard let only = points.first else { return false }
            return hypot(only.x - point.x, only.y - point.y) <= reach
        }
        for index in 0..<(points.count - 1) {
            if distance(from: point, toSegment: points[index], points[index + 1]) <= reach {
                return true
            }
        }
        return false
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }

        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
