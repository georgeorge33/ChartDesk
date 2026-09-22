import AppKit
import CoreGraphics
import CoreText
import SwiftUI

/// The handful of drawing verbs the chart needs, over a plain `CGContext`.
///
/// A shim rather than a rewrite. The shapes are still built as SwiftUI `Path`s by the same
/// code that built them for the canvas — a `Path` hands over its `cgPath` — so the only
/// thing that had to change to draw inside MapKit is where the pen is.
///
/// Everything is in map points, because that is what an overlay renderer draws in. A line
/// meant to be two points thick on the screen is therefore two divided by however many
/// screen points a map point is worth at this zoom, which `screen(_:)` is for.
struct ChartContext {

    let cg: CGContext
    /// How many map points make one point on the screen, at this zoom.
    let mapPointsPerScreenPoint: Double

    /// A width or a length that should stay the same size on screen however far in you are.
    func screen(_ points: Double) -> Double { points * mapPointsPerScreenPoint }

    func fill(_ path: Path, _ colour: NSColor) {
        guard !path.isEmpty else { return }
        cg.addPath(path.cgPath)
        cg.setFillColor(colour.cgColor)
        cg.fillPath()
    }

    /// `phase` is how far into the dash pattern the line starts, for a line drawn in pieces
    /// that has to read as one: each tile strokes its own piece of an airspace boundary,
    /// and without it every piece would start its dashes afresh at the tile's edge.
    func stroke(_ path: Path, _ colour: NSColor, width: Double,
                dash: [Double] = [], phase: Double = 0,
                cap: CGLineCap = .butt, join: CGLineJoin = .miter) {
        guard !path.isEmpty, width > 0 else { return }
        cg.saveGState()
        cg.addPath(path.cgPath)
        cg.setStrokeColor(colour.cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(cap)
        cg.setLineJoin(join)
        if dash.isEmpty {
            cg.setLineDash(phase: 0, lengths: [])
        } else {
            cg.setLineDash(phase: phase, lengths: dash.map { CGFloat($0) })
        }
        cg.strokePath()
        cg.restoreGState()
    }

    /// Whatever `draw` does, kept inside `path`: a chevron's arms stop at the edge of the
    /// concrete it is painted on, however far past it the arm would have run.
    func clipped(to path: Path, _ draw: () -> Void) {
        guard !path.isEmpty else { return }
        cg.saveGState()
        cg.addPath(path.cgPath)
        cg.clip()
        draw()
        cg.restoreGState()
    }

    /// A dot that stays the same size on the screen, `radius` in points.
    func dot(at centre: CGPoint, radius: Double, _ colour: NSColor) {
        let r = screen(radius)
        cg.setFillColor(colour.cgColor)
        cg.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    }

    /// A ring round a point, `radius` and `width` in points.
    func circle(at centre: CGPoint, radius: Double, width: Double, _ colour: NSColor) {
        let r = screen(radius)
        cg.setStrokeColor(colour.cgColor)
        cg.setLineWidth(screen(width))
        cg.strokeEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    }

    // MARK: - Writing

    /// One piece of writing on the chart, in the sizes a chart uses: a few points tall on
    /// the screen however far in the map is.
    struct Label {
        let text: String
        /// A second line under a rule, the way a chart writes a ceiling over a floor.
        var under: String? = nil
        var size: Double = 11
        var weight: NSFont.Weight = .bold
        /// Figures in the monospaced face, so that a ceiling sits square over its floor.
        var mono = false
        var colour: NSColor
        /// Filled behind it, the way a ground chart writes a taxiway's letter.
        var box: NSColor? = nil
        /// And drawn round that.
        var border: NSColor? = nil
        /// A dark edge round the letters themselves, for writing with no box behind it —
        /// which over a photograph is otherwise grey on grey.
        var halo: NSColor? = nil
        /// Where it goes, in map points.
        let at: CGPoint
        /// Which point of the writing sits on `at`, as a fraction of its width and height:
        /// the middle by default, (0.5, 0) for the middle of its top edge, (0, 0.5) for its
        /// left end.
        var anchor = CGPoint(x: 0.5, y: 0.5)
        /// How far from `at` that point is, in points on the screen — so a fix's name sits
        /// the same distance above its dot however far in you are.
        var nudge = CGVector.zero
        /// How far apart, in points on the screen, two of these saying the same thing must
        /// be. A taxiway's letter repeated along it is how a chart reads; three inside a
        /// hundred metres is OpenStreetMap's way of splitting a taxiway showing through.
        var spacing: Double? = nil
    }

    /// A line of writing, shaped once at the size it is read at on the screen.
    ///
    /// Shaped in screen points and drawn under a scale, rather than shaped afresh in map
    /// points at every zoom: the map-point size changed on every step of a zoom, so every
    /// step shaped every label again, and airspace alone is thousands of them. The colour
    /// comes from the context, so one shaped line serves every colour it is drawn in.
    private final class Shaped {
        let line: CTLine
        /// Width and cap height, in screen points.
        let size: CGSize
        init(line: CTLine, size: CGSize) { self.line = line; self.size = size }
    }

    private static let shapedLines = NSCache<NSString, Shaped>()

    private static func shaped(_ text: String, size: Double, weight: NSFont.Weight,
                               mono: Bool) -> Shaped {
        let key = "\(text)|\(size)|\(weight.rawValue)|\(mono)" as NSString
        if let held = shapedLines.object(forKey: key) { return held }
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        // Cap height, not ascent plus descent. A designator is capitals and figures, so
        // the descender space is always empty, and a box built to include it sits the
        // letter visibly high in its own chip.
        let made = Shaped(line: line, size: CGSize(width: width, height: font.capHeight))
        shapedLines.setObject(made, forKey: key)
        return made
    }

    /// The gap either side of the rule in a stacked label, in points.
    private static let ruleGap = 2.5

    /// The writing's own rectangle — the letters, not the chip round them — and its lines.
    private func layout(_ label: Label) -> (rect: CGRect, top: Shaped, bottom: Shaped?) {
        let top = Self.shaped(label.text, size: label.size, weight: label.weight,
                              mono: label.mono)
        let bottom = label.under.map {
            Self.shaped($0, size: label.size, weight: label.weight, mono: label.mono)
        }
        var width = top.size.width, height = top.size.height
        if let bottom {
            width = max(width, bottom.size.width)
            height += Self.ruleGap * 2 + bottom.size.height
        }
        let size = CGSize(width: screen(width), height: screen(height))
        let origin = CGPoint(
            x: label.at.x + screen(label.nudge.dx) - size.width * label.anchor.x,
            y: label.at.y + screen(label.nudge.dy) - size.height * label.anchor.y)
        return (CGRect(origin: origin, size: size), top, bottom)
    }

    /// The chip a label occupies: the writing, plus the room around it.
    ///
    /// Room enough to read. A letter pressed against the edge of its own box is hard work
    /// over a photograph, where the box is the only thing separating it from a taxiway, an
    /// aeroplane, or a threshold's worth of white paint. Writing with no box keeps only
    /// enough for its halo.
    private func chip(_ label: Label, around writing: CGRect) -> CGRect {
        label.box == nil
            ? writing.insetBy(dx: -screen(1.5), dy: -screen(1.5))
            : writing.insetBy(dx: -screen(4), dy: -screen(3.5))
    }

    /// What a label would occupy, for deciding whether two of them collide. The chip and
    /// not the letter: the chip is what you can see.
    func bounds(of label: Label) -> CGRect {
        chip(label, around: layout(label).rect)
    }

    func draw(_ label: Label) {
        let (writing, top, bottom) = layout(label)

        if let colour = label.box {
            let box = chip(label, around: writing)
            let shape = CGPath(roundedRect: box, cornerWidth: screen(3),
                               cornerHeight: screen(3), transform: nil)
            cg.addPath(shape)
            cg.setFillColor(colour.cgColor)
            cg.fillPath()
            if let border = label.border {
                cg.addPath(shape)
                cg.setStrokeColor(border.cgColor)
                cg.setLineWidth(screen(1))
                cg.strokePath()
            }
        }

        // Each line's baseline on the bottom of its own cap box, which is by definition
        // where a capital's feet are.
        let first = writing.minY + screen(top.size.height)
        write(top, centredOn: writing.midX, baseline: first, label)
        guard let bottom else { return }

        // Ceiling over floor with a rule between, the way a chart writes it.
        let ruleY = first + screen(Self.ruleGap)
        var rule = Path()
        rule.move(to: CGPoint(x: writing.minX, y: ruleY))
        rule.addLine(to: CGPoint(x: writing.maxX, y: ruleY))
        if let halo = label.halo {
            stroke(rule, halo, width: screen(2.6), cap: .round)
        }
        stroke(rule, label.colour, width: screen(0.8))
        write(bottom, centredOn: writing.midX, baseline: writing.maxY, label)
    }

    /// One line, drawn under a scale so that it comes out at its size on the screen.
    ///
    /// Core Text draws with y upwards and this context has y running south, so the line is
    /// flipped back about its own baseline rather than the whole world being turned over —
    /// which would take the shapes with it.
    private func write(_ line: Shaped, centredOn middle: Double, baseline: Double,
                       _ label: Label) {
        cg.saveGState()
        cg.setShouldAntialias(true)
        cg.setAllowsFontSmoothing(true)
        cg.setShouldSmoothFonts(true)
        cg.textMatrix = .identity
        cg.translateBy(x: middle - screen(line.size.width) / 2, y: baseline)
        cg.scaleBy(x: mapPointsPerScreenPoint, y: -mapPointsPerScreenPoint)
        cg.textPosition = .zero
        if let halo = label.halo {
            // The halo first, as a stroke round the letters in the halo's colour: in text
            // space now, so the width is in points on the screen.
            cg.setTextDrawingMode(.stroke)
            cg.setLineWidth(2.4)
            cg.setLineJoin(.round)
            cg.setStrokeColor(halo.cgColor)
            CTLineDraw(line.line, cg)
            cg.setTextDrawingMode(.fill)
            // Drawing a line moves the pen to its end. Without going back, the letters
            // were drawn a word to the right of their own halo.
            cg.textPosition = .zero
        }
        cg.setFillColor(label.colour.cgColor)
        CTLineDraw(line.line, cg)
        cg.restoreGState()
    }

    // MARK: - Paint

    /// Figures for painting on the ground, shaped once at a reference size — the size is
    /// the ground's business, not the screen's — with their colour from the context.
    private static let paints = NSCache<NSString, Shaped>()

    private static func painted(_ text: String) -> Shaped {
        if let held = paints.object(forKey: text as NSString) { return held }
        // Narrow and heavy, the way runway figures are painted: tall enough to read from
        // a cockpit on the approach, narrow enough that three of them fit across.
        let font = NSFont.systemFont(ofSize: 100, weight: .bold, width: .condensed)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let made = Shaped(line: line, size: CGSize(width: width, height: font.capHeight))
        paints.setObject(made, forKey: text as NSString)
        return made
    }

    /// How big painted figures would be on the screen, to decide whether they are worth
    /// painting at all or whether a label beside the runway says it better.
    func paintedHeight(inMapPoints height: Double) -> Double {
        height / mapPointsPerScreenPoint
    }

    /// Writing laid on the ground rather than floated above it: a runway's number, as tall
    /// in map points as the paint is in metres, with the tops of the figures facing `up`.
    ///
    /// The line is turned rather than the world. Its baseline runs a right angle clockwise
    /// from `up` on the page, which on a runway means across it, left to right as the
    /// pilot landing on it sees it.
    func paint(_ text: String, centre: CGPoint, facing up: CGVector, capHeight: Double,
               colour: NSColor) {
        let length = hypot(up.dx, up.dy)
        guard length > 0, capHeight > 0 else { return }
        let top = CGVector(dx: up.dx / length, dy: up.dy / length)
        let across = CGVector(dx: -top.dy, dy: top.dx)

        let made = Self.painted(text)
        let unit = capHeight / made.size.height
        let origin = CGPoint(
            x: centre.x - (across.dx * made.size.width + top.dx * made.size.height) * unit / 2,
            y: centre.y - (across.dy * made.size.width + top.dy * made.size.height) * unit / 2)

        cg.saveGState()
        cg.setShouldAntialias(true)
        cg.concatenate(CGAffineTransform(a: across.dx * unit, b: across.dy * unit,
                                         c: top.dx * unit, d: top.dy * unit,
                                         tx: origin.x, ty: origin.y))
        cg.textMatrix = .identity
        cg.textPosition = .zero
        cg.setFillColor(colour.cgColor)
        CTLineDraw(made.line, cg)
        cg.restoreGState()
    }

    /// The box painted figures cover, square to the page, for keeping labels off them.
    func paintedBounds(_ text: String, centre: CGPoint, facing up: CGVector,
                       capHeight: Double) -> CGRect {
        let made = Self.painted(text)
        let unit = capHeight / made.size.height
        let length = max(hypot(up.dx, up.dy), 1e-9)
        let top = CGVector(dx: up.dx / length, dy: up.dy / length)
        let halfAcross = made.size.width * unit / 2, halfUp = capHeight / 2
        let reachX = abs(top.dy) * halfAcross + abs(top.dx) * halfUp
        let reachY = abs(top.dx) * halfAcross + abs(top.dy) * halfUp
        return CGRect(x: centre.x - reachX, y: centre.y - reachY,
                      width: reachX * 2, height: reachY * 2)
    }
}
