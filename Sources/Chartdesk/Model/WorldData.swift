import Foundation

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
    /// In the projection's 0…1 space, so an off-screen runway costs a rectangle comparison.
    let bounds: CGRect
}

/// A box of longitudes and latitudes.
///
/// Mercator is linear in longitude and monotonic in latitude, so this and a projected `CGRect`
/// describe the very same rectangle — one in degrees, which is what clipping a ring compares
/// against, and one projected, which is what culling one compares against.
struct CoordinateBox {
    var west: Double
    var east: Double
    var south: Double
    var north: Double

    /// True when this box holds all of `other` — so a ring that need not be clipped at all.
    func holds(_ other: CoordinateBox) -> Bool {
        west <= other.west && east >= other.east
            && south <= other.south && north >= other.north
    }
}

/// One drawn feature — a ring of land, a lake, a stretch of border — with its extent.
///
/// The extent is worked out once at load, so a feature that is off screen costs a rectangle
/// comparison instead of a path. With a thousand rings on the sheet that is the difference
/// between a map that drags and one that stutters.
struct MapShape {
    let points: [Coordinate]
    /// Projected, in 0…1, for culling against what the view covers.
    let bounds: CGRect
    /// The same extent in degrees, for deciding which edges of the view a ring crosses.
    let box: CoordinateBox
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

    static func airport(_ icao: String?) -> MapAirport? {
        guard let icao = icao else { return nil }
        return airports[icao.uppercased()]
    }

    /// Reads one tier off disk. Costs tens of milliseconds for the deepest one, so this is
    /// called from `MapGeography` on a background queue rather than during a draw.
    nonisolated static func geography(_ detail: MapDetail) -> Geography {
        Geography(detail: detail,
                  land: shapes("land-\(detail.scale)"),
                  lakes: shapes("lakes-\(detail.scale)"),
                  borders: shapes("borders-\(detail.scale)"))
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

                var points: [Coordinate] = []
                var minLongitude = Double.infinity, maxLongitude = -Double.infinity
                var minLatitude = Double.infinity, maxLatitude = -Double.infinity

                // The file is "lon lat lon lat …", the order a projection wants them in.
                // Longitudes may run past ±180 where a ring crosses the antimeridian.
                var index = start
                while let longitude = number(bytes, &index, end),
                      let latitude = number(bytes, &index, end) {
                    points.append(Coordinate(latitude: latitude, longitude: longitude))
                    minLongitude = min(minLongitude, longitude)
                    maxLongitude = max(maxLongitude, longitude)
                    minLatitude = min(minLatitude, latitude)
                    maxLatitude = max(maxLatitude, latitude)
                }
                guard points.count >= 2 else { continue }

                shapes.append(MapShape(points: points,
                                       bounds: projected(minLongitude: minLongitude,
                                                         maxLongitude: maxLongitude,
                                                         minLatitude: minLatitude,
                                                         maxLatitude: maxLatitude),
                                       box: CoordinateBox(west: minLongitude,
                                                          east: maxLongitude,
                                                          south: minLatitude,
                                                          north: maxLatitude)))
            }
        }
        return shapes
    }

    /// The projected extent of a lon/lat box, from its corners alone.
    ///
    /// Mercator is linear in longitude and monotonic in latitude, so the extreme coordinates
    /// project to the extreme points: two projections per ring rather than one per point, which
    /// across the deepest tier saves 380,000 logarithms.
    nonisolated private static func projected(minLongitude: Double, maxLongitude: Double,
                                              minLatitude: Double, maxLatitude: Double) -> CGRect {
        let topLeft = Mercator.point(Coordinate(latitude: maxLatitude, longitude: minLongitude))
        let bottomRight = Mercator.point(Coordinate(latitude: minLatitude,
                                                    longitude: maxLongitude))
        return CGRect(x: topLeft.x, y: topLeft.y,
                      width: max(bottomRight.x - topLeft.x, 0.0000001),
                      height: max(bottomRight.y - topLeft.y, 0.0000001))
    }

    /// Parses `-73.78` straight out of the bytes, advancing past it. Nil at the end of a line.
    ///
    /// The digits are gathered as an integer and divided once, rather than accumulated a tenth
    /// at a time, so the answer is the same one `Double("…")` would have given.
    @inline(__always)
    nonisolated private static func number(_ bytes: UnsafeBufferPointer<UInt8>,
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
                    bounds: projected(minLongitude: min(low.longitude, high.longitude),
                                      maxLongitude: max(low.longitude, high.longitude),
                                      minLatitude: min(low.latitude, high.latitude),
                                      maxLatitude: max(low.latitude, high.latitude))))
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

// MARK: - Projection

/// Web Mercator, the projection every slippy map uses.
///
/// Both axes come back in 0…1 for the whole world, so "zoom" is simply how many points wide
/// the world is drawn: the camera holds that one number and a centre, and everything else is
/// multiplication. Latitude is clamped short of the poles, where Mercator runs to infinity.
enum Mercator {

    static let limit = 85.05112878

    static func point(_ coordinate: Coordinate) -> CGPoint {
        let latitude = min(max(coordinate.latitude, -limit), limit)
        let x = (coordinate.longitude + 180) / 360
        let radians = latitude * .pi / 180
        let y = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2
        return CGPoint(x: x, y: y)
    }

    static func coordinate(_ point: CGPoint) -> Coordinate {
        // Wrapped, because x runs past 0…1 as the map is dragged round the world and a centre
        // reported as 206°W is nonsense even when the arithmetic behind it is sound.
        var longitude = (point.x * 360 - 180).truncatingRemainder(dividingBy: 360)
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        let n = .pi * (1 - 2 * point.y)
        let latitude = atan(sinh(n)) * 180 / .pi
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// The latitude drawn at a projected y — the inverse of the y above, on its own, for
    /// turning a visible rectangle back into the band of latitudes it covers.
    static func latitude(atY y: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
    }

    /// Points along the great circle between two coordinates.
    ///
    /// Straight lines in Mercator are rhumb lines, not the shortest path, and an ocean crossing
    /// drawn that way is visibly wrong — a London to Los Angeles leg would miss Greenland by
    /// hundreds of miles. Interpolating the great circle and letting the projection bend it is
    /// what makes long legs look like the route the aircraft flies.
    static func arc(from start: Coordinate, to end: Coordinate, steps: Int = 24) -> [Coordinate] {
        let φ1 = start.latitude * .pi / 180, λ1 = start.longitude * .pi / 180
        let φ2 = end.latitude * .pi / 180, λ2 = end.longitude * .pi / 180

        let deltaφ = φ2 - φ1, deltaλ = λ2 - λ1
        let a = sin(deltaφ / 2) * sin(deltaφ / 2)
            + cos(φ1) * cos(φ2) * sin(deltaλ / 2) * sin(deltaλ / 2)
        let angle = 2 * asin(min(1, sqrt(a)))

        // Short legs are straight enough that the interpolation is wasted work.
        guard angle > 0.01 else { return [start, end] }

        var points: [Coordinate] = []
        points.reserveCapacity(steps + 1)
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let A = sin((1 - fraction) * angle) / sin(angle)
            let B = sin(fraction * angle) / sin(angle)
            let x = A * cos(φ1) * cos(λ1) + B * cos(φ2) * cos(λ2)
            let y = A * cos(φ1) * sin(λ1) + B * cos(φ2) * sin(λ2)
            let z = A * sin(φ1) + B * sin(φ2)
            points.append(Coordinate(latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
                                     longitude: atan2(y, x) * 180 / .pi))
        }
        return points
    }
}

// MARK: - Camera

/// Where the map is looking, and how closely.
///
/// A struct of two numbers rather than state scattered through the view, because the one thing
/// a map must get right is that zooming keeps the point under the cursor under the cursor, and
/// that is only checkable if the arithmetic can be called without a window.
struct MapCamera: Equatable {

    /// The coordinate drawn at the middle of the view.
    var centre = Coordinate(latitude: 25, longitude: -20)
    /// How many points wide the whole world would be at this zoom.
    var worldWidth: CGFloat = 900

    static let widthRange: ClosedRange<CGFloat> = 320...4_000_000

    /// Which of the bundled worlds is the right one to draw at this zoom.
    var detail: MapDetail { MapDetail.matching(worldWidth: worldWidth) }

    /// True once a runway is long enough on screen to be worth drawing.
    var showsRunways: Bool { worldWidth >= MapDetail.runwaysFrom }

    func screen(_ coordinate: Coordinate, in size: CGSize) -> CGPoint {
        let point = Mercator.point(coordinate)
        let anchor = Mercator.point(centre)
        return CGPoint(x: size.width / 2 + (point.x - anchor.x) * worldWidth,
                       y: size.height / 2 + (point.y - anchor.y) * worldWidth)
    }

    func coordinate(at point: CGPoint, in size: CGSize) -> Coordinate {
        let anchor = Mercator.point(centre)
        return Mercator.coordinate(CGPoint(x: anchor.x + (point.x - size.width / 2) / worldWidth,
                                           y: anchor.y + (point.y - size.height / 2) / worldWidth))
    }

    /// What the view covers, in the projection's 0…1 space. A shape whose bounds miss this
    /// rectangle need not be drawn.
    func visibleRect(in size: CGSize) -> CGRect {
        let anchor = Mercator.point(centre)
        let halfWidth = size.width / 2 / worldWidth
        let halfHeight = size.height / 2 / worldWidth
        return CGRect(x: anchor.x - halfWidth, y: anchor.y - halfHeight,
                      width: halfWidth * 2, height: halfHeight * 2)
    }

    /// Degrees of longitude across the view, which is what decides when labels have room.
    func degreesAcross(in size: CGSize) -> Double {
        guard size.width > 0, worldWidth > 0 else { return 360 }
        return Double(size.width / worldWidth) * 360
    }

    /// Zooms, keeping `point` looking at the same place on the ground.
    mutating func zoom(by factor: CGFloat, around point: CGPoint?, in size: CGSize) {
        let next = min(max(worldWidth * factor, Self.widthRange.lowerBound),
                       Self.widthRange.upperBound)
        guard let point = point, size.width > 0, next != worldWidth else {
            worldWidth = next
            return
        }

        let anchor = Mercator.point(centre)
        let offset = CGPoint(x: (point.x - size.width / 2) / worldWidth,
                             y: (point.y - size.height / 2) / worldWidth)
        let target = CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y)

        worldWidth = next
        let scaled = CGPoint(x: (point.x - size.width / 2) / worldWidth,
                             y: (point.y - size.height / 2) / worldWidth)
        centre = Mercator.coordinate(CGPoint(x: target.x - scaled.x,
                                             y: min(max(target.y - scaled.y, 0), 1)))
    }

    /// Pans by a drag, measured from where the drag started.
    mutating func pan(from start: MapCamera, by translation: CGSize) {
        let anchor = Mercator.point(start.centre)
        let moved = CGPoint(x: anchor.x - translation.width / start.worldWidth,
                            y: anchor.y - translation.height / start.worldWidth)
        centre = Mercator.coordinate(CGPoint(x: moved.x, y: min(max(moved.y, 0), 1)))
        worldWidth = start.worldWidth
    }

    /// Frames a set of coordinates with a tenth of the view as margin, so the end points are
    /// not sitting on the frame.
    mutating func fit(_ coordinates: [Coordinate], in size: CGSize) {
        guard size.width > 40, size.height > 40 else { return }
        guard coordinates.count > 1 else {
            if let only = coordinates.first {
                centre = only
                worldWidth = max(size.width * 40, 12_000)
            }
            return
        }

        let projected = coordinates.map(Mercator.point)
        let minX = projected.map(\.x).min() ?? 0, maxX = projected.map(\.x).max() ?? 1
        let minY = projected.map(\.y).min() ?? 0, maxY = projected.map(\.y).max() ?? 1
        let spanX = max(maxX - minX, 0.000002)
        let spanY = max(maxY - minY, 0.000002)

        worldWidth = min(min(size.width * 0.8 / spanX, size.height * 0.8 / spanY),
                         Self.widthRange.upperBound)
        centre = Mercator.coordinate(CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2))
    }
}
