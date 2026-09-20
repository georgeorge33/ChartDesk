import CoreGraphics
import Foundation
import simd

// The layers that go over the geography: airspace, internal borders, and the names of towns.
// Each is read only when it is switched on, and each is a table built by Tools/.

/// A kind of airspace, as a chart draws it.
///
/// The five ICAO classes a map is worth drawing, and the three kinds of area you keep out of.
/// Class F and G are left out on purpose: G is everything that is not something else, and a
/// layer that covers the whole world tells you nothing.
enum AirspaceClass: String, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"
    case prohibited = "PROHIBITED"
    case restricted = "RESTRICTED"
    case danger = "DANGER"

    var name: String {
        switch self {
        case .a, .b, .c, .d, .e: return "Class \(rawValue)"
        case .prohibited: return "Prohibited"
        case .restricted: return "Restricted"
        case .danger: return "Danger"
        }
    }

    /// The areas you are kept out of rather than cleared into, which a chart draws in red.
    var isSpecialUse: Bool {
        switch self {
        case .prohibited, .restricted, .danger: return true
        default: return false
        }
    }

    /// Quietest first, so the busier airspace reads over it, and the areas to avoid on top.
    static let drawingOrder: [AirspaceClass] =
        [.e, .a, .d, .c, .b, .danger, .restricted, .prohibited]
}

/// What the Layers panel offers a switch for.
///
/// One per ICAO class, because which of them you want on the sheet depends on what you are
/// doing — Class E over the United States is every transition area in the country and buries
/// everything else; over Europe it is a handful of rings. The three kinds of area you keep
/// out of share one switch: nobody wants danger areas drawn but not prohibited ones.
enum AirspaceSwitch: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"
    case areas = "PRD"

    var id: String { rawValue }

    /// What the chip says.
    var label: String { self == .areas ? "P R D" : rawValue }

    /// And what it means, for the tooltip.
    var name: String {
        self == .areas ? "Prohibited, restricted and danger areas" : "Class \(rawValue)"
    }

    var covers: [AirspaceClass] {
        switch self {
        case .a: return [.a]
        case .b: return [.b]
        case .c: return [.c]
        case .d: return [.d]
        case .e: return [.e]
        case .areas: return [.prohibited, .restricted, .danger]
        }
    }

    /// What is on until you say otherwise: everything except Class E.
    ///
    /// Not a preference about Class E so much as about the United States, where it is the
    /// 3,893 transition areas that sit over the whole country from 700ft — every one of them
    /// a ring labelled FL600 over 7 AGL, and together a wall of magenta with the Class B
    /// somewhere behind it. Over Europe it is a few dozen rings and perfectly reasonable,
    /// which is why it is a switch and not a deletion.
    static let byDefault: Set<AirspaceSwitch> = [.a, .b, .c, .d, .areas]

    /// The switch a ring answers to.
    static func holding(_ klass: AirspaceClass) -> AirspaceSwitch {
        klass.isSpecialUse ? .areas : (AirspaceSwitch(rawValue: klass.rawValue) ?? .areas)
    }
}

/// How high a shelf reaches, and what the figure is measured from.
///
/// The FAA's table is feet above the sea and nothing else, so this was an `Int` until openAIP
/// arrived with the rest of the world in it: a European TMA tops out at a flight level, a
/// danger area is often so many feet above the ground, and "2500" means two different heights
/// depending on which. Writing them all as one number would have put the floor of a German
/// danger area 2,000ft out over high ground, which is the wrong way round to be wrong.
struct AirspaceLimit: Equatable {

    enum Datum: Equatable {
        /// The ground itself.
        case surface
        /// Feet above mean sea level.
        case mean
        /// Feet above the ground.
        case aboveGround
        /// A flight level: pressure altitude, in hundreds.
        case standard
        /// No ceiling at all.
        case unlimited
    }

    let feet: Int
    let datum: Datum

    /// The way a chart writes it: hundreds of feet, SFC at the ground, FL where it is one.
    var label: String {
        switch datum {
        case .surface: return "SFC"
        case .unlimited: return "UNL"
        case .standard: return "FL\(feet / 100)"
        case .aboveGround: return "\(feet / 100) AGL"
        case .mean: return "\(feet / 100)"
        }
    }

    /// Reads one field of the table.
    ///
    /// Self-describing, rather than a number in one column and its datum in another: `SFC`,
    /// `7000`, `FL195`, `2500AGL`, `UNL`. The FAA's table has only the first two forms, so it
    /// reads unchanged — which is the point of doing it this way.
    init?(_ token: some StringProtocol) {
        let text = token.trimmingCharacters(in: .whitespaces).uppercased()
        switch text {
        case "SFC", "GND", "0":
            self = AirspaceLimit(feet: 0, datum: .surface)
        case "UNL", "UNLTD", "UNLIMITED":
            self = AirspaceLimit(feet: 99_999, datum: .unlimited)
        default:
            if text.hasPrefix("FL"), let level = Int(text.dropFirst(2)) {
                self = AirspaceLimit(feet: level * 100, datum: .standard)
            } else if text.hasSuffix("AGL"), let feet = Int(text.dropLast(3)) {
                // Zero above the ground is the ground, whatever the datum says.
                self = AirspaceLimit(feet: feet, datum: feet == 0 ? .surface : .aboveGround)
            } else if let feet = Int(text) {
                self = AirspaceLimit(feet: feet, datum: .mean)
            } else {
                return nil
            }
        }
    }

    init(feet: Int, datum: Datum) {
        self.feet = feet
        self.datum = datum
    }
}

/// One shelf of airspace: a ring, and what it reaches from and to.
///
/// A Class B is several of these — Boston's is four, stacked from the surface to 7,000ft —
/// which is why each carries its own ceiling and floor rather than the airport carrying one
/// pair. It is what lets the map label a ring the way a chart does.
struct MapAirspace {
    let klass: AirspaceClass
    /// What it is called: an airport's ident from the FAA, an airspace name from openAIP.
    let name: String
    let ceiling: AirspaceLimit
    let floor: AirspaceLimit

    let directions: [SIMD3<Double>]
    let cap: SphericalCap

    /// Hundreds of feet, the way a chart writes it: 70 over 20, or 70 over SFC.
    var ceilingLabel: String { ceiling.label }
    var floorLabel: String { floor.label }

    /// Where to write the ceiling and floor.
    ///
    /// Not the middle of the ring. A Class B is several shelves about one airport, and every
    /// one of them has its middle over the runway — so labelling them there stacks four
    /// figures on one spot and a declutterer keeps one. Offset out towards each shelf's own
    /// edge instead, which spreads them the way a chart does, each figure sitting in the ring
    /// it belongs to.
    var labelAt: Coordinate {
        let middle = Coordinate(cap.centre)
        let out = cap.radius * 180 / .pi * 0.72
        return Coordinate(latitude: min(max(middle.latitude + out, -89), 89),
                          longitude: middle.longitude)
    }
}

/// A town or city, with Natural Earth's own sense of how important it is.
struct MapCity {
    /// 0 belongs on a world map, 10 on a local one.
    let rank: Int
    let coordinate: Coordinate
    let direction: SIMD3<Double>
    let name: String
}

extension WorldData {

    /// Airspace, from openAIP.
    ///
    /// A file you build yourself with `Tools/make_openaip.py` and your own key, so it may
    /// simply not be there — in which case this reads nothing and the Layers panel says why.
    nonisolated static func loadAirspace() -> [MapAirspace] {
        guard let data = try? Data(contentsOf: OpenAIPFiles.airspace, options: [.mappedIfSafe])
        else { return [] }
        return inDrawingOrder(parseAirspace(data))
    }

    /// The rings, quietest first, so that drawing them in order paints the busy airspace over
    /// the quiet and the areas to keep out of over everything.
    ///
    /// Sorted once here rather than filtered by kind inside the draw. openAIP's table is ten
    /// times the FAA's, and a pass per kind is eight passes over fifty thousand rings on
    /// every frame to save one comparison each.
    nonisolated static func inDrawingOrder(_ rings: [MapAirspace]) -> [MapAirspace] {
        var rank: [AirspaceClass: Int] = [:]
        for (index, klass) in AirspaceClass.drawingOrder.enumerated() { rank[klass] = index }
        return rings.sorted { rank[$0.klass, default: 0] < rank[$1.klass, default: 0] }
    }

    /// Kept apart from the reading so it can be checked against the table on disk, without a
    /// bundle to find it in.
    ///
    /// Scanned as bytes, like the geography tables and for the same reason: openAIP's world
    /// is 1.2 million points, and decoding the file into a string to split it took six
    /// seconds and most of a gigabyte before this was written that way.
    ///
    /// It also fixes a fault the string version had. `split(whereSeparator: \.isNewline)`
    /// breaks on every character Unicode calls a line break, and 25 of openAIP's names hold
    /// a stray U+0085 — so those rings were cut in half and dropped, silently. A table is
    /// lines separated by 0x0A and nothing else.
    nonisolated static func parseAirspace(_ data: Data) -> [MapAirspace] {
        var out: [MapAirspace] = []
        out.reserveCapacity(20_000)

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                defer { start = end + 1 }
                guard end > start, bytes[start] != 0x23 else { continue }

                // kind, name, ceiling, floor, then the ring.
                var at = start
                guard let kind = field(bytes, &at, end),
                      let name = field(bytes, &at, end),
                      let ceilingText = field(bytes, &at, end),
                      let floorText = field(bytes, &at, end),
                      let klass = AirspaceClass(rawValue: kind.uppercased()),
                      let ceiling = AirspaceLimit(ceilingText),
                      let floor = AirspaceLimit(floorText)
                else { continue }

                var directions: [SIMD3<Double>] = []
                while let longitude = WorldData.number(bytes, &at, end),
                      let latitude = WorldData.number(bytes, &at, end) {
                    directions.append(Coordinate(latitude: latitude,
                                                 longitude: longitude).direction)
                }
                guard directions.count >= 4 else { continue }

                out.append(MapAirspace(klass: klass,
                                       name: name,
                                       ceiling: ceiling,
                                       floor: floor,
                                       directions: directions,
                                       cap: SphericalCap(directions)))
            }
        }
        return out
    }

    /// One tab-separated field, up to the tab or the end of the line.
    nonisolated private static func field(_ bytes: UnsafeBufferPointer<UInt8>,
                                          _ index: inout Int, _ end: Int) -> String? {
        guard index < end else { return nil }
        let from = index
        while index < end, bytes[index] != 0x09 { index += 1 }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[from..<index]),
                          as: UTF8.self)
        if index < end { index += 1 }               // step over the tab
        return text
    }

    /// Internal borders — states, provinces, counties — for every country.
    nonisolated static func loadStates() -> [MapShape] {
        shapes("states")
    }

    /// Towns and cities, in the order the tables put them: most important first.
    nonisolated static func loadCities() -> [MapCity] {
        guard let url = Bundle.main.url(forResource: "cities", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return [] }
        return parseCities(data)
    }

    nonisolated static func parseCities(_ data: Data) -> [MapCity] {
        var out: [MapCity] = []
        out.reserveCapacity(7_500)
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  let rank = Int(fields[0]),
                  let latitude = Double(fields[1]),
                  let longitude = Double(fields[2])
            else { continue }
            let coordinate = Coordinate(latitude: latitude, longitude: longitude)
            out.append(MapCity(rank: rank, coordinate: coordinate,
                               direction: coordinate.direction, name: String(fields[3])))
        }
        return out
    }
}

/// How much of each layer there is room for at a given zoom.
enum MapLayerRoom {

    /// Airspace is only worth drawing once a ring is more than a smudge. Below this it is a
    /// heap of overlapping circles with no labels legible on any of them.
    static let airspaceFrom: CGFloat = 20_000

    /// And the same thing said about one ring rather than about the view: how many points
    /// across a ring must measure on the sheet before it is drawn at all.
    ///
    /// A zoom threshold alone was enough for the FAA's 4,223 rings and is not enough for
    /// openAIP's 18,489. Measured at 16° across, which is as wide as this layer ever draws:
    /// over Chicago 1,872 rings are in view and 152 are bigger than this; over the Alps
    /// 3,835 and 860. The rest are specks carrying two figures too small to read, and enough
    /// of them to wash the sheet in colour.
    ///
    /// Twenty-two points is a ring 44 across, which is the room a ceiling over a floor needs.
    static let leastRadius: CGFloat = 22
    /// Internal borders clutter a view of a continent and place a view of a state.
    static let statesFrom: CGFloat = 6_000

    /// The airport's ground plan, which is worth drawing once a taxiway is wider than a
    /// line: about six kilometres across a panel, where a runway is already most of it.
    static let layoutFrom: CGFloat = 6_000_000

    /// And worth *fetching* ten times sooner than that — about sixty kilometres across,
    /// which is the point where it is clear which field you are coming down at.
    ///
    /// Overpass takes a minute or two, so asking at the zoom where the layout would be drawn
    /// means watching an empty airport while it arrives. Asking on the way down means it is
    /// there when you get there.
    static let layoutFetchFrom: CGFloat = 600_000

    /// And the stands, which are hundreds of numbers at a big field: only once the view is
    /// about a kilometre across, where you would be looking for one.
    static let standsFrom: CGFloat = 30_000_000

    /// The least important town worth naming, on Natural Earth's own scale of 0 to 10.
    ///
    /// Drawn in rank order and decluttered, so this is a floor on the work rather than on what
    /// appears: a name that will not fit is dropped whatever its rank.
    static func cityRank(degreesAcross: Double) -> Int {
        switch degreesAcross {
        case 150...: return 0
        case 60..<150: return 1
        case 30..<60: return 2
        case 15..<30: return 4
        case 7..<15: return 6
        case 3..<7: return 7
        default: return 10
        }
    }
}
