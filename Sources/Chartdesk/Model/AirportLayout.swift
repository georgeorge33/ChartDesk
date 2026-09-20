import Foundation
import simd

/// An airport's runways, taxiways and aprons, as OpenStreetMap has them.
///
/// The shapes a chart's ground layout is made of, which no bundled table has: the runway
/// table knows where a runway is and how long, and nothing at all about the taxiways beside
/// it. This is what turns the closest zoom from a rectangle on a field into somewhere you
/// can follow a taxi instruction.
///
/// Fetched from the Overpass API one airport at a time, and kept — an airport's ground plan
/// changes every few years, not every few minutes.
struct AirportLayout {

    /// A line down the middle of something you can taxi or land on.
    struct Way {
        /// "A", "B7", "14L/32R" — what the chart calls it, when OpenStreetMap knows.
        let ref: String
        /// Metres, from the tag where there is one and from what the thing is where there
        /// is not: a runway is wider than a taxiway, and both are wider than a taxilane.
        let width: Double
        let directions: [SIMD3<Double>]
        let cap: SphericalCap
    }

    /// Concrete you park on rather than drive along.
    struct Area {
        let directions: [SIMD3<Double>]
        let cap: SphericalCap
    }

    /// A stand, where an aeroplane parks.
    struct Stand {
        let ref: String
        let direction: SIMD3<Double>
    }

    /// Where you stop and wait, and the bar painted across the taxiway to say so.
    ///
    /// The bar is worked out rather than mapped: OpenStreetMap puts a node on the taxiway
    /// and says nothing about which way the taxiway runs there, so the nearest stretch of
    /// pavement is found and the bar laid across it.
    struct Hold {
        let ref: String
        let direction: SIMD3<Double>
        let across: [SIMD3<Double>]
    }

    /// What a chart calls the taxiway this way belongs to.
    ///
    /// OpenStreetMap numbers a taxiway's segments — Madrid's ZW is tagged ZW-1, ZW-2 and so
    /// on — while the chart paints "ZW5" on the tarmac. Only a letter group, a hyphen and a
    /// number group is touched, so anything else keeps the name it was given.
    static func designator(_ ref: String) -> String {
        let parts = ref.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].allSatisfy(\.isLetter), !parts[0].isEmpty,
              parts[1].allSatisfy(\.isNumber), !parts[1].isEmpty
        else { return ref }
        return String(parts[0] + parts[1])
    }

    /// The two white lines painted down the sides of a runway.
    ///
    /// Worked out from the centreline and the width, because that is all OpenStreetMap has.
    /// Each point is pushed half a width square to the way's own direction there, which on a
    /// sphere is a cross product and not an offset in degrees — at 60° north a degree of
    /// longitude is half what it is at the equator, and a runway drawn that way would be a
    /// wedge.
    static func edges(of way: Way) -> [[SIMD3<Double>]] {
        guard way.directions.count >= 2 else { return [] }
        let half = way.width / 2 / 6_371_000
        var left: [SIMD3<Double>] = [], right: [SIMD3<Double>] = []

        for (index, at) in way.directions.enumerated() {
            // The direction of travel here: forward at the start, back at the end, and the
            // average of the two in between, so a bend does not pinch.
            let before = index > 0 ? way.directions[index - 1] : at
            let after = index < way.directions.count - 1 ? way.directions[index + 1] : at
            let along = after - before
            guard simd_length(along) > 1e-12 else { continue }
            let sideways = simd_cross(at, simd_normalize(along))
            guard simd_length(sideways) > 1e-12 else { continue }
            let offset = simd_normalize(sideways) * half
            left.append(simd_normalize(at - offset))
            right.append(simd_normalize(at + offset))
        }
        guard left.count >= 2 else { return [] }
        return [left, right]
    }

    /// The piano keys: the white bars painted across each threshold.
    ///
    /// The one marking that says "runway" at a glance, and the reason a ground chart's
    /// runway is recognisable at any size. Eight stripes over the middle four-fifths of the
    /// width, starting six metres in and running thirty — which is what the real paint is,
    /// near enough for a map.
    static func thresholdBars(of way: Way) -> [[SIMD3<Double>]] {
        guard way.directions.count >= 2 else { return [] }
        var bars: [[SIMD3<Double>]] = []

        for (at, towards) in [(way.directions[0], way.directions[1]),
                              (way.directions[way.directions.count - 1],
                               way.directions[way.directions.count - 2])] {
            let along = towards - at
            guard simd_length(along) > 1e-12 else { continue }
            let forward = simd_normalize(along)
            let sideways = simd_cross(at, forward)
            guard simd_length(sideways) > 1e-12 else { continue }
            let side = simd_normalize(sideways)

            let start = 6.0 / 6_371_000, run = 30.0 / 6_371_000
            for stripe in 0..<8 {
                let across = (Double(stripe) - 3.5) / 8 * way.width * 0.8 / 6_371_000
                let from = simd_normalize(at + forward * start + side * across)
                let to = simd_normalize(at + forward * (start + run) + side * across)
                bars.append([from, to])
            }
        }
        return bars
    }

    /// A runway's two numbers, each at the end it is painted on.
    ///
    /// "14L/32R" is two ends, and which is which is not a matter of taste: the 14 is painted
    /// where an aeroplane lines up to fly 140°, so it belongs at the end the way runs *from*
    /// on that heading.
    static func numbers(of way: Way) -> [(String, SIMD3<Double>)] {
        let parts = way.ref.split(separator: "/").map(String.init)
        guard parts.count == 2, let first = way.directions.first,
              let last = way.directions.last
        else { return [] }

        let along = Spherical.bearing(from: first, to: last)
        var out: [(String, SIMD3<Double>)] = []
        for part in parts {
            let digits = part.prefix(while: \.isNumber)
            guard let number = Int(digits), number > 0, number <= 36 else { continue }
            let heading = Double(number) * 10
            // Within a right angle of the way's own direction means this number is the one
            // you fly when you start at its first point.
            let difference = abs((heading - along + 540).truncatingRemainder(dividingBy: 360) - 180)
            out.append((part, difference < 90 ? first : last))
        }
        return out
    }

    let icao: String
    let runways: [Way]
    let taxiways: [Way]
    let aprons: [Area]
    let stands: [Stand]
    let holds: [Hold]
    /// When it was fetched, so the panel can say how old it is.
    let fetched: Date

    var isEmpty: Bool { runways.isEmpty && taxiways.isEmpty && aprons.isEmpty }

    /// Everything, for deciding whether any of it is on the sheet.
    var cap: SphericalCap {
        SphericalCap(runways.flatMap(\.directions) + taxiways.flatMap(\.directions))
    }
}

/// What a way is, when OpenStreetMap does not say how wide it is.
enum AirportSurface: String {
    case runway
    case taxiway
    case taxilane
    case apron

    /// Metres. A runway is 45 across at a field that takes jets and 23 at one that does not;
    /// a taxiway is 23; a taxilane between stands is 15. Only used where the way carries no
    /// width of its own, which is most of them.
    var width: Double {
        switch self {
        case .runway: return 45
        case .taxiway: return 23
        case .taxilane: return 15
        case .apron: return 0
        }
    }
}

/// Fetches airport layouts and keeps them.
///
/// Overpass is a free, shared, community-run service, so this asks it for one airport at a
/// time, writes what comes back to disk, and never asks twice. The old taxi router had a
/// command-line tool do this and kept the app off the network entirely; the app fetches its
/// own map tiles now, and an airport you have zoomed into is a much better signal of what to
/// fetch than a list you have to remember to run.
@MainActor
final class AirportLayoutStore: ObservableObject {

    static let shared = AirportLayoutStore()

    @Published private(set) var layouts: [String: AirportLayout] = [:]
    /// Set while one is on its way, so the map can say so rather than looking broken.
    @Published private(set) var fetching: String?
    @Published private(set) var failure: String?

    private var refused: Set<String> = []

    /// The mirrors, in order. The main instance is the busiest.
    private static let endpoints = [
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass-api.de/api/interpreter",
        "https://overpass.osm.ch/api/interpreter",
    ]

    nonisolated static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        // Second version of the query — the first had no stands or holding positions in it,
        // and an answer from it is not missing them, it simply never asked.
        return support.appendingPathComponent("Chartdesk/layouts/v2", isDirectory: true)
    }

    nonisolated static func file(for icao: String) -> URL {
        directory.appendingPathComponent("\(icao.uppercased()).json")
    }

    func layout(for icao: String) -> AirportLayout? { layouts[icao.uppercased()] }

    /// Asks for an airport's layout: memory, then disk, then Overpass.
    func request(_ airport: MapAirport) {
        let icao = airport.icao.uppercased()
        guard layouts[icao] == nil, fetching == nil, !refused.contains(icao) else { return }

        if let onDisk = try? Data(contentsOf: Self.file(for: icao)),
           let layout = Self.parse(onDisk, icao: icao) {
            layouts[icao] = layout
            return
        }

        fetching = icao
        let where_ = airport.coordinate
        Task.detached(priority: .userInitiated) {
            let answer = await Self.fetch(icao: icao, at: where_)
            await MainActor.run {
                self.fetching = nil
                switch answer {
                case .arrived(let layout):
                    self.failure = nil
                    self.layouts[icao] = layout
                case .refused(let problem):
                    // Once per run per airport: Overpass is busy often enough that asking
                    // again on every frame would be rude as well as pointless.
                    self.refused.insert(icao)
                    self.failure = problem
                }
            }
        }
    }

    /// What came back, or why nothing did.
    enum Answer {
        case arrived(AirportLayout)
        case refused(String)
    }

    /// One airport from Overpass, written to disk on the way past.
    private static func fetch(icao: String, at where_: Coordinate) async -> Answer {
        var last = "Overpass did not answer"
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 90)
            request.httpMethod = "POST"
            request.setValue("Chartdesk/1.1 (+https://github.com/georgeorge33/ChartDesk)",
                             forHTTPHeaderField: "User-Agent")
            request.httpBody = query(icao: icao, at: where_).data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    last = "\(URL(string: endpoint)?.host ?? endpoint) answered \(code)"
                    continue
                }
                guard let layout = parse(data, icao: icao) else {
                    last = "nothing in the answer to draw"
                    continue
                }
                try? FileManager.default.createDirectory(at: directory,
                                                         withIntermediateDirectories: true)
                try? data.write(to: file(for: icao))
                return .arrived(layout)
            } catch {
                last = error.localizedDescription
            }
        }
        return .refused(last)
    }

    /// The aerodrome by its ICAO code, and a circle round the airport if that finds nothing.
    ///
    /// Both, in one query, because an aerodrome tagged with its code is the honest boundary
    /// and a great many small fields are a bare node with no boundary at all.
    nonisolated static func query(icao: String, at where_: Coordinate) -> String {
        """
        [out:json][timeout:90];
        (
          way["aeroway"="aerodrome"]["icao"="\(icao)"];
          relation["aeroway"="aerodrome"]["icao"="\(icao)"];
        );
        map_to_area->.apt;
        (
          way["aeroway"~"^(runway|taxiway|taxilane|apron)$"](area.apt);
          way["aeroway"~"^(runway|taxiway|taxilane|apron)$"]\
        (around:4000,\(figure(where_.latitude)),\(figure(where_.longitude)));
        );
        out geom;
        (
          node["aeroway"~"^(parking_position|holding_position)$"](area.apt);
          way["aeroway"="parking_position"](area.apt);
          node["aeroway"~"^(parking_position|holding_position)$"]\
        (around:4000,\(figure(where_.latitude)),\(figure(where_.longitude)));
          way["aeroway"="parking_position"]\
        (around:4000,\(figure(where_.latitude)),\(figure(where_.longitude)));
        );
        out geom;
        """
    }

    nonisolated private static func figure(_ value: Double) -> String {
        String(format: "%.5f", value)
    }

    /// Overpass's own JSON, with the geometry asked for inline.
    nonisolated static func parse(_ data: Data, icao: String) -> AirportLayout? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = top["elements"] as? [[String: Any]]
        else { return nil }

        var runways: [AirportLayout.Way] = []
        var taxiways: [AirportLayout.Way] = []
        var aprons: [AirportLayout.Area] = []
        var stands: [AirportLayout.Stand] = []
        var holdPoints: [(ref: String, direction: SIMD3<Double>)] = []
        var seen = Set<String>()

        for element in elements {
            // The two halves of the query overlap wherever an aerodrome is mapped, and the
            // same way coming back twice would be drawn twice.
            let id = "\(element["type"] as? String ?? "?")\(element["id"] as? Int ?? 0)"
            if !seen.insert(id).inserted { continue }
            guard let tags = element["tags"] as? [String: Any],
                  let kind = tags["aeroway"] as? String
            else { continue }

            let ref = ((tags["ref"] as? String) ?? (tags["name"] as? String) ?? "")
                .trimmingCharacters(in: .whitespaces)

            // A stand or a holding position is a point: a node has its own, and a way — a
            // stand drawn as the line an aeroplane parks along — is taken at its middle.
            if kind == "parking_position" || kind == "holding_position" {
                var at: SIMD3<Double>?
                if let latitude = element["lat"] as? Double,
                   let longitude = element["lon"] as? Double {
                    at = Coordinate(latitude: latitude, longitude: longitude).direction
                } else if let geometry = element["geometry"] as? [[String: Any]],
                          !geometry.isEmpty {
                    let middle = geometry[geometry.count / 2]
                    if let latitude = middle["lat"] as? Double,
                       let longitude = middle["lon"] as? Double {
                        at = Coordinate(latitude: latitude, longitude: longitude).direction
                    }
                }
                guard let at = at else { continue }
                if kind == "parking_position" {
                    guard !ref.isEmpty else { continue }   // an unnamed stand says nothing
                    stands.append(AirportLayout.Stand(ref: ref, direction: at))
                } else {
                    holdPoints.append((ref, at))
                }
                continue
            }

            guard let surface = AirportSurface(rawValue: kind),
                  let geometry = element["geometry"] as? [[String: Any]]
            else { continue }

            // A seaplane base's landing area is tagged as a runway and is a stretch of
            // water; drawn as tarmac it puts a grey strip down the middle of a lake.
            if isWater(tags["surface"] as? String) { continue }

            var directions: [SIMD3<Double>] = []
            directions.reserveCapacity(geometry.count)
            for point in geometry {
                guard let latitude = point["lat"] as? Double,
                      let longitude = point["lon"] as? Double else { continue }
                directions.append(Coordinate(latitude: latitude,
                                             longitude: longitude).direction)
            }
            guard directions.count >= 2 else { continue }
            let cap = SphericalCap(directions)

            if surface == .apron {
                guard directions.count >= 4 else { continue }
                aprons.append(AirportLayout.Area(directions: directions, cap: cap))
                continue
            }

            let width = (tags["width"] as? String).flatMap(metres) ?? surface.width
            let way = AirportLayout.Way(ref: ref, width: width,
                                        directions: directions, cap: cap)
            if surface == .runway { runways.append(way) } else { taxiways.append(way) }
        }

        guard !(runways.isEmpty && taxiways.isEmpty && aprons.isEmpty) else { return nil }
        let holds = bars(for: holdPoints, along: taxiways + runways)
        return AirportLayout(icao: icao, runways: runways, taxiways: taxiways,
                             aprons: aprons, stands: stands, holds: holds, fetched: Date())
    }

    /// Lays a bar across the pavement at each holding position.
    ///
    /// OpenStreetMap marks the spot and says nothing about which way the taxiway runs
    /// through it, so the nearest stretch of pavement is found and the bar drawn square to
    /// it — which is where the paint is on the ground.
    nonisolated static func bars(for points: [(ref: String, direction: SIMD3<Double>)],
                                 along ways: [AirportLayout.Way]) -> [AirportLayout.Hold] {
        var holds: [AirportLayout.Hold] = []
        for point in points {
            var best: (from: SIMD3<Double>, to: SIMD3<Double>, width: Double, dot: Double)?
            for way in ways {
                // Nowhere near it: a cap test before walking every segment.
                guard simd_dot(way.cap.centre, point.direction)
                        > cos(way.cap.radius + 0.0002) else { continue }
                for index in 0..<(way.directions.count - 1) {
                    let dot = max(simd_dot(way.directions[index], point.direction),
                                  simd_dot(way.directions[index + 1], point.direction))
                    if dot > (best?.dot ?? -1) {
                        best = (way.directions[index], way.directions[index + 1],
                                way.width, dot)
                    }
                }
            }
            guard let found = best else { continue }

            // Square to the pavement, and as wide as it is.
            let along = simd_normalize(found.to - found.from)
            let sideways = simd_normalize(simd_cross(point.direction, along))
            let half = found.width / 2 / 6_371_000
            let left = simd_normalize(point.direction - sideways * half)
            let right = simd_normalize(point.direction + sideways * half)
            holds.append(AirportLayout.Hold(ref: point.ref, direction: point.direction,
                                            across: [left, right]))
        }
        return holds
    }

    /// True for a landing area that is water rather than a surface.
    ///
    /// OpenStreetMap writes `surface=water`, and the table this app bundles is built from
    /// OurAirports, which spells the same thing WATER, WAT, WATER-E, WATER-G and "SUMMER
    /// WATER." — so both ask whether the word is in there at all.
    nonisolated static func isWater(_ surface: String?) -> Bool {
        (surface ?? "").uppercased().contains("WAT")
    }

    /// "45", "45 m", "150 ft" — OpenStreetMap's width tag, as metres.
    nonisolated static func metres(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("ft") || trimmed.hasSuffix("'") {
            let number = trimmed.replacingOccurrences(of: "ft", with: "")
                .replacingOccurrences(of: "'", with: "")
            return Double(number.trimmingCharacters(in: .whitespaces)).map { $0 * 0.3048 }
        }
        return Double(trimmed.replacingOccurrences(of: "m", with: "")
            .trimmingCharacters(in: .whitespaces))
    }
}
