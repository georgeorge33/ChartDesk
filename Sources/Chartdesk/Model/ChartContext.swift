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

    func stroke(_ path: Path, _ colour: NSColor, width: Double,
                dash: [Double] = [], cap: CGLineCap = .butt, join: CGLineJoin = .miter) {
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
            cg.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
        }
        cg.strokePath()
        cg.restoreGState()
    }

    // MARK: - Writing

    /// One piece of writing on the chart, in the sizes a chart uses: a few points tall on
    /// the screen however far in the map is.
    struct Label {
        let text: String
        var size: Double = 11
        var bold: Bool = true
        var colour: NSColor
        /// Filled behind it, the way a ground chart writes a taxiway's letter.
        var box: NSColor?
        /// And drawn round that.
        var border: NSColor?
        /// Where it goes, in map points.
        let at: CGPoint
    }

    /// Measured once per string and size. The same two dozen designators are drawn every
    /// frame, and shaping them is the expensive half of writing them.
    private static let measured = NSCache<NSString, NSValue>()

    private func font(_ label: Label) -> NSFont {
        let points = label.size * mapPointsPerScreenPoint
        return label.bold ? NSFont.boldSystemFont(ofSize: points)
                          : NSFont.systemFont(ofSize: points)
    }

    /// The line, and how wide and how tall the writing itself is.
    ///
    /// Tall means cap height, not ascent plus descent. A designator is a capital letter or
    /// a number, so the descender space is always empty, and a box built to include it sits
    /// the letter visibly high in its own chip. Cap height is the box the letter actually
    /// fills, which is what makes it look centred.
    private func line(_ label: Label) -> (CTLine, CGSize) {
        let font = font(label)
        let attributed = NSAttributedString(string: label.text, attributes: [
            .font: font, .foregroundColor: label.colour,
        ])
        let made = CTLineCreateWithAttributedString(attributed)
        let key = "\(label.text)|\(label.bold)|\(font.pointSize)" as NSString
        if let held = Self.measured.object(forKey: key) {
            return (made, held.sizeValue)
        }
        let width = CTLineGetTypographicBounds(made, nil, nil, nil)
        let size = CGSize(width: width, height: font.capHeight)
        Self.measured.setObject(NSValue(size: size), forKey: key)
        return (made, size)
    }

    /// The chip a label occupies: the writing, plus the room around it.
    ///
    /// Room enough to read. A letter pressed against the edge of its own box is hard work
    /// over a photograph, where the box is the only thing separating it from a taxiway, an
    /// aeroplane, or a threshold's worth of white paint.
    private func chip(_ label: Label, around writing: CGSize) -> CGRect {
        CGRect(x: label.at.x - writing.width / 2, y: label.at.y - writing.height / 2,
               width: writing.width, height: writing.height)
            .insetBy(dx: -screen(4), dy: -screen(3.5))
    }

    /// What a label would occupy, for deciding whether two of them collide. The chip and
    /// not the letter: the chip is what you can see.
    func bounds(of label: Label) -> CGRect {
        let (_, writing) = line(label)
        return chip(label, around: writing)
    }

    func draw(_ label: Label) {
        let (made, writing) = line(label)
        let box = chip(label, around: writing)

        if let colour = label.box {
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

        // Core Text draws with y upwards and this context has y running south, so the
        // writing is flipped back about its own baseline rather than the whole world being
        // turned over — which would take the shapes with it.
        //
        // The baseline sits on the bottom of the cap box, which is where a capital's feet
        // are by definition. No fudge factor: the old one was a guess at the descent and
        // left every label a fraction high.
        cg.saveGState()
        cg.setShouldAntialias(true)
        cg.setAllowsFontSmoothing(true)
        cg.setShouldSmoothFonts(true)
        cg.textMatrix = .identity
        cg.translateBy(x: box.midX - writing.width / 2,
                       y: label.at.y + writing.height / 2)
        cg.scaleBy(x: 1, y: -1)
        cg.textPosition = .zero
        CTLineDraw(made, cg)
        cg.restoreGState()
    }
}
