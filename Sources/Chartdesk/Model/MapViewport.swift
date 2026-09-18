import SwiftUI

// The geometry between a camera and a canvas: what the view covers, what of a ring falls
// inside it, and where a coordinate lands on the sheet. Out here rather than inside the map
// view because clipping is the part that can quietly lose a continent, and a thing that can
// do that should be callable without a window.

/// The view as a box of degrees, which is what a ring gets clipped against.
///
/// In degrees rather than in the projection's space because the test runs per point, and
/// projecting each of a ring's 80,000 points only to find it is in another ocean is the
/// cost this exists to avoid. Padded a few points past the panel, so the edges a clip
/// leaves behind land outside anything the canvas draws.
struct MapWindow {
    let box: CoordinateBox
    /// The same padded view, projected, for culling whole features.
    let bounds: CGRect
    /// Which copy of the world this is: a turn of the globe west, none, or east.
    let shift: Double

    init(visible: CGRect, shift: Double, padding: Double) {
        self.shift = shift
        let west = Double(visible.minX) - shift - padding
        let east = Double(visible.maxX) - shift + padding
        // y grows downwards, so the top of the rectangle is the higher latitude.
        let top = Double(visible.minY) - padding
        let bottom = Double(visible.maxY) + padding
        box = CoordinateBox(west: west * 360 - 180, east: east * 360 - 180,
                            south: Mercator.latitude(atY: bottom),
                            north: Mercator.latitude(atY: top))
        bounds = CGRect(x: west, y: top, width: east - west, height: bottom - top)
    }

    /// The part of a closed ring that falls inside the view.
    ///
    /// Sutherland-Hodgman: the ring is cut against each of the four edges in turn, each cut
    /// a walk keeping the points on the inside and working out where the line crosses over.
    /// A clip rather than simply leaving out the parts you cannot see, because the view is
    /// so often *inside* a ring — over Kansas every last point of North America is off the
    /// panel, and a ring cut down to what you can see is one that no longer says Kansas is
    /// land. Clipping says it, by handing back the edge of the panel.
    ///
    /// Only the edges the ring actually crosses are walked, so an island sitting well
    /// inside the view is handed back untouched.
    ///
    /// Latitudes along a cut are interpolated in degrees rather than through the
    /// projection, which puts a crossing a hair from where Mercator would have. It lands on
    /// the padded edge either way, which is off the panel and never drawn.
    func clip(_ ring: [Coordinate], box shape: CoordinateBox) -> [Coordinate] {
        var points = ring
        if shape.west < box.west {
            points = Self.cut(points, inside: { $0.longitude >= box.west }) { first, second in
                Self.along(first, second,
                           at: (box.west - first.longitude)
                               / (second.longitude - first.longitude))
            }
        }
        if shape.east > box.east {
            points = Self.cut(points, inside: { $0.longitude <= box.east }) { first, second in
                Self.along(first, second,
                           at: (box.east - first.longitude)
                               / (second.longitude - first.longitude))
            }
        }
        if shape.south < box.south {
            points = Self.cut(points, inside: { $0.latitude >= box.south }) { first, second in
                Self.along(first, second,
                           at: (box.south - first.latitude)
                               / (second.latitude - first.latitude))
            }
        }
        if shape.north > box.north {
            points = Self.cut(points, inside: { $0.latitude <= box.north }) { first, second in
                Self.along(first, second,
                           at: (box.north - first.latitude)
                               / (second.latitude - first.latitude))
            }
        }
        return points
    }

    /// One pass of the clip: the ring cut against a single edge.
    private static func cut(_ ring: [Coordinate],
                     inside: (Coordinate) -> Bool,
                     crossing: (Coordinate, Coordinate) -> Coordinate) -> [Coordinate] {
        guard let last = ring.last else { return [] }
        var out: [Coordinate] = []
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

    private static func along(_ first: Coordinate, _ second: Coordinate,
                              at fraction: Double) -> Coordinate {
        Coordinate(latitude: first.latitude + (second.latitude - first.latitude) * fraction,
                   longitude: first.longitude
                       + (second.longitude - first.longitude) * fraction)
    }
}

/// Turns coordinates into points on the sheet, with the camera's arithmetic done once.
///
/// `MapCamera.screen` projects the centre afresh for every coordinate handed to it, which
/// down a ring of 80,000 points is 80,000 logarithms nobody asked for.
struct MapPlotter {
    private let anchor: CGPoint
    private let width: Double
    private let centre: CGPoint

    init(camera: MapCamera, size: CGSize) {
        anchor = Mercator.point(camera.centre)
        width = Double(camera.worldWidth)
        centre = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func point(_ coordinate: Coordinate, offset: Double = 0) -> CGPoint {
        let projected = Mercator.point(coordinate)
        return CGPoint(x: centre.x + (projected.x - anchor.x) * width + offset,
                       y: centre.y + (projected.y - anchor.y) * width)
    }

    /// A ring or a line as a path, leaving out points nearer than half a point to the last
    /// one kept.
    ///
    /// Half a point is finer than a screen can draw, and a skipped point is within half a
    /// point of the one kept before it, so the line drawn stands in for it. This is what
    /// keeps a tier honest at the shallow end of its range, where its rings carry several
    /// times the detail that zoom can show.
    func path(_ points: [Coordinate], offset: Double, closed: Bool) -> Path {
        var path = Path()
        var last = CGPoint.zero
        var kept = 0
        for coordinate in points {
            let here = point(coordinate, offset: offset)
            if kept > 0, abs(here.x - last.x) < 0.5, abs(here.y - last.y) < 0.5 { continue }
            if kept == 0 {
                path.move(to: here)
            } else {
                path.addLine(to: here)
            }
            last = here
            kept += 1
        }
        guard kept > 1 else { return Path() }
        if closed { path.closeSubpath() }
        return path
    }
}
