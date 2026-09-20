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

    let icao: String
    let runways: [Way]
    let taxiways: [Way]
    let aprons: [Area]
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
        return support.appendingPathComponent("Chartdesk/layouts", isDirectory: true)
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
        var seen = Set<Int>()

        for element in elements {
            // The two halves of the query overlap wherever an aerodrome is mapped, and the
            // same way coming back twice would be drawn twice.
            if let id = element["id"] as? Int, !seen.insert(id).inserted { continue }
            guard let tags = element["tags"] as? [String: Any],
                  let kind = tags["aeroway"] as? String,
                  let surface = AirportSurface(rawValue: kind),
                  let geometry = element["geometry"] as? [[String: Any]]
            else { continue }

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

            let ref = ((tags["ref"] as? String) ?? (tags["name"] as? String) ?? "")
                .trimmingCharacters(in: .whitespaces)
            let width = (tags["width"] as? String).flatMap(metres) ?? surface.width
            let way = AirportLayout.Way(ref: ref, width: width,
                                        directions: directions, cap: cap)
            if surface == .runway { runways.append(way) } else { taxiways.append(way) }
        }

        guard !(runways.isEmpty && taxiways.isEmpty && aprons.isEmpty) else { return nil }
        return AirportLayout(icao: icao, runways: runways, taxiways: taxiways,
                             aprons: aprons, fetched: Date())
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
