import MapKit
import SwiftUI

// Everything between the camera and the canvas: what of the globe can be seen from where it
// is turned to, and how a shape gets from the sphere onto the sheet. Out here rather than
// inside the map view because clipping is the part that can quietly lose a continent, and a
// thing that can do that should be callable without a window.

/// One frame's worth of "where everything goes".
struct MapSheet {

    let projection: MercatorProjection
    let size: CGSize
    /// The panel with a few points of slack, so the edges a clip leaves behind fall outside
    /// anything the canvas actually draws.
    let panel: CGRect

    init(camera: MapCamera, size: CGSize, padding: CGFloat = 4) {
        projection = camera.projection(in: size)
        self.size = size
        panel = CGRect(origin: .zero, size: size).insetBy(dx: -padding, dy: -padding)
    }

    /// For drawing inside MapKit, where the coordinate space is `MKMapPoint` itself.
    ///
    /// No camera and no view size: an overlay renderer is handed a rectangle of the world
    /// and draws that, and MapKit applies the transform. The panel is that rectangle, so
    /// the same clipping that kept a continent from costing eighty thousand points on the
    /// canvas keeps it from costing them here.
    init(mapRect: MKMapRect, padding: Double) {
        projection = MercatorProjection(mapPoints: CGSize(width: MKMapSize.world.width,
                                                          height: MKMapSize.world.height))
        size = CGSize(width: mapRect.width, height: mapRect.height)
        panel = CGRect(x: mapRect.minX, y: mapRect.minY,
                       width: mapRect.width, height: mapRect.height)
            .insetBy(dx: -padding, dy: -padding)
    }

    /// Built from what the map view is actually showing, which is the only way an overlay
    /// lands on its own base rather than near it.
    init(rect: MKMapRect, size: CGSize, padding: CGFloat = 4) {
        projection = MercatorProjection(rect: rect, in: size)
        self.size = size
        panel = CGRect(origin: .zero, size: size).insetBy(dx: -padding, dy: -padding)
    }

    func point(_ coordinate: Coordinate) -> CGPoint {
        projection.point(coordinate.direction)
    }

    /// Whether any of a shape could show up at all: one dot product for the far side of the
    /// world, one rectangle comparison for somewhere off the panel.
    func mayShow(_ cap: SphericalCap) -> Bool {
        projection.couldFace(cap) && projection.bounds(of: cap).intersects(panel)
    }

    // MARK: - Shapes

    /// A closed ring — a landmass, an island, a lake — as a path on the sheet.
    ///
    /// Two clips, in order, because they answer different questions. The globe's edge comes
    /// first: it decides what part of the ring is on the side of the sphere facing us, and
    /// closes the gap along the edge where the ring runs round the back. The panel comes
    /// second: it decides what part of *that* is on the sheet, which is what stops a ring of
    /// 80,000 points costing 80,000 points to draw when you are zoomed in on a harbour.
    ///
    /// The second clip is Sutherland-Hodgman, and it is what keeps land under your feet: the
    /// view is very often *inside* a ring — over Kansas every last point of North America is
    /// off the panel — and a clip hands back the edge of the panel where merely leaving out
    /// what you cannot see would hand back nothing at all.
    func path(ring: MapShape) -> Path {
        var points = projection.visible(ring: ring.directions)
        guard points.count > 2 else { return Path() }

        if !holds(points) {
            points = Self.clip(points, to: panel)
            guard points.count > 2 else { return Path() }
        }
        return Self.path(points, closed: true)
    }

    /// An open line — a border, a leg of a route, a meridian — as a path.
    ///
    /// No clip and no closing: a line has no inside, so where it goes round the back of the
    /// globe the pen simply lifts and comes down again where it returns.
    /// The same line, drawn as a curve through its points rather than a chain of straight
    /// bits between them.
    ///
    /// A taxiway's fillet is mapped as three or four nodes round the corner, and joining
    /// them with straight lines draws the corner as a cut-off — which is what made the
    /// yellow lines look faceted. Catmull-Rom through the same points, so nothing moves: the
    /// curve passes through every node it was given and only the space between them changes.
    func path(curve directions: [SIMD3<Double>]) -> Path {
        var points: [CGPoint] = []
        points.reserveCapacity(directions.count)
        for direction in directions where projection.faces(direction) {
            points.append(projection.point(direction))
        }
        guard points.count > 2 else { return path(line: directions) }

        var path = Path()
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let before = points[max(index - 1, 0)]
            let from = points[index]
            let to = points[index + 1]
            let after = points[min(index + 2, points.count - 1)]
            // A sixth of the way along the neighbours' span, which is the usual tension: any
            // more and a tight corner overshoots the pavement it is drawn on.
            let first = CGPoint(x: from.x + (to.x - before.x) / 6,
                                y: from.y + (to.y - before.y) / 6)
            let second = CGPoint(x: to.x - (after.x - from.x) / 6,
                                 y: to.y - (after.y - from.y) / 6)
            path.addCurve(to: to, control1: first, control2: second)
        }
        return path
    }

    /// The whole line, in one piece, with no pen lifted.
    ///
    /// For the short things: a runway is two points a couple of kilometres apart, and the
    /// pen-lifting in `path(line:)` exists for a meridian that runs off the sheet. It also
    /// breaks a dashed line into pieces, and a dash pattern starts again at every piece —
    /// so zooming in, where more of the runway falls outside the panel, slid the markings
    /// along the tarmac. One path, one phase, and the dashes stay where the paint is.
    func path(straight directions: [SIMD3<Double>]) -> Path {
        var path = Path()
        var started = false
        for direction in directions where projection.faces(direction) {
            let here = projection.point(direction)
            if started {
                path.addLine(to: here)
            } else {
                path.move(to: here)
                started = true
            }
        }
        return path
    }

    func path(line directions: [SIMD3<Double>]) -> Path {
        var path = Path()
        var drawing = false
        var last = CGPoint.zero
        var previous: CGPoint?

        for direction in directions {
            guard projection.faces(direction) else {
                previous = nil
                drawing = false
                continue
            }
            let here = projection.point(direction)
            defer { previous = here }

            // A segment is wanted, not a point: a lone point on the near side draws nothing.
            guard let before = previous else { continue }

            // Nowhere near the panel, so lift the pen. Without this a meridian thirty degrees
            // away still went into the path, and zoomed in to half a metre per point that is
            // a line ending three million points off the edge of the sheet.
            guard touchesPanel(before, here) else {
                drawing = false
                continue
            }

            if !drawing {
                path.move(to: before)
                drawing = true
                last = before
            }
            guard abs(here.x - last.x) >= 0.5 || abs(here.y - last.y) >= 0.5 else { continue }
            path.addLine(to: here)
            last = here
        }
        return path
    }

    /// Whether the box around two points reaches the panel.
    ///
    /// Grown by a point before asking, because a level or upright segment makes a rectangle of
    /// no height or no width, and an empty rectangle intersects nothing at all — which would
    /// have quietly dropped every meridian.
    private func touchesPanel(_ from: CGPoint, _ to: CGPoint) -> Bool {
        let box = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                         width: abs(to.x - from.x), height: abs(to.y - from.y))
        return box.insetBy(dx: -1, dy: -1).intersects(panel)
    }

    /// True when every point is already on the panel, and the clip is work for nothing.
    private func holds(_ points: [CGPoint]) -> Bool {
        for point in points {
            if point.x < panel.minX || point.x > panel.maxX
                || point.y < panel.minY || point.y > panel.maxY { return false }
        }
        return true
    }

    /// A ring as a path, leaving out points nearer than half a point to the last one kept.
    ///
    /// Half a point is finer than a screen can draw, and a skipped point stays within half a
    /// point of the one kept before it, so the line drawn stands in for it. This is what keeps
    /// a level of detail honest at the shallow end of its range, where its rings carry several
    /// times the detail that zoom can show.
    private static func path(_ points: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        var last = CGPoint.zero
        var kept = 0
        for point in points {
            if kept > 0, abs(point.x - last.x) < 0.5, abs(point.y - last.y) < 0.5 { continue }
            if kept == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
            last = point
            kept += 1
        }
        guard kept > 1 else { return Path() }
        if closed { path.closeSubpath() }
        return path
    }

    // MARK: - Clipping to the panel

    /// The part of a closed ring inside a rectangle: Sutherland-Hodgman, cut against each of
    /// the four edges in turn, each cut a walk keeping the points on the inside and working
    /// out where the line crosses over.
    static func clip(_ ring: [CGPoint], to rect: CGRect) -> [CGPoint] {
        var points = ring
        points = cut(points, keeping: { $0.x >= rect.minX }) { Self.atX(rect.minX, $0, $1) }
        points = cut(points, keeping: { $0.x <= rect.maxX }) { Self.atX(rect.maxX, $0, $1) }
        points = cut(points, keeping: { $0.y >= rect.minY }) { Self.atY(rect.minY, $0, $1) }
        points = cut(points, keeping: { $0.y <= rect.maxY }) { Self.atY(rect.maxY, $0, $1) }
        return points
    }

    private static func cut(_ ring: [CGPoint],
                            keeping inside: (CGPoint) -> Bool,
                            crossing: (CGPoint, CGPoint) -> CGPoint) -> [CGPoint] {
        guard let last = ring.last else { return [] }
        var out: [CGPoint] = []
        out.reserveCapacity(ring.count / 2 + 8)

        var previous = last
        var previousInside = inside(previous)
        for point in ring {
            let pointInside = inside(point)
            // A side changing between two points is a line crossing the edge; the point it
            // crosses at belongs to both halves, and so to this one.
            if pointInside != previousInside { out.append(crossing(previous, point)) }
            if pointInside { out.append(point) }
            previous = point
            previousInside = pointInside
        }
        return out
    }

    private static func atX(_ x: CGFloat, _ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let span = to.x - from.x
        guard abs(span) > 1e-12 else { return CGPoint(x: x, y: from.y) }
        let along = (x - from.x) / span
        return CGPoint(x: x, y: from.y + (to.y - from.y) * along)
    }

    private static func atY(_ y: CGFloat, _ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let span = to.y - from.y
        guard abs(span) > 1e-12 else { return CGPoint(x: from.x, y: y) }
        let along = (y - from.y) / span
        return CGPoint(x: from.x + (to.x - from.x) * along, y: y)
    }
}
