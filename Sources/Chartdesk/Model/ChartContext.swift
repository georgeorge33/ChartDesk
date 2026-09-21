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

    private func line(_ label: Label) -> (CTLine, CGSize) {
        let points = label.size * mapPointsPerScreenPoint
        let font = label.bold ? NSFont.boldSystemFont(ofSize: points)
                              : NSFont.systemFont(ofSize: points)
        let attributed = NSAttributedString(string: label.text, attributes: [
            .font: font, .foregroundColor: label.colour,
        ])
        let made = CTLineCreateWithAttributedString(attributed)
        let key = "\(label.text)|\(label.bold)|\(points)" as NSString
        if let held = Self.measured.object(forKey: key) {
            return (made, held.sizeValue)
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(made, &ascent, &descent, nil)
        let size = CGSize(width: width, height: ascent + descent)
        Self.measured.setObject(NSValue(size: size), forKey: key)
        return (made, size)
    }

    /// What a label would occupy, for deciding whether two of them collide.
    func bounds(of label: Label) -> CGRect {
        let (_, size) = line(label)
        return CGRect(x: label.at.x - size.width / 2, y: label.at.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    func draw(_ label: Label) {
        let (made, size) = line(label)
        let frame = CGRect(x: label.at.x - size.width / 2, y: label.at.y - size.height / 2,
                           width: size.width, height: size.height)
        if let box = label.box {
            let around = frame.insetBy(dx: -screen(2.5), dy: -screen(1.5))
            let shape = CGPath(roundedRect: around, cornerWidth: screen(2),
                               cornerHeight: screen(2), transform: nil)
            cg.addPath(shape)
            cg.setFillColor(box.cgColor)
            cg.fillPath()
            if let border = label.border {
                cg.addPath(shape)
                cg.setStrokeColor(border.cgColor)
                cg.setLineWidth(screen(0.8))
                cg.strokePath()
            }
        }
        // Core Text draws with y upwards and this context has y running south, so the
        // writing is flipped back about its own baseline rather than the whole world being
        // turned over — which would take the shapes with it.
        cg.saveGState()
        cg.textMatrix = .identity
        cg.translateBy(x: frame.minX, y: frame.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.textPosition = CGPoint(x: 0, y: size.height * 0.24)
        CTLineDraw(made, cg)
        cg.restoreGState()
    }
}
