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

    /// The visible part of a closed ring, as points on the sheet.
    ///
    /// Sutherland-Hodgman cannot do this. Its clip regions are half-planes, and the region
    /// here is a hemisphere whose boundary, on the sheet, is a circle — so where a ring leaves
    /// the globe and comes back, the two ends have to be joined by an *arc* of that circle
    /// rather than the straight line a half-plane clip would leave. A straight line there
    /// draws a chord across the face of the globe, which is a continent with a slice cut off.
    ///
    /// Which way round the arc goes is the whole difficulty, and it cannot be answered by
    /// taking the shorter one: the land is sometimes the larger part. It is answered by the
    /// hidden stretch of the ring itself. Those points are on the far side, but they still
    /// have an azimuth — a bearing round the edge — and the arc that replaces them is the one
    /// sweeping through those bearings.
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

        // Wholly in view: nothing to close.
        if !anyHidden {
            return ring.map(point)
        }
        // Wholly out of view — unless it is so large that the globe's whole face is inside it,
        // in which case what you can see of it is all of it.
        if !anyFacing {
            return encloses(ring: ring) ? wholeFace(steps: steps) : []
        }

        var out: [CGPoint] = []
        out.reserveCapacity(ring.count + 32)

        for index in ring.indices {
            let next = (index + 1) % ring.count
            let here = ring[index], there = ring[next]

            if facing[index] { out.append(point(here)) }

            guard facing[index] != facing[next] else { continue }

            if facing[index] {
                // Leaving. Walk the edge round to wherever it comes back, sweeping through
                // the bearings of the stretch that is hidden.
                let leaves = crossing(here, there)
                out.append(point(leaves))

                var step = next
                var through: [Double] = []
                while !facing[step] {
                    through.append(azimuth(of: ring[step]))
                    step = (step + 1) % ring.count
                }
                let returns = crossing(ring[(step + ring.count - 1) % ring.count], ring[step])
                out.append(contentsOf: arc(from: azimuth(of: leaves),
                                           to: azimuth(of: returns),
                                           through: through,
                                           steps: steps))
            } else {
                // Coming back. The crossing itself; the arc that got here was already drawn.
                out.append(point(crossing(here, there)))
            }
        }
        return out
    }

    /// Points along the globe's edge from one bearing to another, going the way that passes
    /// through the bearings of the hidden stretch.
    private func arc(from: Double, to: Double, through: [Double], steps: Double) -> [CGPoint] {
        // Both distances measured the same way round — anticlockwise, in 0..<2π. Mixing a
        // signed shortest sweep with an unsigned anticlockwise one is what once sent a ring
        // the long way round and traced the whole edge of the globe as coastline.
        func anticlockwise(_ angle: Double) -> Double {
            var value = angle
            while value < 0 { value += 2 * .pi }
            while value >= 2 * .pi { value -= 2 * .pi }
            return value
        }

        let round = anticlockwise(to - from)
        var sweep = round

        if through.isEmpty {
            // A crossing with nothing hidden between it and the next, which happens where a
            // ring grazes the edge. Nothing to go on, so take the shorter way.
            if round > .pi { sweep = round - 2 * .pi }
        } else {
            // Which way round is settled by where round the edge there is *nothing*.
            //
            // Asking instead where the middle of the hidden stretch lies cannot answer it for
            // a shape that merely grazes the edge: a small island half over the horizon has
            // every bearing all but equal, and the comparison comes down to which way the
            // rounding fell. Three of them came out drawn as coastline all the way round the
            // globe. The widest empty stretch is a robust thing to find, whatever the scale of
            // the shape, and the land is on the other side of it.
            var marks = through.map { anticlockwise($0 - from) }
            marks.append(0)          // where this arc starts
            marks.append(round)      // and where it has to end
            marks.sort()

            var widest = 2 * .pi - marks[marks.count - 1] + marks[0]
            var emptyFrom = marks[marks.count - 1]
            for index in 1..<marks.count {
                let gap = marks[index] - marks[index - 1]
                if gap > widest {
                    widest = gap
                    emptyFrom = marks[index - 1]
                }
            }

            // Going anticlockwise would run through the empty stretch, so the land went the
            // other way about.
            if emptyFrom < round { sweep = round - 2 * .pi }
        }

        let count = max(2, Int(abs(sweep) / steps))
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for step in 1..<count {
            points.append(edge(at: from + sweep * Double(step) / Double(count)))
        }
        return points
    }

    /// The globe's whole face, for a shape that swallows it.
    private func wholeFace(steps: Double) -> [CGPoint] {
        let count = max(24, Int(2 * .pi / steps))
        return (0..<count).map { edge(at: 2 * .pi * Double($0) / Double(count)) }
    }

    /// Whether a ring holds the point the globe is centred on.
    ///
    /// By winding: the bearings of the ring's points, walked round, come back having gone once
    /// round the circle when the centre is inside it.
    ///
    /// The *sign* of that is the whole answer, and taking the size of it instead says that
    /// Antarctica contains Europe. A closed curve on a sphere has two sides and no inherent
    /// inside, so a coast that separates the poles winds once about either of them: +2π about
    /// the one it encloses and −2π about the one it does not. Which way round a ring is drawn
    /// is what settles it, and Natural Earth gives outlines anticlockwise, as GeoJSON requires.
    ///
    /// Only asked of a ring with no point in view at all, which is a landmass wider than the
    /// hemisphere you are looking at and otherwise indistinguishable from one somewhere else.
    private func encloses(ring: [SIMD3<Double>]) -> Bool {
        var total = 0.0
        var previous = azimuth(of: ring[ring.count - 1])
        for direction in ring {
            let here = azimuth(of: direction)
            var step = here - previous
            while step <= -.pi { step += 2 * .pi }
            while step > .pi { step -= 2 * .pi }
            total += step
            previous = here
        }
        return total > .pi
    }
}

extension GlobeProjection {

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
