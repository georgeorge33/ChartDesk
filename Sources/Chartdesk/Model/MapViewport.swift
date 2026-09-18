import SwiftUI

// Everything between the camera and the canvas: what of the globe can be seen from where it
// is turned to, and how a shape gets from the sphere onto the sheet. Out here rather than
// inside the map view because clipping is the part that can quietly lose a continent, and a
// thing that can do that should be callable without a window.

/// One frame's worth of "where everything goes".
struct MapSheet {

    let projection: GlobeProjection
    let size: CGSize
    /// The panel with a few points of slack, so the edges a clip leaves behind fall outside
    /// anything the canvas actually draws.
    let panel: CGRect
    /// True when the globe's edge is on the sheet, and shapes running off it have to be
    /// closed along it. False once zoomed in past the point where the edge is visible, which
    /// is most of the time you are looking at a route.
    let showsEdge: Bool

    init(camera: MapCamera, size: CGSize, padding: CGFloat = 4) {
        projection = camera.projection(in: size)
        self.size = size
        panel = CGRect(origin: .zero, size: size).insetBy(dx: -padding, dy: -padding)
        showsEdge = projection.showsHorizon(in: size)
    }

    /// The globe's outline, for drawing the sea and for shading the sphere.
    var disc: CGRect { projection.disc() }

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
    func path(line directions: [SIMD3<Double>]) -> Path {
        var path = Path()
        var drawing = false
        var last = CGPoint.zero

        for direction in directions {
            guard projection.faces(direction) else {
                drawing = false
                continue
            }
            let here = projection.point(direction)
            if drawing {
                guard abs(here.x - last.x) >= 0.5 || abs(here.y - last.y) >= 0.5 else { continue }
                path.addLine(to: here)
            } else {
                path.move(to: here)
                drawing = true
            }
            last = here
        }
        return path
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
