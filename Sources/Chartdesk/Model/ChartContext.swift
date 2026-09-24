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
    ///
    /// Equatable so that a label still on the map at the next zoom, saying the same thing
    /// in the same place, can be left alone rather than drawn again.
    struct Label: Equatable {
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
        var at: CGPoint
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
        /// Turned about its anchor, in radians, clockwise on the page.
        var angle: Double = 0
        /// Laid along this line instead of straight: the middle of the writing's height
        /// follows it, in map points, from the writing's left end to its right. For an
        /// airspace tag that curves with its ring, chip and all.
        var path: [CGPoint]? = nil
        /// Which label this is from one zoom to the next, where its place does not say.
        /// Most labels sit at a map point that the zoom never moves; a tag along an
        /// airspace boundary is set in from its ring by so many points of the screen, so
        /// its map point creeps with the zoom, and it is known by its ring and its place
        /// round it instead.
        var identity: String? = nil
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
        /// The line's glyphs, run by run, with where each sits along the baseline and how
        /// far it advances: for setting the writing along a curve a glyph at a time.
        let glyphs: [Glyph]

        struct Glyph {
            let font: CTFont
            let glyph: CGGlyph
            /// Along the baseline from the line's start, and the glyph's advance.
            let x: Double
            let advance: Double
        }

        init(line: CTLine, size: CGSize) {
            self.line = line
            self.size = size
            var glyphs: [Glyph] = []
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0,
                      let value = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String],
                      CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID()
                else { continue }
                let font = value as! CTFont
                var ids = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                let all = CFRange(location: 0, length: 0)
                CTRunGetGlyphs(run, all, &ids)
                CTRunGetPositions(run, all, &positions)
                CTRunGetAdvances(run, all, &advances)
                for index in 0..<count {
                    glyphs.append(Glyph(font: font, glyph: ids[index],
                                        x: Double(positions[index].x),
                                        advance: Double(advances[index].width)))
                }
            }
            self.glyphs = glyphs
        }
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
    /// not the letter: the chip is what you can see. A turned label claims the square box
    /// round its turned chip, which is more room than it covers and never less.
    func bounds(of label: Label) -> CGRect {
        if let path = label.path, path.count > 1 {
            // The line, with half the band's height all round: the round ends included.
            let reach = band(of: label) / 2 + screen(1)
            var minX = path[0].x, maxX = path[0].x, minY = path[0].y, maxY = path[0].y
            for point in path.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX - reach, y: minY - reach,
                          width: maxX - minX + reach * 2, height: maxY - minY + reach * 2)
        }
        let box = chip(label, around: layout(label).rect)
        guard label.angle != 0 else { return box }
        let pivot = Self.pivot(of: label, in: self)
        let turn = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: label.angle)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        return box.applying(turn)
    }

    /// The point a label turns about: where its anchor sits.
    private static func pivot(of label: Label, in context: ChartContext) -> CGPoint {
        CGPoint(x: label.at.x + context.screen(label.nudge.dx),
                y: label.at.y + context.screen(label.nudge.dy))
    }

    /// How tall the chip is round a label's writing, in map points: its cap height and the
    /// room above and below it.
    func band(of label: Label) -> Double {
        let top = Self.shaped(label.text, size: label.size, weight: label.weight,
                              mono: label.mono)
        return screen(top.size.height + 7)
    }

    func draw(_ label: Label) {
        if let path = label.path, path.count > 1 {
            drawAlong(path, label)
            return
        }
        guard label.angle == 0 else {
            // Laid out square to the page and then turned as a whole about its anchor,
            // chip, rule and all.
            let pivot = Self.pivot(of: label, in: self)
            cg.saveGState()
            cg.translateBy(x: pivot.x, y: pivot.y)
            cg.rotate(by: label.angle)
            cg.translateBy(x: -pivot.x, y: -pivot.y)
            var square = label
            square.angle = 0
            draw(square)
            cg.restoreGState()
            return
        }
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

    // MARK: - Writing along a line

    /// A label laid along a line: the chip as a band stroked along it with round ends, its
    /// border a band a little wider underneath, and the writing a glyph at a time, each
    /// turned to the line where its middle falls and centred on it top to bottom.
    private func drawAlong(_ path: [CGPoint], _ label: Label) {
        let shaped = Self.shaped(label.text, size: label.size, weight: label.weight,
                                 mono: label.mono)
        var line = Path()
        line.move(to: path[0])
        for point in path.dropFirst() { line.addLine(to: point) }
        let band = band(of: label)
        if let border = label.border {
            stroke(line, border, width: band + screen(2), cap: .round, join: .round)
        }
        if let box = label.box {
            stroke(line, box, width: band, cap: .round, join: .round)
        }

        var lengths = [0.0]
        lengths.reserveCapacity(path.count)
        for index in 1..<path.count {
            let a = path[index - 1], b = path[index]
            lengths.append(lengths[index - 1] + Double(hypot(b.x - a.x, b.y - a.y)))
        }
        let total = lengths[lengths.count - 1]
        guard total > 0 else { return }

        // A point that far along the line and the way it runs there; past either end, on
        // along the end's own direction.
        func along(_ distance: Double) -> (point: CGPoint, x: Double, y: Double) {
            var index = 1
            while index < path.count - 1, lengths[index] < distance { index += 1 }
            let a = path[index - 1], b = path[index]
            let span = lengths[index] - lengths[index - 1]
            let x = span > 0 ? Double(b.x - a.x) / span : 1
            let y = span > 0 ? Double(b.y - a.y) / span : 0
            let t = distance - lengths[index - 1]
            return (CGPoint(x: Double(a.x) + x * t, y: Double(a.y) + y * t), x, y)
        }

        let unit = mapPointsPerScreenPoint
        let start = (total - screen(shaped.size.width)) / 2
        let half = screen(shaped.size.height) / 2
        cg.saveGState()
        cg.setShouldAntialias(true)
        cg.setAllowsFontSmoothing(true)
        cg.setShouldSmoothFonts(true)
        cg.textMatrix = .identity
        cg.setFillColor(label.colour.cgColor)
        for glyph in shaped.glyphs {
            let advance = screen(glyph.advance)
            let middle = along(start + screen(glyph.x) + advance / 2)
            // Up, for the writing, is a right angle anticlockwise on the page from the way
            // the line runs — with y running down, that is (y, -x).
            let upX = middle.y, upY = -middle.x
            let originX = Double(middle.point.x) - middle.x * advance / 2 - upX * half
            let originY = Double(middle.point.y) - middle.y * advance / 2 - upY * half
            cg.saveGState()
            cg.concatenate(CGAffineTransform(a: middle.x * unit, b: middle.y * unit,
                                             c: upX * unit, d: upY * unit,
                                             tx: originX, ty: originY))
            var id = glyph.glyph
            var at = CGPoint.zero
            CTFontDrawGlyphs(glyph.font, &id, &at, 1, cg)
            cg.restoreGState()
        }
        cg.restoreGState()
    }
}
