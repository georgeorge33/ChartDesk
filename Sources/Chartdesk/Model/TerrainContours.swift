import Foundation
import simd

/// One line of constant height, taken off a terrain tile.
struct TerrainContour {
    let metres: Double
    let directions: [SIMD3<Double>]
    let cap: SphericalCap
    /// Every fifth line, drawn heavier. What lets you count contours at a glance instead of
    /// reading a figure off each one.
    let isIndex: Bool
}

/// Contour lines, found in a tile of heights.
///
/// The reason to bother, when the tile is already being painted: a painted tile is pixels,
/// and pixels run out. Zoom past the deepest zoom the terrain tiles go to and the shading
/// turns to porridge, because there is nothing left to magnify. A contour is a line — it is
/// the same line at any size, and it projects onto the globe with everything else the app
/// draws rather than having to be warped into place.
///
/// So the tile gives both halves of a paper chart: the hillshade underneath, which is the
/// shape, and the lines over it, which are the numbers.
enum TerrainContours {

    /// How far apart the lines are, by how close in the tile is.
    ///
    /// Not a fixed interval, because one loose enough for the Alps has nothing to say about
    /// Vermont, and one tight enough for Vermont is a solid brown wash over the Alps. These
    /// are the figures a paper chart uses at roughly the same scales.
    static func interval(forZoom z: Int) -> Double {
        switch z {
        case ..<9: return 500
        case 9...11: return 250
        case 12...13: return 100
        default: return 50
        }
    }

    /// Where a contour is drawn heavier: every fifth one, as a chart does it.
    static func isIndex(_ metres: Double, interval: Double) -> Bool {
        let fifth = interval * 5
        return abs(metres.truncatingRemainder(dividingBy: fifth)) < 0.5
    }

    /// The lines on one tile.
    ///
    /// Marching squares. Every square of four neighbouring heights is looked at on its own:
    /// the contour either crosses it or does not, and which of its four edges the crossing
    /// enters and leaves by follows from which corners are above the level. The crossings on
    /// an edge are then chained into lines, because a thousand loose two-point segments
    /// cannot be simplified, cannot be drawn as one stroke, and cannot carry a label.
    static func find(in heights: [Double], side: Int, tile: MapTile,
                     interval: Double) -> [TerrainContour] {
        guard side > 1, heights.count == side * side else { return [] }
        var lowest = Double.greatestFiniteMagnitude, highest = -Double.greatestFiniteMagnitude
        for h in heights {
            lowest = min(lowest, h)
            highest = max(highest, h)
        }
        guard highest > lowest else { return [] }

        var found: [TerrainContour] = []
        var level = (lowest / interval).rounded(.down) * interval
        while level <= highest {
            defer { level += interval }
            // Sea level is the coastline, and the terrain fill already draws that edge.
            guard level > 0, level > lowest, level < highest else { continue }
            for line in chains(in: heights, side: side, level: level) {
                let thinned = simplified(line, tolerance: 0.35)
                guard thinned.count >= 2 else { continue }
                let directions = thinned.map { point in
                    place(point, in: tile, side: side).direction
                }
                found.append(TerrainContour(metres: level, directions: directions,
                                            cap: SphericalCap(directions),
                                            isIndex: isIndex(level, interval: interval)))
            }
        }
        return found
    }

    // MARK: - Marching squares

    /// An edge of the grid, numbered so that the two squares either side of it agree.
    ///
    /// This is the whole trick to chaining: a crossing belongs to an *edge*, not to a
    /// square, so the square on each side finds the same crossing under the same number and
    /// the two halves of the line join without comparing any coordinates.
    private static func edge(_ x: Int, _ y: Int, _ down: Bool, _ side: Int) -> Int {
        ((y * side) + x) * 2 + (down ? 1 : 0)
    }

    private static func chains(in heights: [Double], side: Int,
                               level: Double) -> [[SIMD2<Double>]] {
        var place: [Int: SIMD2<Double>] = [:]
        var links: [Int: [Int]] = [:]

        func crossingAcross(_ x: Int, _ y: Int) -> Int {          // between (x,y) and (x+1,y)
            let key = edge(x, y, false, side)
            if place[key] == nil {
                let a = heights[y * side + x], b = heights[y * side + x + 1]
                let t = (level - a) / (b - a)
                place[key] = SIMD2(Double(x) + t, Double(y))
            }
            return key
        }
        func crossingDown(_ x: Int, _ y: Int) -> Int {            // between (x,y) and (x,y+1)
            let key = edge(x, y, true, side)
            if place[key] == nil {
                let a = heights[y * side + x], b = heights[(y + 1) * side + x]
                let t = (level - a) / (b - a)
                place[key] = SIMD2(Double(x), Double(y) + t)
            }
            return key
        }
        func join(_ one: Int, _ other: Int) {
            links[one, default: []].append(other)
            links[other, default: []].append(one)
        }

        for y in 0..<(side - 1) {
            for x in 0..<(side - 1) {
                let a = heights[y * side + x] > level            // top left
                let b = heights[y * side + x + 1] > level        // top right
                let c = heights[(y + 1) * side + x + 1] > level  // bottom right
                let d = heights[(y + 1) * side + x] > level      // bottom left
                let kind = (a ? 8 : 0) | (b ? 4 : 0) | (c ? 2 : 0) | (d ? 1 : 0)
                guard kind != 0, kind != 15 else { continue }

                let top = { crossingAcross(x, y) }
                let bottom = { crossingAcross(x, y + 1) }
                let left = { crossingDown(x, y) }
                let right = { crossingDown(x + 1, y) }

                switch kind {
                case 1, 14: join(left(), bottom())
                case 2, 13: join(bottom(), right())
                case 3, 12: join(left(), right())
                case 4, 11: join(top(), right())
                case 6, 9:  join(top(), bottom())
                case 7, 8:  join(left(), top())
                default:
                    // The two saddles, where the square holds two separate lines and which
                    // pair up is genuinely ambiguous. The middle of the square decides it,
                    // which is what keeps a ridge from being drawn as two hollows.
                    let middle = (heights[y * side + x] + heights[y * side + x + 1]
                                + heights[(y + 1) * side + x] + heights[(y + 1) * side + x + 1]) / 4
                    let high = middle > level
                    if (kind == 5) == high {
                        join(top(), right()); join(left(), bottom())
                    } else {
                        join(left(), top()); join(bottom(), right())
                    }
                }
            }
        }

        // Walk what was joined. Open lines first, from their loose ends, so a line that runs
        // off the tile is not started somewhere in its middle and left in two pieces.
        var walked = Set<Int>()
        var lines: [[SIMD2<Double>]] = []

        func walk(from start: Int) {
            var line: [SIMD2<Double>] = []
            var here = start
            var previous = -1
            while !walked.contains(here) {
                walked.insert(here)
                if let at = place[here] { line.append(at) }
                let next = (links[here] ?? []).first { $0 != previous && !walked.contains($0) }
                guard let onward = next else { break }
                previous = here
                here = onward
            }
            if line.count >= 2 { lines.append(line) }
        }

        for (key, joined) in links where joined.count == 1 { walk(from: key) }
        for key in links.keys { walk(from: key) }
        return lines
    }

    // MARK: - Thinning

    /// Douglas-Peucker, in the tile's own pixels.
    ///
    /// Marching squares puts a point on every edge it crosses, which down a straight slope
    /// is a point every pixel and says nothing. Measured over the Alps this leaves about a
    /// fifth of them, and the line is the same line.
    static func simplified(_ points: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var spans = [(0, points.count - 1)]

        while let (from, to) = spans.popLast() {
            guard to > from + 1 else { continue }
            let start = points[from], end = points[to]
            let along = end - start
            let length = simd_length(along)
            var worst = 0.0, at = from

            for index in (from + 1)..<to {
                let offset = points[index] - start
                let away = length > 1e-12
                    ? abs(offset.x * along.y - offset.y * along.x) / length
                    : simd_length(offset)
                if away > worst { worst = away; at = index }
            }
            guard worst > tolerance else { continue }
            keep[at] = true
            spans.append((from, at))
            spans.append((at, to))
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    // MARK: - Onto the globe

    /// Where a point in a tile's pixels falls on the earth.
    ///
    /// The slippy-map formula run backwards. A tile is a square of Mercator, so across it
    /// longitude is linear and latitude is not.
    static func place(_ point: SIMD2<Double>, in tile: MapTile, side: Int) -> Coordinate {
        let across = Double(1 << tile.z)
        let worldX = (Double(tile.x) + point.x / Double(side)) / across
        let worldY = (Double(tile.y) + point.y / Double(side)) / across
        return Coordinate(latitude: atan(sinh(.pi * (1 - 2 * worldY))) * 180 / .pi,
                          longitude: worldX * 360 - 180)
    }
}
