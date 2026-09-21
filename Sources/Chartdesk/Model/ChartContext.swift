import AppKit
import CoreGraphics
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
}
