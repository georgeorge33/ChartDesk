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

/// One drawn feature — a ring of land, a lake, a stretch of border — with its extent.
///
/// The extent is in the projection's own 0…1 space and is worked out once at load, so a
/// feature that is off screen costs a rectangle comparison instead of a path. With a thousand
/// rings on the sheet that is the difference between a map that drags and one that stutters.
struct MapShape {
    let points: [Coordinate]
    let bounds: CGRect
}

/// The geography and airport positions the map draws, all bundled.
///
/// Built by `Tools/make_mapdata.py` from public-domain sources: Natural Earth at 1:50m for the
/// land, lakes and borders, OurAirports for the fields. Bundled rather than fetched because the
/// rest of the app works with the network off, and a map that needed tiles would be the first
/// thing to stop doing that.
///
/// Three layers because each is drawn differently: land filled, lakes filled back in with the
/// sea's colour so a coast reads as a coast, and borders stroked. Borders are only the arcs two
/// countries share, so no line is drawn twice and no coastline is mistaken for a frontier.
enum WorldData {

    static let land: [MapShape] = load("land")
    static let lakes: [MapShape] = load("lakes")
    static let borders: [MapShape] = load("borders")

    /// Airports by ident, for looking up what a flight plan names.
    static let airports: [String: MapAirport] = loadAirports()

    static func airport(_ icao: String?) -> MapAirport? {
        guard let icao = icao else { return nil }
        return airports[icao.uppercased()]
    }

    // MARK: - Loading

    private static func load(_ resource: String) -> [MapShape] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        var shapes: [MapShape] = []
        for line in text.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let numbers = line.split(separator: " ").compactMap { Double($0) }
            guard numbers.count >= 4 else { continue }

            var points: [Coordinate] = []
            points.reserveCapacity(numbers.count / 2)
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity

            // The file is "lon lat lon lat …", the order a projection wants them in.
            // Longitudes may run past ±180 where a ring crosses the antimeridian.
            for index in stride(from: 0, to: numbers.count - 1, by: 2) {
                let coordinate = Coordinate(latitude: numbers[index + 1], longitude: numbers[index])
                points.append(coordinate)
                let projected = Mercator.point(coordinate)
                minX = min(minX, projected.x); maxX = max(maxX, projected.x)
                minY = min(minY, projected.y); maxY = max(maxY, projected.y)
            }

            shapes.append(MapShape(points: points,
                                   bounds: CGRect(x: minX, y: minY,
                                                  width: max(maxX - minX, 0.0000001),
                                                  height: max(maxY - minY, 0.0000001))))
        }
        return shapes
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
