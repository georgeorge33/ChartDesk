import CoreGraphics
import Foundation
import simd

/// A point on the globe, in degrees.
struct Coordinate: Equatable {
    var latitude: Double
    var longitude: Double
}

/// An airport the map can draw, from the bundled table.
struct MapAirport: Identifiable, Equatable {
    let icao: String
    let coordinate: Coordinate
    let name: String
    let town: String
    let country: String

    var id: String { icao }

    /// "Boston Logan International Airport, Boston" — what the map labels a hovered field with.
    var subtitle: String {
        town.isEmpty ? name : "\(name), \(town)"
    }
}

/// A runway, as its two ends — the last thing left to draw once you are closer in than a
/// coastline can tell you anything.
struct MapRunway {
    let airport: String
    let ident: String
    let low: Coordinate
    let high: Coordinate
    let widthFeet: Int
    /// So a runway on the other side of the world costs one dot product.
    let cap: SphericalCap
}

/// One drawn feature — a ring of land, a lake, a stretch of border.
///
/// Held as unit vectors rather than as degrees, worked out once at load. The globe needs the
/// direction of every point, and four trigonometric calls per point is not a thing to do
/// sixty times a second: this way putting a point on the sheet is two dot products.
///
/// The cap is the smallest cap of the sphere holding the shape, so a feature on the far side
/// costs one dot product instead of a path. It is what a bounding box was for Mercator — a box
/// of longitudes and latitudes says nothing useful on a globe, since near a pole it wraps the
/// whole world, and it cannot answer the one question worth asking, which is whether any of
/// this is turned towards us.
struct MapShape {
    let directions: [SIMD3<Double>]
    let cap: SphericalCap
}

// MARK: - Detail

/// How closely the map is drawn, and so which of the three bundled worlds it draws.
///
/// A coastline is only ever right for one scale. Natural Earth publishes the same world at
/// 1:110m, 1:50m and 1:10m, each generalised for the scale it is meant to be seen at, and the
/// map picks between them by zoom: at a whole-world view the 1:50m rings carry ten times the
/// points the screen has pixels, and zoomed in on the Aegean they carry too few.
enum MapDetail: Int, CaseIterable, Comparable, CustomStringConvertible {
    case coarse = 0
    case medium = 1
    case fine = 2

    /// The Natural Earth scale this tier comes from, which is also its file suffix.
    var scale: String { ["110", "50", "10"][rawValue] }

    /// "1:50m", for the readout — so which tier you are on is something you can see.
    var description: String { "1:\(scale)m" }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Where each tier takes over, as how many points wide the whole world is drawn.
    ///
    /// Keyed off the zoom alone rather than off how many degrees the panel shows, because what
    /// decides which generalisation is right is ground distance per point, and that does not
    /// change when you widen the window. On a 900pt panel these land at about 135° across and
    /// 27° across: roughly a hemisphere, and roughly a country.
    static let mediumFrom: CGFloat = 2_400
    static let fineFrom: CGFloat = 12_000
    /// Runways start to be longer than a few points at about 2.5° across.
    static let runwaysFrom: CGFloat = 120_000
    /// And below about 5° across, the full OpenStreetMap coastline takes over from the
    /// simplified one — where it is on hand. Not sooner: at a wider view it would mean reading
    /// hundreds of one-degree cells to draw a coast the simplified table already draws well.
    static let fullFrom: CGFloat = 65_000

    static func matching(worldWidth: CGFloat) -> MapDetail {
        if worldWidth >= fineFrom { return .fine }
        if worldWidth >= mediumFrom { return .medium }
        return .coarse
    }
}

/// One tier's three layers, drawn together or not at all — a 1:10m coast beside a 1:50m
/// border puts the frontier in the sea.
struct Geography {
    let detail: MapDetail
    let land: [MapShape]
    let lakes: [MapShape]
    let borders: [MapShape]
}

// MARK: - The tables

/// The geography, airport positions and runways the map draws, all bundled.
///
/// Built by `Tools/make_mapdata.py` from public-domain sources: Natural Earth for the land,
/// lakes and borders at three scales, OurAirports for the fields and the runways. Bundled
/// rather than fetched because the rest of the app works with the network off, and a map that
/// needed tiles would be the first thing to stop doing that.
///
/// Three layers per tier because each is drawn differently: land filled, lakes filled back in
/// with the sea's colour so a coast reads as a coast, and borders stroked. Borders are only the
/// arcs two countries share, so no line is drawn twice and no coastline is mistaken for one.
enum WorldData {

    /// Airports by ident, for looking up what a flight plan names. Small, and wanted whatever
    /// the zoom, so this one is not deferred.
    static let airports: [String: MapAirport] = loadAirports()

    /// The nearest airport to a point, within so many metres, or nothing.
    ///
    /// Walked rather than indexed: there are 11,362 of them and this is asked once when the
    /// camera stops, not once a frame.
    static func nearestAirport(to where_: Coordinate, within metres: Double) -> MapAirport? {
        let from = where_.direction
        let cosLimit = cos(metres / 6_371_000)
        var best: MapAirport?
        var bestDot = cosLimit
        for airport in airports.values {
            let dot = simd_dot(from, airport.coordinate.direction)
            if dot > bestDot { bestDot = dot; best = airport }
        }
        return best
    }

    static func airport(_ icao: String?) -> MapAirport? {
        guard let icao = icao else { return nil }
        return airports[icao.uppercased()]
    }

    /// Reads one tier off disk. Costs tens of milliseconds for the deepest one, so this is
    /// called from `MapGeography` on a background queue rather than during a draw.
    ///
    /// Only the deepest level's *land* is OpenStreetMap's. Lakes and borders stay Natural
    /// Earth: OpenStreetMap's coastline is the coast and nothing else — its download holds no
    /// lakes and no frontiers — so the alternative to a slightly coarser lake beside a finer
    /// coast is no lake at all.
    nonisolated static func geography(_ detail: MapDetail) -> Geography {
        return Geography(detail: detail,
                         land: shapes(landTable(for: detail)),
                         lakes: shapes("lakes-\(detail.scale)"),
                         borders: shapes("borders-\(detail.scale)"))
    }

    /// Which land table a tier draws from: OpenStreetMap's for the deepest, Natural Earth's
    /// for the two above it, which have no OpenStreetMap equivalent and need none.
    nonisolated static func landTable(for detail: MapDetail) -> String {
        detail == .fine ? Coastline.deepestLandTable : "land-\(detail.scale)"
    }

    // MARK: - Loading

    private static func mapped(_ resource: String) -> Data? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    nonisolated static func shapes(_ resource: String) -> [MapShape] {
        guard let data = mapped(resource) else { return [] }
        return parseShapes(data)
    }

    /// One ring per line, `lon lat lon lat …`.
    ///
    /// Scanned as bytes. The obvious spelling — decode the file, `split` on newlines, split each
    /// line on spaces, `Double(String(field))` — allocates a string per number, and the deepest
    /// tier holds 380,000 of them: it is the difference between a tier that arrives in the gap
    /// between two frames and one you wait for.
    nonisolated static func parseShapes(_ data: Data) -> [MapShape] {
        var shapes: [MapShape] = []

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                defer { start = end + 1 }

                // Comments carry the provenance, and an empty line carries nothing.
                guard end > start, bytes[start] != 0x23 else { continue }

                var directions: [SIMD3<Double>] = []

                // The file is "lon lat lon lat …", the order a projection wants them in. A
                // longitude running past ±180 — which is how the tables cross the
                // antimeridian — names the same direction either way, so a sphere needs no
                // special handling for the seam it does not have.
                var index = start
                while let longitude = number(bytes, &index, end),
                      let latitude = number(bytes, &index, end) {
                    directions.append(Coordinate(latitude: latitude,
                                                 longitude: longitude).direction)
                }
                guard directions.count >= 2 else { continue }

                shapes.append(MapShape(directions: directions, cap: SphericalCap(directions)))
            }
        }
        return shapes
    }

    /// Parses `-73.78` straight out of the bytes, advancing past it. Nil at the end of a line.
    ///
    /// The digits are gathered as an integer and divided once, rather than accumulated a tenth
    /// at a time, so the answer is the same one `Double("…")` would have given.
    @inline(__always)
    /// One number out of the bytes. Shared with the airspace parser, which reads the same
    /// `lon lat lon lat …` tail after its own four fields.
    nonisolated static func number(_ bytes: UnsafeBufferPointer<UInt8>,
                                   _ index: inout Int, _ end: Int) -> Double? {
        while index < end, bytes[index] == 0x20 { index += 1 }   // spaces
        guard index < end else { return nil }

        var negative = false
        if bytes[index] == 0x2D {                                // '-'
            negative = true
            index += 1
        }

        var digits = 0
        var scale = 1.0
        var sawDigit = false
        while index < end, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            digits = digits * 10 + Int(bytes[index] - 0x30)
            index += 1
            sawDigit = true
        }
        if index < end, bytes[index] == 0x2E {                   // '.'
            index += 1
            while index < end, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                digits = digits * 10 + Int(bytes[index] - 0x30)
                scale *= 10
                index += 1
                sawDigit = true
            }
        }
        guard sawDigit else { return nil }

        let value = Double(digits) / scale
        return negative ? -value : value
    }

    /// Runway ends, for the deepest zoom. Read on demand like a tier: 15,000 of them are worth
    /// nothing until you are close enough that a runway is longer than a few points.
    nonisolated static func loadRunways() -> [MapRunway] {
        guard let data = mapped("runway-ends") else { return [] }

        var runways: [MapRunway] = []
        runways.reserveCapacity(15_000)

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                defer { start = end + 1 }
                guard end > start, bytes[start] != 0x23 else { continue }

                // airport, ident, lat, lon, lat, lon, width — tab separated.
                var fields: [Range<Int>] = []
                var field = start
                var cursor = start
                while cursor <= end {
                    if cursor == end || bytes[cursor] == 0x09 {
                        fields.append(field..<cursor)
                        field = cursor + 1
                    }
                    cursor += 1
                }
                guard fields.count >= 7 else { continue }

                var figures: [Double] = []
                for slot in 2..<6 {
                    var at = fields[slot].lowerBound
                    guard let value = number(bytes, &at, fields[slot].upperBound) else { break }
                    figures.append(value)
                }
                guard figures.count == 4 else { continue }

                var widthAt = fields[6].lowerBound
                let width = number(bytes, &widthAt, fields[6].upperBound) ?? 0

                let low = Coordinate(latitude: figures[0], longitude: figures[1])
                let high = Coordinate(latitude: figures[2], longitude: figures[3])
                runways.append(MapRunway(
                    airport: String(decoding: bytes[fields[0]], as: UTF8.self),
                    ident: String(decoding: bytes[fields[1]], as: UTF8.self),
                    low: low, high: high,
                    widthFeet: Int(width),
                    cap: SphericalCap([low.direction, high.direction])))
            }
        }
        return runways
    }

    private static func loadAirports() -> [String: MapAirport] {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }

        var table: [String: MapAirport] = [:]
        table.reserveCapacity(7000)
        for line in text.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6,
                  let latitude = Double(fields[1]),
                  let longitude = Double(fields[2])
            else { continue }
            let icao = String(fields[0])
            table[icao] = MapAirport(icao: icao,
                                     coordinate: Coordinate(latitude: latitude,
                                                            longitude: longitude),
                                     name: String(fields[3]),
                                     town: String(fields[4]),
                                     country: String(fields[5]))
        }
        return table
    }
}

// MARK: - Great circles

enum Spherical {

    /// Directions along the great circle between two coordinates.
    ///
    /// On a globe this is simply what a leg *is* — the shortest way between two places — so
    /// the interpolation is a turn from one direction to the other and nothing to do with any
    /// projection. Under Mercator the same thing had to be worked out and then bent by the
    /// projection, or a London to Los Angeles leg ran straight across the sheet and missed
    /// Greenland by hundreds of miles.
    static func arc(from start: Coordinate, to end: Coordinate,
                    steps: Int = 24) -> [SIMD3<Double>] {
        let first = start.direction, last = end.direction
        let angle = acos(min(max(simd_dot(first, last), -1), 1))

        // Short legs are straight enough that the interpolation is wasted work.
        guard angle > 0.01 else { return [first, last] }

        var out: [SIMD3<Double>] = []
        out.reserveCapacity(steps + 1)
        let spread = sin(angle)
        for step in 0...steps {
            let along = Double(step) / Double(steps)
            let here = sin((1 - along) * angle) / spread
            let there = sin(along * angle) / spread
            out.append(simd_normalize(first * here + last * there))
        }
        return out
    }
}

// MARK: - Camera

/// Where the globe is turned to, and how closely it is drawn.
///
/// A centre and a zoom, as before. What changed is what they mean: the centre is the place
/// turned towards the viewer rather than the middle of a sheet, and dragging turns the sphere
/// instead of sliding a sheet about. Kept as a struct of two numbers because the one thing a
/// map must get right is that zooming leaves what is under the cursor under the cursor, and
/// that is only checkable if the arithmetic can be called without a window.
struct MapCamera: Equatable {

    /// The place on the globe turned towards the viewer.
    var centre = Coordinate(latitude: 25, longitude: -20)

    /// How many points across the whole world would be drawn — the sphere's circumference on
    /// the sheet.
    ///
    /// Held in those terms rather than as the sphere's radius so that "how many degrees does
    /// the view cover" is the same arithmetic it was under Mercator: a panel shows
    /// `width × 360 / worldWidth` degrees either way. Which means the zooms at which each
    /// level of detail takes over did not have to be retuned for the globe.
    var worldWidth: CGFloat = 2_600

    /// How far in and out the map will go, as the sphere's circumference in points.
    ///
    /// The far end is set by the finest thing there is to look at, not by an arbitrary number.
    /// 80,000,000 points round the world is half a metre to the point: OpenStreetMap's
    /// coastline is surveyed to about a metre and the runway ends are given to five decimals,
    /// so at that zoom the map is drawing everything it knows and a staircase would be the
    /// data's own, not the projection's. Closer than that there is nothing further to see.
    ///
    /// The near end is a formality — `smallest(in:)` stops the zoom well before it, at the
    /// point where the whole globe is on the panel and there is nothing more to reveal.
    static let widthRange: ClosedRange<CGFloat> = 900...80_000_000

    /// The sphere's radius on the sheet.
    var radius: Double { Double(worldWidth) / (2 * .pi) }

    /// Which of the bundled worlds is the right one to draw at this zoom.
    var detail: MapDetail { MapDetail.matching(worldWidth: worldWidth) }

    /// True once a runway is long enough on screen to be worth drawing.
    var showsRunways: Bool { worldWidth >= MapDetail.runwaysFrom }

    func projection(in size: CGSize) -> GlobeProjection {
        GlobeProjection(centre: centre, radius: radius, in: size)
    }

    func screen(_ coordinate: Coordinate, in size: CGSize) -> CGPoint {
        projection(in: size).point(coordinate.direction)
    }

    /// What is under a point on the sheet, or nil for a point off the globe.
    func coordinate(at point: CGPoint, in size: CGSize) -> Coordinate? {
        projection(in: size).direction(at: point).map(Coordinate.init)
    }

    /// Degrees across the view, which is what decides when labels have room.
    func degreesAcross(in size: CGSize) -> Double {
        guard size.width > 0, worldWidth > 0 else { return 360 }
        return Double(size.width / worldWidth) * 360
    }

    /// Turns the globe so that a direction lands on a given point of the sheet.
    ///
    /// The one operation both dragging and zooming are made of. North stays up, so the turn is
    /// only exact for a point near the middle of the view — a globe that rolled to follow the
    /// cursor exactly would be a globe you could turn upside down by accident.
    mutating func hold(_ direction: SIMD3<Double>, at point: CGPoint, in size: CGSize) {
        // Not one turn but a few. North stays up, which means the basis is rebuilt after every
        // turn and the place a direction lands moves with it — a single pass leaves the thing
        // you grabbed a good ten points from the cursor when you grabbed it near the edge of
        // the view. Each pass closes most of what is left; four gets inside a tenth of a point,
        // which is finer than a cursor can ask for.
        for _ in 0..<4 {
            guard let now = projection(in: size).direction(at: point),
                  simd_dot(now, direction) > -0.999999  // antipodal: any turn would do
            else { return }

            let turn = simd_quaternion(now, direction)
            centre = Coordinate(simd_normalize(turn.act(centre.direction)))

            let landed = projection(in: size).point(direction)
            guard hypot(landed.x - point.x, landed.y - point.y) >= 0.1 else { return }
        }
    }

    /// How far out it is worth zooming, for a panel of a given size.
    ///
    /// A sheet could be zoomed out for ever and only got emptier. A sphere cannot: past the
    /// point where the whole globe is on the panel there is nothing further to reveal, and
    /// carrying on only shrinks the world to a marble in a dark room.
    static func smallest(in size: CGSize) -> CGFloat {
        let fills = CGFloat(Double(min(size.width, size.height)) * .pi)
        return max(widthRange.lowerBound, fills * 0.6)
    }

    /// Zooms, keeping whatever is under `point` under it.
    mutating func zoom(by factor: CGFloat, around point: CGPoint?, in size: CGSize) {
        let floor = size.width > 0 ? Self.smallest(in: size) : Self.widthRange.lowerBound
        let next = min(max(worldWidth * factor, floor), Self.widthRange.upperBound)
        guard let point = point, size.width > 0, next != worldWidth,
              let before = projection(in: size).direction(at: point)
        else {
            worldWidth = next
            return
        }
        worldWidth = next
        hold(before, at: point, in: size)
    }

    /// Turns by a drag, measured from where the drag began, so a drag is absolute rather than
    /// a running sum. Whatever was grabbed stays under the finger.
    mutating func turn(from start: MapCamera, grabbing grabbed: CGPoint,
                       to moved: CGPoint, in size: CGSize) {
        self = start
        guard let held = start.projection(in: size).direction(at: grabbed) else { return }
        hold(held, at: moved, in: size)
    }

    /// Frames a set of coordinates with a little of the view as margin, so the end points are
    /// not sitting on the frame.
    mutating func fit(_ coordinates: [Coordinate], in size: CGSize) {
        guard size.width > 40, size.height > 40, !coordinates.isEmpty else { return }

        let cap = SphericalCap(coordinates.map(\.direction))
        centre = Coordinate(cap.centre)

        guard coordinates.count > 1 else {
            worldWidth = max(size.width * 40, 12_000)
            return
        }

        // A place `radius` round the globe is drawn `sin(radius)` of the way out from the
        // middle, so that is what has to fit inside the panel.
        let out = max(cap.sinRadius, 0.02)
        let wanted = Double(min(size.width, size.height)) * 0.4 / out * 2 * .pi
        worldWidth = min(max(CGFloat(wanted), Self.widthRange.lowerBound),
                         Self.widthRange.upperBound)
    }
}
