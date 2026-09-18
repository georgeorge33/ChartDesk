import CoreGraphics
import Foundation
import simd

// The globe: the map drawn as a sphere seen from outside, rather than as a Mercator sheet.
//
// Orthographic — the viewer is infinitely far off, looking at one point on the surface. That
// is what makes it read as a sphere: the middle of the view is face-on and the edges fall away
// exactly as a ball's do. It costs the far hemisphere, which is simply not there to be drawn.
//
// Three things get easier. A great circle is the shortest path and now looks like it, so an
// ocean crossing needs no apology. There is no antimeridian: a sphere has no seam, so the
// ±360° copies every shape used to be drawn in are gone. And scale is honest everywhere,
// where Mercator stretched Greenland to the size of Africa.
//
// One thing gets much harder, and it is the reason for most of the code below: a shape that
// runs off the edge of the globe has to be closed along that edge. See `Horizon`.

extension Coordinate {

    /// The point on the unit sphere this coordinate names.
    var direction: SIMD3<Double> {
        let latitude = self.latitude * .pi / 180
        let longitude = self.longitude * .pi / 180
        let ring = cos(latitude)
        return SIMD3(ring * cos(longitude), ring * sin(longitude), sin(latitude))
    }

    init(_ direction: SIMD3<Double>) {
        latitude = asin(min(max(direction.z, -1), 1)) * 180 / .pi
        longitude = atan2(direction.y, direction.x) * 180 / .pi
    }
}

/// The smallest cap of the sphere holding a shape — a centre and an angle out from it.
///
/// What a bounding box was for Mercator. A box of longitudes and latitudes says nothing useful
/// on a globe: near a pole it wraps the whole world, and it cannot answer the one question
/// worth asking, which is whether any of this shape is on the side of the sphere facing us.
struct SphericalCap {
    /// Unit vector to the middle of the shape.
    let centre: SIMD3<Double>
    /// The cosine and sine of the angle out to the furthest point.
    ///
    /// Kept as a cosine rather than an angle because that is what a dot product gives: finding
    /// the cap costs one dot per point of a shape instead of one arc cosine, and across the
    /// deepest tier that is 380,000 of them saved at load.
    let cosRadius: Double
    let sinRadius: Double

    var radius: Double { acos(min(max(cosRadius, -1), 1)) }

    init(_ directions: [SIMD3<Double>]) {
        var sum = SIMD3<Double>.zero
        for direction in directions { sum += direction }
        // A shape spread evenly round the globe sums to nothing; anything will do for it, and
        // the radius below comes out large enough to keep it whatever it is.
        let middle = simd_length(sum) > 1e-9 ? simd_normalize(sum) : SIMD3(0, 0, 1)

        var closest = 1.0
        for direction in directions {
            closest = min(closest, simd_dot(middle, direction))
        }
        centre = middle
        cosRadius = closest
        sinRadius = (1 - closest * closest).squareRoot()
    }
}

/// The globe, drawn orthographically.
struct GlobeProjection {

    /// Screen-right, screen-up and straight-at-the-viewer, as unit vectors.
    let east: SIMD3<Double>
    let north: SIMD3<Double>
    let forward: SIMD3<Double>
    /// The sphere's radius in points on the sheet.
    let radius: Double
    /// Where the middle of the sphere lands.
    let middle: CGPoint

    init(centre: Coordinate, radius: Double, in size: CGSize) {
        let latitude = centre.latitude * .pi / 180
        let longitude = centre.longitude * .pi / 180
        forward = SIMD3(cos(latitude) * cos(longitude),
                        cos(latitude) * sin(longitude),
                        sin(latitude))
        east = SIMD3(-sin(longitude), cos(longitude), 0)
        north = SIMD3(-sin(latitude) * cos(longitude),
                      -sin(latitude) * sin(longitude),
                      cos(latitude))
        self.radius = radius
        middle = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Where a direction lands on the sheet. Meaningless for anything behind the horizon, so
    /// ask `faces` first.
    func point(_ direction: SIMD3<Double>) -> CGPoint {
        let across = simd_dot(direction, east) * radius
        let up = simd_dot(direction, north) * radius
        return CGPoint(x: middle.x + CGFloat(across), y: middle.y - CGFloat(up))
    }

    /// True for the hemisphere turned towards the viewer.
    func faces(_ direction: SIMD3<Double>) -> Bool {
        simd_dot(direction, forward) > 0
    }

    /// How far round the sphere a point is from straight-ahead, in radians.
    func angle(of direction: SIMD3<Double>) -> Double {
        acos(min(max(simd_dot(direction, forward), -1), 1))
    }

    /// What is under a point on the sheet, or nil for a point off the globe entirely.
    func direction(at point: CGPoint) -> SIMD3<Double>? {
        let across = Double(point.x - middle.x) / radius
        let up = -Double(point.y - middle.y) / radius
        let fromMiddle = across * across + up * up
        guard fromMiddle <= 1 else { return nil }
        let towards = (1 - fromMiddle).squareRoot()
        return across * east + up * north + towards * forward
    }

    /// True when the whole globe fits on the sheet, which is when its edge has to be drawn
    /// and shapes running off it have to be closed along it.
    func showsHorizon(in size: CGSize) -> Bool {
        radius < Double(max(size.width, size.height))
    }

    /// The circle the globe's edge draws as.
    func disc() -> CGRect {
        let across = CGFloat(radius)
        let corner = CGPoint(x: middle.x - across, y: middle.y - across)
        let side = CGSize(width: across * 2, height: across * 2)
        return CGRect(origin: corner, size: side)
    }
}

// MARK: - The edge of the globe

extension GlobeProjection {

    /// Where round the globe's edge a direction sits, in radians, measured from screen-right.
    ///
    /// Defined for the far hemisphere as well as the near one — which is the point of it. A
    /// shape that runs off the edge has to be closed along that edge, and the part that is
    /// hidden is what says which way round to go.
    func azimuth(of direction: SIMD3<Double>) -> Double {
        atan2(simd_dot(direction, north), simd_dot(direction, east))
    }

    /// A point on the globe's edge at the given azimuth.
    func edge(at azimuth: Double) -> CGPoint {
        let across = cos(azimuth) * radius
        let up = sin(azimuth) * radius
        return CGPoint(x: middle.x + CGFloat(across), y: middle.y - CGFloat(up))
    }

    /// Where a segment between a facing point and a hidden one crosses the edge.
    private func crossing(_ from: SIMD3<Double>, _ to: SIMD3<Double>) -> SIMD3<Double> {
        let here = simd_dot(from, forward)
        let there = simd_dot(to, forward)
        let along = here / (here - there)
        let between = from + (to - from) * along
        let length = simd_length(between)
        return length > 1e-12 ? between / length : from
    }

    /// How a closing arc's direction is chosen, where the rule has a choice.
    enum Closing: CaseIterable {
        /// Avoid the widest stretch of edge with no crossing on it.
        case emptiest
        /// Avoid swallowing another crossing, preferring clockwise when neither would.
        case fewestCrossings
        /// The same, preferring anticlockwise.
        case fewestCrossingsOtherWay
        /// Every arc clockwise, and every arc anticlockwise.
        case allClockwise
        case allAnticlockwise
    }

    /// The visible part of a closed ring, as points on the sheet.
    ///
    /// Sutherland-Hodgman cannot do this. Its clip regions are half-planes, and the region
    /// here is a hemisphere whose boundary on the sheet is a circle — so where a ring leaves
    /// the globe and comes back, the two ends have to be joined by an *arc* of that circle
    /// rather than the straight line a half-plane clip would leave. A straight line there
    /// draws a chord across the face of the globe: a continent with a slice cut off.
    ///
    /// Which way round each arc goes is the whole difficulty, and five rules for deciding it
    /// up front were each wrong somewhere:
    ///
    /// * the shorter way — the land is sometimes the larger part, and an island half over the
    ///   horizon came out as coastline round the entire globe;
    /// * the bearings of the hidden stretch — meaningless where a ring merely grazes the edge
    ///   and every bearing is all but equal;
    /// * the ring's own winding, clockwise in every table — different gaps of one ring
    ///   genuinely need different directions;
    /// * the arc holding no other crossing — wrong for Sulawesi on the limb, whose crossings
    ///   sit within five degrees of one another;
    /// * which stretches of the edge are land, by parity — right about a stretch, but a single
    ///   arc can span several of them.
    ///
    /// So the answer is not chosen, it is *checked*. Each rule is tried and the first result
    /// that could exist is kept: positive area, and no larger than the face of the globe,
    /// which a ring cut down to the face cannot be. Going the wrong way round adds whole turns
    /// of the edge, so a wrong answer fails one of those or the other. Where none of them
    /// works the ring is left out rather than drawn wrong — which costs a sliver of coast at
    /// the very edge of the globe, against painting the whole world as land.
    func visible(ring: [SIMD3<Double>], steps: Double = 0.05) -> [CGPoint] {
        guard ring.count > 2 else { return [] }

        var facing = [Bool](repeating: false, count: ring.count)
        var anyFacing = false
        var anyHidden = false
        for (index, direction) in ring.enumerated() {
            let ahead = faces(direction)
            facing[index] = ahead
            if ahead { anyFacing = true } else { anyHidden = true }
        }

        if !anyHidden { return ring.map(point) }
        // Wholly out of view, so nothing to draw. A ring large enough for the globe's whole
        // face to fall inside it would have to be filled instead, but none exists: no
        // landmass on Earth is wider than a hemisphere, and the widest — Africa and Eurasia
        // together, a cap of 95° — always has coast in view when its middle does.
        if !anyFacing { return [] }

        let face = Double.pi * radius * radius
        var best: [CGPoint] = []
        var bestArea = Double.infinity

        for closing in Closing.allCases {
            let candidate = trace(ring: ring, facing: facing, closing: closing, steps: steps)
            guard candidate.count > 2 else { continue }
            let area = Self.area(candidate)
            if area > 0, area <= face * Self.mostOfTheFace { return candidate }
            if abs(area) < bestArea {
                bestArea = abs(area)
                best = candidate
            }
        }
        // Nothing possible. Better a missing sliver than a globe painted over.
        return bestArea <= face * Self.mostOfTheFace ? best : []
    }

    /// The most of the globe's face a single ring may honestly cover.
    ///
    /// Snug deliberately. Going the wrong way round the edge traces the entire edge, and that
    /// answer has an area of *exactly* the face — so a tolerance above 1 waves it through,
    /// which is how eighteen views still came back painted over. No landmass can cover a whole
    /// hemisphere: the widest is Africa and Eurasia together, whose visible part peaks near
    /// half the face.
    static let mostOfTheFace = 0.9

    /// The signed area of a closed screen-space ring.
    static func area(_ points: [CGPoint]) -> Double {
        guard points.count > 2 else { return 0 }
        var twice = 0.0
        for index in points.indices {
            let here = points[index], next = points[(index + 1) % points.count]
            twice += Double(here.x * next.y - next.x * here.y)
        }
        return twice / 2
    }

    private func trace(ring: [SIMD3<Double>], facing: [Bool], closing: Closing,
                       steps: Double) -> [CGPoint] {
        var bearings: [Double] = []
        for index in ring.indices {
            let next = (index + 1) % ring.count
            guard facing[index] != facing[next] else { continue }
            bearings.append(azimuth(of: crossing(ring[index], ring[next])))
        }

        var out: [CGPoint] = []
        out.reserveCapacity(ring.count + 64)

        for index in ring.indices {
            let next = (index + 1) % ring.count
            if facing[index] { out.append(point(ring[index])) }
            guard facing[index] != facing[next] else { continue }

            let crossed = crossing(ring[index], ring[next])
            out.append(point(crossed))
            guard facing[index] else { continue }

            var step = next
            var hidden: [Double] = []
            while !facing[step] {
                hidden.append(azimuth(of: ring[step]))
                step = (step + 1) % ring.count
            }
            let back = azimuth(of: crossing(ring[(step + ring.count - 1) % ring.count],
                                            ring[step]))
            out.append(contentsOf: arc(from: azimuth(of: crossed), to: back,
                                       hidden: hidden, bearings: bearings,
                                       closing: closing, steps: steps))
        }
        return out
    }

    /// Points along the globe's edge from one bearing to another.
    private func arc(from: Double, to: Double, hidden: [Double], bearings: [Double],
                     closing: Closing, steps: Double) -> [CGPoint] {
        func ahead(_ angle: Double) -> Double {
            var value = angle
            while value < 0 { value += 2 * .pi }
            while value >= 2 * .pi { value -= 2 * .pi }
            return value
        }
        let anticlockwiseSweep = ahead(to - from)

        var anticlockwise: Bool
        switch closing {
        case .allAnticlockwise:
            anticlockwise = true
        case .allClockwise:
            anticlockwise = false
        case .emptiest:
            // Do not run through the widest stretch of edge that nothing crosses.
            var marks = hidden.map { ahead($0 - from) }
            marks.append(0)
            marks.append(anticlockwiseSweep)
            marks.sort()
            var widest = 2 * .pi - marks[marks.count - 1] + marks[0]
            var emptyFrom = marks[marks.count - 1]
            for index in 1..<marks.count where marks[index] - marks[index - 1] > widest {
                widest = marks[index] - marks[index - 1]
                emptyFrom = marks[index - 1]
            }
            anticlockwise = !(emptyFrom < anticlockwiseSweep)
        case .fewestCrossings, .fewestCrossingsOtherWay:
            var inside = 0, outside = 0
            for bearing in bearings {
                let along = ahead(bearing - from)
                guard along > 1e-9, along < 2 * .pi - 1e-9,
                      abs(along - anticlockwiseSweep) > 1e-9 else { continue }
                if along < anticlockwiseSweep { inside += 1 } else { outside += 1 }
            }
            anticlockwise = inside == outside
                ? (closing == .fewestCrossingsOtherWay)
                : inside < outside
        }

        let sweep = anticlockwise ? anticlockwiseSweep : anticlockwiseSweep - 2 * .pi
        let count = max(2, Int(abs(sweep) / steps))
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for step in 1..<count {
            points.append(edge(at: from + sweep * Double(step) / Double(count)))
        }
        return points
    }

    /// Whether any of a cap could be on the side of the globe facing us.
    ///
    /// Every point of the cap is at least `radius` short of its centre's angle from
    /// straight-ahead, so the whole thing is behind the horizon once that centre is a right
    /// angle plus the radius away. One dot product, for a shape of any size.
    func couldFace(_ cap: SphericalCap) -> Bool {
        // A cap wider than a right angle covers at least a hemisphere, so it reaches the side
        // facing us wherever its centre happens to be. Worth saying outright: the test below
        // reads the cosine of `radius + 90°`, which stops meaning anything once that passes
        // 180°, and quietly culled Eurasia-sized shapes when it did.
        if cap.cosRadius <= 0 { return true }
        return simd_dot(cap.centre, forward) > -cap.sinRadius
    }

    /// Where a cap lands on the sheet, and how wide, for culling against the panel.
    ///
    /// Conservative: an arc of `radius` projects to `sin(radius)` of the globe's own radius,
    /// never more, so a circle that size around the cap's centre holds all of it.
    func bounds(of cap: SphericalCap) -> CGRect {
        // A cap reaching round the far side has no honest extent on the sheet — its centre
        // projects to a place it is not. Say "everywhere" and let the clip sort it out.
        guard cap.cosRadius > 0, faces(cap.centre) else { return .infinite }
        let across = CGFloat(cap.sinRadius * radius)
        let at = point(cap.centre)
        return CGRect(x: at.x - across, y: at.y - across,
                      width: across * 2, height: across * 2)
    }
}

/// Whether a ring is wound clockwise, which everything above depends on.
///
/// Measured in degrees rather than on the sphere, and so only meaningful for a ring that does
/// not straddle the antimeridian — which is all this is for: a check that the tables still
/// have the winding the drawing assumes. Every one of the 75,218 rings shipped had it when
/// this was written, and a rebuild that quietly reversed them would otherwise paint the ocean
/// as land and the land as ocean.
func ringRunsClockwise(_ ring: [Coordinate]) -> Bool? {
    guard ring.count > 3 else { return nil }
    let longitudes = ring.map(\.longitude)
    guard let west = longitudes.min(), let east = longitudes.max(), east - west <= 180 else {
        return nil
    }
    var twice = 0.0
    for index in ring.indices {
        let here = ring[index], next = ring[(index + 1) % ring.count]
        twice += here.longitude * next.latitude - next.longitude * here.latitude
    }
    return twice < 0
}
