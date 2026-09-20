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
        /// True where the pavement under this line is mapped as its own outline, so the
        /// width tag does not have to stand in for it and nothing should be drawn from it.
        let paved: Bool
        /// The white lines down the sides and the piano keys across the thresholds.
        ///
        /// Runways only, and worked out once on the field's own plane rather than on every
        /// frame: they depend on the runway and not on where the camera is.
        let edges: [[SIMD3<Double>]]
        let keys: [[SIMD3<Double>]]

        init(ref: String, width: Double, directions: [SIMD3<Double>], cap: SphericalCap,
             paved: Bool = false, edges: [[SIMD3<Double>]] = [],
             keys: [[SIMD3<Double>]] = []) {
            self.ref = ref
            self.width = width
            self.directions = directions
            self.cap = cap
            self.paved = paved
            self.edges = edges
            self.keys = keys
        }
    }

    /// Pavement mapped as its own outline rather than as a line with a width tag.
    ///
    /// The distinction an AMDB is built on: there, a taxiway is a polygon and the yellow
    /// line down it is a separate feature. OpenStreetMap mostly has only the line, and
    /// inflating it by its width is a guess at where the tarmac stops — but at the fields
    /// where somebody has drawn the outline, `area:aeroway` is the real edge and is used
    /// in place of the guess.
    struct Pavement {
        let surface: AirportSurface
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
    /// On the field's own plane this is what it sounds like: step half a width square to
    /// the way's direction. Against the globe it was a cross product per point, to keep a
    /// runway at 60° north from being drawn as a wedge — the plane has no such problem to
    /// solve, because a metre is a metre in both directions on it.
    static func edges(of way: Way, in frame: AirportFrame) -> [[SIMD3<Double>]] {
        let line = way.directions.map(frame.plane)
        guard line.count >= 2 else { return [] }
        let half = way.width / 2
        var left: [SIMD2<Double>] = [], right: [SIMD2<Double>] = []

        for (index, at) in line.enumerated() {
            // The direction of travel here: forward at the start, back at the end, and the
            // average of the two in between, so a bend does not pinch.
            let before = index > 0 ? line[index - 1] : at
            let after = index < line.count - 1 ? line[index + 1] : at
            let along = after - before
            guard simd_length(along) > 1e-9 else { continue }
            let forward = simd_normalize(along)
            let sideways = SIMD2(-forward.y, forward.x) * half
            left.append(at - sideways)
            right.append(at + sideways)
        }
        guard left.count >= 2 else { return [] }
        return [left.map(frame.globe), right.map(frame.globe)]
    }

    /// The piano keys: the white bars painted across each threshold.
    ///
    /// The one marking that says "runway" at a glance, and the reason a ground chart's
    /// runway is recognisable at any size. Eight stripes over the middle four-fifths of the
    /// width, starting six metres in and running thirty — which is what the real paint is,
    /// near enough for a map. In metres, on the plane, because that is what those figures
    /// already are.
    static func thresholdBars(of way: Way, in frame: AirportFrame) -> [[SIMD3<Double>]] {
        let line = way.directions.map(frame.plane)
        guard line.count >= 2 else { return [] }
        var bars: [[SIMD3<Double>]] = []

        for (at, towards) in [(line[0], line[1]),
                              (line[line.count - 1], line[line.count - 2])] {
            let along = towards - at
            guard simd_length(along) > 1e-9 else { continue }
            let forward = simd_normalize(along)
            let side = SIMD2(-forward.y, forward.x)

            for stripe in 0..<8 {
                let across = (Double(stripe) - 3.5) / 8 * way.width * 0.8
                bars.append([frame.globe(at + forward * 6 + side * across),
                             frame.globe(at + forward * 36 + side * across)])
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
    /// Runway and taxiway pavement that is drawn rather than inferred.
    let pavement: [Pavement]
    let stands: [Stand]
    let holds: [Hold]
    /// The field's own plane, kept so anything worked out later is worked out on it.
    let frame: AirportFrame
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

/// One airport's layout, counted up, for the list of what is on this Mac.
struct AirportLayoutSummary: Identifiable {
    let icao: String
    /// From the bundled table, when it knows the field. Blank for one it does not.
    let name: String
    let runways: Int
    let taxiways: Int
    let aprons: Int
    /// How much of the pavement is a drawn outline rather than an inflated centreline.
    let outlines: Int
    let stands: Int
    let holds: Int
    let bytes: Int
    let fetched: Date
    /// True when the map has it in hand, rather than only on disk.
    let loaded: Bool

    var id: String { icao }
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
    /// Waiting their turn, in the order to ask. One request at a time, always: Overpass is
    /// free, shared and slow, and a dozen at once would be both rude and no faster.
    private var queued: [MapAirport] = []
    /// The flight's own fields, wanted whatever the map is showing.
    private var pinned: [MapAirport] = []

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
        //
        // The pavement outlines were added without a third version, which is a judgement
        // rather than an oversight. `area:aeroway` is on about one taxiway in a hundred
        // worldwide and on none at all at most large fields — Frankfurt has none, Heathrow
        // has one — so throwing away a cache that takes hours to rebuild would cost far
        // more than it returns. Delete the directory to refetch with the outlines.
        return support.appendingPathComponent("Chartdesk/layouts/v2", isDirectory: true)
    }

    nonisolated static func file(for icao: String) -> URL {
        directory.appendingPathComponent("\(icao.uppercased()).json")
    }

    func layout(for icao: String) -> AirportLayout? { layouts[icao.uppercased()] }

    /// Every layout on this Mac, counted.
    ///
    /// Reads and parses the lot, which is a few milliseconds an airport — fine for a window
    /// somebody opened to look at the list, and not something to do on a frame. The set on
    /// disk is the honest answer to "what have I got": the map holds only what it has been
    /// close to since launch, and everything else is waiting in the cache.
    nonisolated static func inventory(loaded: Set<String>) -> [AirportLayoutSummary] {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey,
                                                                                   .contentModificationDateKey]))
            ?? []
        var found: [AirportLayoutSummary] = []
        for file in files where file.pathExtension == "json" {
            let icao = file.deletingPathExtension().lastPathComponent.uppercased()
            guard let data = try? Data(contentsOf: file),
                  let layout = parse(data, icao: icao)
            else { continue }
            let about = try? file.resourceValues(forKeys: [.fileSizeKey,
                                                           .contentModificationDateKey])
            found.append(AirportLayoutSummary(
                icao: icao,
                name: WorldData.airport(icao)?.name ?? "",
                runways: layout.runways.count,
                taxiways: layout.taxiways.count,
                aprons: layout.aprons.count,
                outlines: layout.pavement.count,
                stands: layout.stands.count,
                holds: layout.holds.count,
                bytes: about?.fileSize ?? data.count,
                fetched: about?.contentModificationDate ?? Date(),
                loaded: loaded.contains(icao)))
        }
        return found.sorted { $0.taxiways > $1.taxiways }
    }

    /// The codes the map is holding, for the list to mark.
    var held: Set<String> { Set(layouts.keys) }

    /// True when this one was asked for and refused, so nothing keeps promising it.
    func hasRefused(_ icao: String) -> Bool { refused.contains(icao.uppercased()) }

    /// How many are still waiting their turn.
    var waiting: Int { queued.count }

    /// The fields the loaded flight uses. Fetched whatever the map is showing, and first.
    ///
    /// The one set of layouts you know you are going to want, because you are flying there.
    /// Asking for them when the plan loads means they are on the disk by the time you are on
    /// the ground, rather than a minute of waiting at the moment you most want the map.
    func alwaysKeep(_ airports: [MapAirport]) {
        pinned = airports
        for airport in airports.reversed() where !isHeld(airport.icao) {
            queued.removeAll { $0.icao.uppercased() == airport.icao.uppercased() }
            queued.insert(airport, at: 0)
        }
        start()
    }

    /// The fields in view, biggest first.
    ///
    /// Replaces whatever was queued, because the view has moved and the old queue is
    /// somewhere else — but the flight's own fields stay at the front of it.
    func want(_ airports: [MapAirport]) {
        let flight = Set(pinned.map { $0.icao.uppercased() })
        queued = pinned.filter { !isHeld($0.icao) }
            + airports.filter { !flight.contains($0.icao.uppercased()) && !isHeld($0.icao) }
        start()
    }

    /// One airport, for when something asks about exactly one.
    func request(_ airport: MapAirport) { want([airport]) }

    /// In hand already, or asked and refused: either way there is nothing to do.
    private func isHeld(_ icao: String) -> Bool {
        let icao = icao.uppercased()
        return layouts[icao] != nil || refused.contains(icao)
    }

    /// Takes the next one off the queue, unless one is already on its way.
    private func start() {
        guard fetching == nil, !queued.isEmpty else { return }
        let airport = queued.removeFirst()
        let icao = airport.icao.uppercased()
        guard !isHeld(icao) else { return start() }

        // Disk first: an airport fetched last week costs a file read, not a minute.
        if let onDisk = try? Data(contentsOf: Self.file(for: icao)),
           let layout = Self.parse(onDisk, icao: icao) {
            layouts[icao] = layout
            return start()
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
                self.start()
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
                    // Overpass reports its own failures in the body, with a perfectly good
                    // HTTP 200 and no elements. Read as "no aeroways here" that is
                    // indistinguishable from a field nobody has mapped, and the panel ends
                    // up blaming OpenStreetMap for a busy server.
                    last = remark(in: data) ?? "no aeroways in the answer for \(icao)"
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
          way["area:aeroway"~"^(runway|taxiway|taxilane|apron)$"](area.apt);
          way["area:aeroway"~"^(runway|taxiway|taxilane|apron)$"]\
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
    /// What Overpass says when it is refusing rather than answering.
    nonisolated static func remark(in data: Data) -> String? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remark = top["remark"] as? String
        else { return nil }
        return "Overpass: " + remark.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func parse(_ data: Data, icao: String) -> AirportLayout? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = top["elements"] as? [[String: Any]]
        else { return nil }

        var runways: [AirportLayout.Way] = []
        var taxiways: [AirportLayout.Way] = []
        var aprons: [AirportLayout.Area] = []
        var pavement: [AirportLayout.Pavement] = []
        var stands: [AirportLayout.Stand] = []
        var holdPoints: [(ref: String, direction: SIMD3<Double>)] = []
        var seen = Set<String>()

        for element in elements {
            // The two halves of the query overlap wherever an aerodrome is mapped, and the
            // same way coming back twice would be drawn twice.
            let id = "\(element["type"] as? String ?? "?")\(element["id"] as? Int ?? 0)"
            if !seen.insert(id).inserted { continue }
            guard let tags = element["tags"] as? [String: Any] else { continue }

            // An outline rather than a line down the middle. `area:aeroway` is the tag for
            // it; the older way of saying the same thing is the ordinary aeroway tag with
            // area=yes on a closed ring, and both mean "this is the tarmac itself".
            var outline = tags["area:aeroway"] as? String
            if outline == nil, (tags["area"] as? String) == "yes" {
                outline = tags["aeroway"] as? String
            }
            guard let kind = outline ?? (tags["aeroway"] as? String) else { continue }

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

            if outline != nil {
                guard directions.count >= 4 else { continue }
                if surface == .apron {
                    aprons.append(AirportLayout.Area(directions: directions, cap: cap))
                } else {
                    pavement.append(AirportLayout.Pavement(surface: surface,
                                                           directions: directions, cap: cap))
                }
                continue
            }

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

        // Everything after this point is worked out on the field's own plane, so the plane
        // comes first — from what is mapped, which is the field.
        let frame = AirportFrame(covering: runways.flatMap(\.directions)
                                    + taxiways.flatMap(\.directions))

        // The outlines in metres, once. Asking whether a centreline has its pavement drawn
        // is then a ray cast rather than a reprojection per test.
        let rings = pavement.map { (isRunway: $0.surface == .runway, cap: $0.cap,
                                    ring: $0.directions.map(frame.plane)) }
        func covered(_ way: AirportLayout.Way, runway: Bool) -> Bool {
            guard !rings.isEmpty else { return false }
            let at = way.directions[way.directions.count / 2]
            let middle = frame.plane(at)
            for entry in rings where entry.isRunway == runway {
                // Nowhere near it: a cap test before walking the ring.
                guard simd_dot(entry.cap.centre, at) >= entry.cap.cosRadius else { continue }
                if AirportFrame.encloses(entry.ring, middle) { return true }
            }
            return false
        }

        // The runway keeps its paint whether or not its tarmac is drawn: an outline is the
        // pavement, and the white lines and piano keys on top of it are a separate thing —
        // which is exactly how an AMDB separates a runway element from a runway marking.
        let paved = runways.map { way in
            AirportLayout.Way(ref: way.ref, width: way.width, directions: way.directions,
                              cap: way.cap, paved: covered(way, runway: true),
                              edges: AirportLayout.edges(of: way, in: frame),
                              keys: AirportLayout.thresholdBars(of: way, in: frame))
        }
        let taxied = taxiways.map { way in
            AirportLayout.Way(ref: way.ref, width: way.width, directions: way.directions,
                              cap: way.cap, paved: covered(way, runway: false))
        }

        let holds = bars(for: holdPoints, along: taxied + paved, in: frame)
        return AirportLayout(icao: icao, runways: paved, taxiways: taxied,
                             aprons: aprons, pavement: pavement, stands: stands,
                             holds: holds, frame: frame, fetched: Date())
    }

    /// Lays a bar across the pavement at each holding position.
    ///
    /// OpenStreetMap marks the spot and says nothing about which way the taxiway runs
    /// through it, so the nearest stretch of pavement is found and the bar drawn square to
    /// it — which is where the paint is on the ground.
    nonisolated static func bars(for points: [(ref: String, direction: SIMD3<Double>)],
                                 along ways: [AirportLayout.Way],
                                 in frame: AirportFrame) -> [AirportLayout.Hold] {
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

            // Square to the pavement, and as wide as it is — on the plane, where "half a
            // width square to it" is the two words it sounds like.
            let along = simd_normalize(frame.plane(found.to) - frame.plane(found.from))
            let at = frame.plane(point.direction)
            let sideways = SIMD2(-along.y, along.x) * (found.width / 2)
            let left = frame.globe(at - sideways)
            let right = frame.globe(at + sideways)
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
