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
        /// What it is. A taxiway is movement area and carries a painted centreline and a
        /// designator; a taxilane is the lead into a stand on the apron, which is pavement
        /// and nothing else.
        let surface: AirportSurface
        /// True where the pavement under this line is mapped as its own outline, so the
        /// width tag does not have to stand in for it and nothing should be drawn from it.
        let paved: Bool
        /// The white lines down the sides and the piano keys across the thresholds.
        ///
        /// Runways only, and worked out once on the field's own plane rather than on every
        /// frame: they depend on the runway and not on where the camera is.
        let edges: [[SIMD3<Double>]]
        let keys: [[SIMD3<Double>]]
        /// The touchdown zone and the aiming point: the blocks of white either side of the
        /// centreline a few hundred metres in from each threshold.
        let zones: [Paint]
        /// Each end's number, painted across the runway the way it is on the concrete.
        let names: [Painted]
        /// The broken white line down the middle, which starts where the number ends
        /// rather than at the threshold: painted through the figures, it strikes them out.
        let centreline: [SIMD3<Double>]

        /// True for the movement area: what a clearance names and a chart letters.
        var isMovementArea: Bool { surface == .runway || surface == .taxiway }

        init(ref: String, width: Double, directions: [SIMD3<Double>], cap: SphericalCap,
             surface: AirportSurface, paved: Bool = false,
             edges: [[SIMD3<Double>]] = [], keys: [[SIMD3<Double>]] = [],
             zones: [Paint] = [], names: [Painted] = [],
             centreline: [SIMD3<Double>] = []) {
            self.ref = ref
            self.width = width
            self.directions = directions
            self.cap = cap
            self.surface = surface
            self.paved = paved
            self.edges = edges
            self.keys = keys
            self.zones = zones
            self.names = names
            self.centreline = centreline
        }
    }

    /// A stripe of paint: a line down its middle, and how wide it is in metres.
    struct Paint {
        let line: [SIMD3<Double>]
        let width: Double
        /// And never thinner than this on the screen, in points. For paint that is a line
        /// to be followed rather than a block to be seen — a centreline's arrows, a
        /// chevron — which at its real width is a hairline at any zoom a chart is read at.
        var least = 0.0
    }

    /// The ends of a runway that are not the runway proper.
    ///
    /// A displaced threshold's stretch is runway you may take off from and roll out on but
    /// not land on, so it carries arrows pointing at the threshold where the centreline
    /// would be. A stopway or a blast pad beyond the end is not for aeroplanes at all but
    /// in an emergency, and carries yellow chevrons pointing back at the runway.
    struct RunwayEnd {
        enum Kind { case displaced, pad }
        let kind: Kind
        /// The concrete, as a closed ring.
        let outline: [SIMD3<Double>]
        /// Its paint: the threshold bar, arrowheads and arrows in white, or chevrons in
        /// yellow.
        let marks: [Paint]
        let cap: SphericalCap
    }

    /// A runway number, painted on the runway rather than written beside it.
    ///
    /// Across the runway and facing the aeroplane landing on it, which is how the paint is
    /// laid: the top of the figures points down the runway, away from the threshold.
    struct Painted {
        let text: String
        /// The middle of the figures.
        let centre: SIMD3<Double>
        /// A point further down the runway from the centre, which is the way the tops of
        /// the figures face. A bearing would do on a globe; on a map, projecting the two
        /// points and taking the angle between them is the same thing and stays right
        /// whatever the projection does to angles near the poles.
        let ahead: SIMD3<Double>
        /// How tall the figures are, in metres.
        let height: Double
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
        /// Grass inside the concrete: X-Plane draws an apron round an island as one outline
        /// with a hole in it.
        var holes: [[SIMD3<Double>]] = []
    }

    /// A line painted on the ground: a centreline, an edge, a hold line, an apron's safety
    /// line. X-Plane's airport file has every one of them; OpenStreetMap has none.
    struct Marking {
        struct Style: Equatable {
            enum Colour { case yellow, white, red, orange }
            enum Kind {
                case centreline
                case edge
                /// A hold line for something other than a runway, or for an ILS's critical
                /// area. The runway's own are holds, not markings.
                case hold
                case runwayHold
                case broken
                case other
            }
            let colour: Colour
            let kind: Kind
        }
        let style: Style
        let directions: [SIMD3<Double>]
        let cap: SphericalCap
    }

    /// Where a layout came from, which is who it is credited to.
    enum Source: Equatable {
        case openStreetMap
        /// From the X-Plane Scenery Gateway, with the number of the approved version it is.
        case xPlane(scenery: Int)

        /// For telling two copies of one airport apart, where the ICAO alone cannot.
        var tag: String {
            switch self {
            case .openStreetMap: return "osm"
            case .xPlane(let scenery): return "xp\(scenery)"
            }
        }

        var isXPlane: Bool {
            if case .xPlane = self { return true }
            return false
        }

        var name: String { isXPlane ? "X-Plane" : "OpenStreetMap" }
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

        // From each threshold along the runway's own line, like everything else painted on it.
        for inwards in [line, Array(line.reversed())] {
            let (near, _) = walk(inwards, 6)
            let (far, _) = walk(inwards, 36)
            let run = far - near
            guard simd_length(run) > 1e-9 else { continue }
            let side = SIMD2(-run.y, run.x) / simd_length(run)

            for stripe in 0..<8 {
                let across = (Double(stripe) - 3.5) / 8 * way.width * 0.8
                bars.append([frame.globe(near + side * across),
                             frame.globe(far + side * across)])
            }
        }
        return bars
    }

    /// The touchdown zone markings and the aiming point, at both ends.
    ///
    /// The FAA's pattern for a precision runway, at 500ft steps from the threshold: three
    /// stripes a side, then the aiming point, then two, two, one, one. The stripes are 75ft
    /// by 6ft with 5ft between them and the aiming point is 150ft by 30ft, with the inner
    /// edges of both 72ft apart — laid out here in metres, which is what the plane is in.
    ///
    /// Only where there is room for it: a runway narrower than thirty metres or shorter than
    /// twelve hundred is not a precision runway and does not carry the paint, and no stripe
    /// goes past the middle, where it would meet the other end's.
    ///
    /// Measured along the runway's own line from each threshold, and each stripe square to
    /// the stretch of it the stripe covers. OpenStreetMap draws a runway through a node at
    /// every taxiway that crosses it, and never quite straight: laid out along the first
    /// stretch of the line instead, the pattern went wherever that stretch pointed, and ten
    /// metres of it three degrees out put Burbank's aiming point thirty-seven metres off the
    /// centreline. Four runways in ten were more than three metres off.
    static func touchdownZones(of way: Way, in frame: AirportFrame) -> [Paint] {
        let line = way.directions.map(frame.plane)
        guard line.count >= 2, way.width >= 30 else { return [] }
        let length = pathLength(line)
        guard length >= 1_200 else { return [] }

        // On a runway narrower than the forty-five metres the pattern is drawn for, the
        // whole of it is brought in towards the centreline so that it stays on the concrete.
        let squeeze = min(1, way.width / 45)
        let inner = 11 * squeeze
        let pattern: [(from: Double, stripes: Int)] = [
            (150, 3), (300, 0), (450, 2), (600, 2), (750, 1), (900, 1),
        ]

        var out: [Paint] = []
        for inwards in [line, Array(line.reversed())] {
            for mark in pattern {
                // Nought stripes means the aiming point.
                let long = mark.stripes == 0 ? 45.0 : 22.5
                guard mark.from + long <= length / 2 else { break }
                let (start, _) = walk(inwards, mark.from)
                let (end, _) = walk(inwards, mark.from + long)
                let run = end - start
                guard simd_length(run) > 1e-9 else { continue }
                let side = SIMD2(-run.y, run.x) / simd_length(run)

                var offsets: [(Double, Double)] = []
                if mark.stripes == 0 {
                    offsets = [(inner + 4.5 * squeeze, 9 * squeeze)]
                } else {
                    for stripe in 0..<mark.stripes {
                        offsets.append(((inner + 0.9 + Double(stripe) * 3.35) * squeeze,
                                        1.8 * squeeze))
                    }
                }
                for (out_, wide) in offsets {
                    for sign in [-1.0, 1.0] {
                        let shift = side * (out_ * sign)
                        out.append(Paint(line: [frame.globe(start + shift),
                                                frame.globe(end + shift)],
                                         width: wide))
                    }
                }
            }
        }
        return out
    }

    /// Each end's number, where it is painted: just past the piano keys, facing down the
    /// runway.
    ///
    /// Eighteen metres tall, which is the FAA's sixty feet, or less on a runway too narrow
    /// to take that — the figures have to fit across it with room either side.
    static func paintedNumbers(of way: Way, in frame: AirportFrame) -> [Painted] {
        let line = way.directions.map(frame.plane)
        guard line.count >= 2 else { return [] }
        let height = min(18, way.width * 0.45)
        guard height >= 4 else { return [] }

        var out: [Painted] = []
        for (number, threshold) in numbers(of: way) {
            let at = frame.plane(threshold)
            // Towards whichever end is not this one: into the runway.
            let other = simd_distance(at, line[0]) < simd_distance(at, line[line.count - 1])
                ? line[line.count - 1] : line[0]
            let along = other - at
            guard simd_length(along) > 1e-9 else { continue }
            let forward = simd_normalize(along)
            // Past the piano keys, which run from six metres to thirty-six, with six metres
            // of black between them and the foot of the figures.
            let middle = at + forward * (36 + 6 + height / 2)
            out.append(Painted(text: number,
                               centre: frame.globe(middle),
                               ahead: frame.globe(middle + forward * 10),
                               height: height))
        }
        return out
    }

    /// The centreline, held back from each threshold past the piano keys and the number.
    ///
    /// Twelve metres clear of the figures, which is roughly the FAA's forty feet; where no
    /// number is painted, just past the piano keys. A runway too short to leave anything
    /// between the two ends has no centreline.
    static func centreline(of way: Way, in frame: AirportFrame) -> [SIMD3<Double>] {
        let line = way.directions.map(frame.plane)
        guard line.count >= 2 else { return way.directions }
        let height = way.names.first?.height ?? 0
        let clear = height > 0 ? 36 + 6 + height + 12 : 42
        guard let from = trimmed(line, by: clear),
              let both = trimmed(Array(from.reversed()), by: clear)
        else { return [] }
        return both.reversed().map(frame.globe)
    }

    /// How long a line is, in metres along it.
    fileprivate static func pathLength(_ line: [SIMD2<Double>]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    /// The point so many metres along a line from its start, and the way the line runs
    /// there. Past the end, the end.
    fileprivate static func walk(_ line: [SIMD2<Double>], _ metres: Double)
    -> (SIMD2<Double>, SIMD2<Double>) {
        var left = metres
        for index in 0..<(line.count - 1) {
            let a = line[index], b = line[index + 1]
            let step = simd_distance(a, b)
            guard step > 1e-9 else { continue }
            let direction = (b - a) / step
            if step >= left { return (a + direction * left, direction) }
            left -= step
        }
        let last = line[line.count - 1], before = line[max(line.count - 2, 0)]
        let run = simd_distance(before, last)
        return (last, run > 1e-9 ? (last - before) / run : SIMD2(1, 0))
    }

    /// A line with its first so many metres taken off, or nothing if that is all of it.
    private static func trimmed(_ line: [SIMD2<Double>], by metres: Double) -> [SIMD2<Double>]? {
        var left = metres
        for index in 0..<(line.count - 1) {
            let a = line[index], b = line[index + 1]
            let step = simd_distance(a, b)
            if step > left {
                return [a + (b - a) * (left / step)] + Array(line[(index + 1)...])
            }
            left -= step
        }
        return nil
    }

    /// A runway's two numbers, each at the end it is painted on.
    ///
    /// "14L/32R" is two ends, and which is which is not a matter of taste: the 14 is painted
    /// where an aeroplane lines up to fly 140°, so it belongs at the end the way runs *from*
    /// on that heading.
    static func numbers(of way: Way) -> [(String, SIMD3<Double>)] {
        // "14L/32R" usually, "14L-32R" at some fields, and "18" alone for a runway used
        // one way only, which has one number painted at one end.
        let parts = way.ref.split(whereSeparator: { $0 == "/" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), let first = way.directions.first,
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
    /// Displaced thresholds, stopways and blast pads.
    let ends: [RunwayEnd]
    /// The paint on the ground, a line at a time. Only X-Plane's airport file has it.
    let markings: [Marking]
    /// Where it came from, and so who is credited for it.
    let source: Source
    /// The field's own plane, kept so anything worked out later is worked out on it.
    let frame: AirportFrame
    /// When it was fetched, so the panel can say how old it is.
    let fetched: Date
    /// Everything, for deciding whether any of it is on the sheet. Worked out once rather
    /// than on every tile that asks, which is every tile.
    let cap: SphericalCap

    init(icao: String, runways: [Way], taxiways: [Way], aprons: [Area], pavement: [Pavement],
         stands: [Stand], holds: [Hold], ends: [RunwayEnd], frame: AirportFrame, fetched: Date,
         markings: [Marking] = [], source: Source = .openStreetMap) {
        self.icao = icao
        self.runways = runways
        self.taxiways = taxiways
        self.aprons = aprons
        self.pavement = pavement
        self.stands = stands
        self.holds = holds
        self.ends = ends
        self.markings = markings
        self.source = source
        self.frame = frame
        self.fetched = fetched
        var everything = runways.flatMap(\.directions) + taxiways.flatMap(\.directions)
        for piece in pavement { everything.append(contentsOf: piece.directions) }
        for marking in markings { everything.append(contentsOf: marking.directions) }
        cap = SphericalCap(everything.isEmpty ? [frame.centre] : everything)
    }

    var isEmpty: Bool { runways.isEmpty && taxiways.isEmpty && aprons.isEmpty }
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
    /// "X-Plane" or "OpenStreetMap". An airport can have one of each on disk, and the map
    /// draws X-Plane's.
    let source: String
    let runways: Int
    let taxiways: Int
    let aprons: Int
    /// How much of the pavement is a drawn outline rather than an inflated centreline.
    let outlines: Int
    /// Painted lines, which only X-Plane's layouts have.
    let markings: Int
    let stands: Int
    let holds: Int
    let bytes: Int
    let fetched: Date
    /// True when the map has it in hand, rather than only on disk.
    let loaded: Bool

    var id: String { source + icao }
}

/// Fetches airport layouts and keeps them.
///
/// From the X-Plane Scenery Gateway first, which has a whole airport's ground in one file and
/// answers in a second or two, and from OpenStreetMap's Overpass API where the Gateway has
/// nothing but runways. Both are free and shared, so one request goes at a time, what comes
/// back is written to disk, and nothing is asked for twice that need not be. The old taxi
/// router had a command-line tool do this and kept the app off the network entirely; an
/// airport you have zoomed into is a much better signal of what to fetch than a list you have
/// to remember to run — though the airports you have charts for can be fetched in one go.
@MainActor
final class AirportLayoutStore: ObservableObject {

    static let shared = AirportLayoutStore()

    @Published private(set) var layouts: [String: AirportLayout] = [:]
    /// Set while one is on its way, so the map can say so rather than looking broken.
    @Published private(set) var fetching: String?
    @Published private(set) var failure: String?
    /// A fetch of every airport you have charts for, while it runs and once it is done.
    @Published private(set) var bulk: Bulk?

    /// How far a fetch of many airports has got.
    struct Bulk: Equatable {
        let total: Int
        var done = 0
        /// Fetched this time.
        var added = 0
        /// On this Mac already.
        var already = 0
        /// Not on the Gateway, or there with nothing but its runways.
        var missing = 0
        var failed = 0
        var current: String?
        /// Why it stopped before the end, when it did.
        var stopped: String?

        var isRunning: Bool { done < total && stopped == nil }
    }

    private var refused: Set<String> = []
    /// Waiting their turn, in the order to ask. One thing at a time, always: both sources are
    /// free and shared, and a dozen requests at once would be rude and no faster.
    private var queued: [MapAirport] = []
    /// The flight's own fields, wanted whatever the map is showing.
    private var pinned: [MapAirport] = []
    /// Drawn from OpenStreetMap's copy, or from an X-Plane copy a month old, and worth asking
    /// the Gateway about once the queue is quiet. Once per airport per run.
    private var checks: [String] = []
    private var checked: Set<String> = []
    /// What a fetch of many airports still has to do.
    private var batch: [String] = []
    private var batchFailures = 0
    /// Layouts on disk from before the query asked for stopways and blast pads, waiting
    /// for those two to be fetched on their own. After any whole airport, so a top-up
    /// never holds up a field that has nothing at all yet; once per airport per run.
    private var topping: [MapAirport] = []
    private var toppedUp: Set<String> = []
    /// True while something is being read, fetched, checked or topped up.
    private var working = false

    /// The mirrors, in order. The main instance is the busiest.
    private static let endpoints = [
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass-api.de/api/interpreter",
        "https://overpass.osm.ch/api/interpreter",
    ]

    /// Where every layout is kept, each source in a folder of its own.
    nonisolated static var root: URL {
        #if DEBUG
        // A test copy of the app keeps its own, so that trying it out never touches yours.
        if let elsewhere = ProcessInfo.processInfo.environment["CHARTDESK_LAYOUTS"] {
            return URL(fileURLWithPath: elsewhere, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Chartdesk/layouts", isDirectory: true)
    }

    /// OpenStreetMap's.
    nonisolated static var directory: URL {
        // Second version of the query — the first had no stands or holding positions in it,
        // and an answer from it is not missing them, it simply never asked.
        //
        // The pavement outlines were added without a third version, which is a judgement
        // rather than an oversight. `area:aeroway` is on about one taxiway in a hundred
        // worldwide and on none at all at most large fields — Frankfurt has none, Heathrow
        // has one — so throwing away a cache that takes hours to rebuild would cost far
        // more than it returns. Delete the directory to refetch with the outlines.
        root.appendingPathComponent("v2", isDirectory: true)
    }

    nonisolated static func file(for icao: String) -> URL {
        directory.appendingPathComponent("\(icao.uppercased()).json")
    }

    /// Written into every answer saved from the query that asks for stopways and blast
    /// pads, so an answer from before it can be told apart. Overpass's own JSON has no
    /// room for a note like this, and an extra key at the top is ignored by everything
    /// that reads it.
    nonisolated static let completeKey = "chartdeskQuery"
    nonisolated static let completeness = 2

    nonisolated static func isComplete(_ data: Data) -> Bool {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (top[completeKey] as? Int ?? 0) >= completeness
    }

    nonisolated static func marked(_ data: Data) -> Data {
        guard var top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return data }
        top[completeKey] = completeness
        return (try? JSONSerialization.data(withJSONObject: top)) ?? data
    }

    nonisolated static let userAgent = "Chartdesk/1.1 (+https://github.com/georgeorge33/ChartDesk)"

    func layout(for icao: String) -> AirportLayout? { layouts[icao.uppercased()] }

    /// Every layout on this Mac, counted.
    ///
    /// Reads and parses the lot, which is a few milliseconds an airport — fine for a window
    /// somebody opened to look at the list, and not something to do on a frame. The set on
    /// disk is the honest answer to "what have I got": the map holds only what it has been
    /// close to since launch, and everything else is waiting in the cache.
    nonisolated static func inventory(loaded: [String: String]) -> [AirportLayoutSummary] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var found: [AirportLayoutSummary] = []

        func add(_ layout: AirportLayout, file: URL, bytes: Int) {
            let about = try? file.resourceValues(forKeys: Set(keys))
            found.append(AirportLayoutSummary(
                icao: layout.icao,
                name: WorldData.airport(layout.icao)?.name ?? "",
                source: layout.source.name,
                runways: layout.runways.count,
                taxiways: layout.taxiways.filter(\.isMovementArea).count,
                aprons: layout.aprons.count,
                outlines: layout.pavement.count,
                markings: layout.markings.count,
                stands: layout.stands.count,
                holds: layout.holds.count,
                bytes: about?.fileSize ?? bytes,
                fetched: about?.contentModificationDate ?? layout.fetched,
                loaded: loaded[layout.icao] == layout.source.name))
        }

        let osm = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        for file in osm where file.pathExtension == "json" {
            let icao = file.deletingPathExtension().lastPathComponent.uppercased()
            guard let data = try? Data(contentsOf: file),
                  let layout = parse(data, icao: icao) else { continue }
            add(layout, file: file, bytes: data.count)
        }
        let xplane = (try? manager.contentsOfDirectory(at: XPlaneGateway.directory,
                                                       includingPropertiesForKeys: keys)) ?? []
        for file in xplane where file.pathExtension == "dat" {
            let icao = file.deletingPathExtension().lastPathComponent.uppercased()
            guard let data = try? Data(contentsOf: file),
                  let layout = XPlaneGateway.drawn(from: data, icao: icao,
                                                   scenery: XPlaneGateway.note(for: icao)?.scenery ?? 0,
                                                   fetched: Date()) else { continue }
            add(layout, file: file, bytes: data.count)
        }
        return found.sorted { $0.taxiways > $1.taxiways }
    }

    /// The codes the map is holding, and whose copy of each, for the list to mark.
    var held: [String: String] { layouts.mapValues { $0.source.name } }

    /// Throws away every layout, on disk and in hand.
    ///
    /// These take a minute or two each to fetch from a shared service that is often busy —
    /// the whole of the United States is hours of asking — so nothing calls this on the
    /// app's behalf. It is here for when a layout has been fetched wrong, or the query has
    /// changed and the cached answers predate it, and the only fix is to ask again.
    ///
    /// Returns how many files went, so whatever asked can say so.
    @discardableResult
    func deleteAll() -> Int {
        let manager = FileManager.default
        var gone = 0
        let osm = (try? manager.contentsOfDirectory(at: Self.directory,
                                                    includingPropertiesForKeys: nil)) ?? []
        for file in osm where file.pathExtension == "json" {
            if (try? manager.removeItem(at: file)) != nil { gone += 1 }
        }
        // X-Plane's airport files, and the notes beside them of what was asked when — which
        // go too, or an airport would be remembered as fetched with nothing on the disk.
        let xplane = (try? manager.contentsOfDirectory(at: XPlaneGateway.directory,
                                                       includingPropertiesForKeys: nil)) ?? []
        for file in xplane where file.pathExtension == "dat" || file.pathExtension == "json" {
            let removed = (try? manager.removeItem(at: file)) != nil
            if removed, file.pathExtension == "dat" { gone += 1 }
        }

        // The map is holding some of them, and something refused earlier should be allowed
        // to be asked for again — otherwise emptying the cache would leave the app behaving
        // as though it were still full.
        layouts.removeAll()
        refused.removeAll()
        queued.removeAll()
        checks.removeAll()
        checked.removeAll()
        failure = nil
        return gone
    }

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

    /// The next thing to do, unless something is being done already: the airports the map
    /// wants first; then asking the Gateway about the ones drawn from older copies; then a
    /// fetch of many airports; and the stopways for old OpenStreetMap layouts last of all.
    private func start() {
        guard !working else { return }
        if !queued.isEmpty { return next() }
        if !checks.isEmpty { return check() }
        if !batch.isEmpty { return fetchNextOfBatch() }
        topUp()
    }

    /// The next airport the map wants, from the disk if it is there and the network if not.
    /// Read off the main thread either way: X-Plane's Logan is twenty-five thousand lines.
    private func next() {
        let airport = queued.removeFirst()
        let icao = airport.icao.uppercased()
        guard !isHeld(icao) else { return start() }
        working = true
        let where_ = airport.coordinate
        Task.detached(priority: .userInitiated) {
            let found = await Self.obtain(icao: icao, at: where_) {
                await MainActor.run { self.fetching = icao }
            }
            await MainActor.run {
                self.fetching = nil
                self.working = false
                switch found.answer {
                case .arrived(let layout):
                    self.failure = nil
                    self.layouts[icao] = layout
                case .refused(let problem):
                    // Once per run per airport: Overpass is busy often enough that asking
                    // again on every frame would be rude as well as pointless.
                    self.refused.insert(icao)
                    self.failure = problem
                }
                if found.askGateway, !self.checked.contains(icao) { self.checks.append(icao) }
                // Drawn as it is straight away, and its stopways asked for when the queue
                // is quiet.
                if found.topUp, !self.toppedUp.contains(icao) { self.topping.append(airport) }
                self.start()
            }
        }
    }

    /// What `next` found for an airport, and what is worth doing about it later.
    struct Obtained {
        var answer: Answer
        /// Drawn from a copy the Gateway may have something better than.
        var askGateway = false
        /// An OpenStreetMap layout from before the query asked for stopways.
        var topUp = false
    }

    /// One airport, from wherever it is soonest had: X-Plane's copy on this Mac, then
    /// OpenStreetMap's, then the Gateway, and Overpass when the Gateway has nothing.
    ///
    /// An OpenStreetMap copy is drawn straight away even where the Gateway might have
    /// better, and the Gateway asked afterwards: something now beats something better in
    /// two seconds, and an airport drawn the old way is still an airport.
    nonisolated static func obtain(icao: String, at where_: Coordinate,
                                   announce: @Sendable () async -> Void) async -> Obtained {
        let note = XPlaneGateway.note(for: icao)
        if note?.status == .layout, let layout = XPlaneGateway.cached(icao) {
            return Obtained(answer: .arrived(layout), askGateway: note?.isStale ?? false)
        }
        // Asked lately and told there is nothing better: OpenStreetMap's it is.
        let settled = note.map { $0.status != .layout && !$0.isStale } ?? false
        if let onDisk = try? Data(contentsOf: file(for: icao)),
           let layout = parse(onDisk, icao: icao) {
            return Obtained(answer: .arrived(layout), askGateway: !settled,
                            topUp: !isComplete(onDisk))
        }
        await announce()
        if !settled, case .layout(let layout, _) = await XPlaneGateway.refresh(icao) {
            return Obtained(answer: .arrived(layout))
        }
        return Obtained(answer: await fetch(icao: icao, at: where_))
    }

    /// Asks the Gateway about one airport drawn from an older copy, and draws its layout
    /// instead if it has a better one.
    private func check() {
        let icao = checks.removeFirst()
        guard checked.insert(icao).inserted else { return start() }
        working = true
        Task.detached(priority: .utility) {
            let outcome = await XPlaneGateway.refresh(icao)
            await MainActor.run {
                self.working = false
                if case .layout(let layout, let changed) = outcome, let drawn = self.layouts[icao],
                   changed || !drawn.source.isXPlane {
                    self.layouts[icao] = layout
                }
                self.start()
            }
        }
    }

    /// Every one of these airports from the Gateway, one after another, so they are on this
    /// Mac before the map wants them.
    ///
    /// From the Gateway only. An airport it has nothing for is left to be asked of Overpass
    /// when the map wants it, as before: a list of Overpass queries at a minute or two each
    /// would be hours of a shared server's time, which is not a button's to spend.
    func fetchLayouts(for codes: [String]) {
        guard !(bulk?.isRunning ?? false) else { return }
        var seen = Set<String>()
        let wanted = codes.map { $0.uppercased() }.filter { code in
            !code.isEmpty && code.count <= 8 && code != Airport.unsortedCode
                && seen.insert(code).inserted
        }
        guard !wanted.isEmpty else { return }
        batch = wanted
        batchFailures = 0
        bulk = Bulk(total: wanted.count)
        start()
    }

    func stopFetchingLayouts() {
        guard var progress = bulk, progress.isRunning else { return }
        batch.removeAll()
        progress.stopped = "Stopped"
        progress.current = nil
        bulk = progress
    }

    private func fetchNextOfBatch() {
        let icao = batch.removeFirst()
        bulk?.current = icao
        working = true
        Task.detached(priority: .utility) {
            let note = XPlaneGateway.note(for: icao)
            let answered = note.map {
                !$0.isStale && ($0.status != .layout || XPlaneGateway.has(icao))
            } ?? false
            let outcome: XPlaneGateway.Outcome?
            if answered {
                outcome = nil
            } else {
                outcome = await XPlaneGateway.refresh(icao)
                // A breath between airports: the Gateway is free, and asks to be treated
                // considerately.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await MainActor.run {
                self.working = false
                self.count(icao, note: note, outcome: outcome)
                self.start()
            }
        }
    }

    private func count(_ icao: String, note: XPlaneGateway.Note?, outcome: XPlaneGateway.Outcome?) {
        guard var progress = bulk else { return }
        progress.done += 1
        progress.current = nil
        switch outcome {
        case nil:
            if note?.status == .layout { progress.already += 1 } else { progress.missing += 1 }
            batchFailures = 0
        case .layout(let layout, let changed)?:
            if changed { progress.added += 1 } else { progress.already += 1 }
            // On the map already, from an older copy: drawn from this one now.
            if let drawn = layouts[icao], changed || !drawn.source.isXPlane {
                layouts[icao] = layout
            }
            batchFailures = 0
        case .absent?:
            progress.missing += 1
            batchFailures = 0
        case .failed(let problem)?:
            progress.failed += 1
            batchFailures += 1
            // Three in a row is the network or the server, not the airports.
            if batchFailures >= 3 {
                batch.removeAll()
                progress.stopped = problem
            }
        }
        bulk = progress
    }

    /// The next layout that is missing its stopways and blast pads, if any.
    private func topUp() {
        guard !topping.isEmpty else { return }
        let airport = topping.removeFirst()
        let icao = airport.icao.uppercased()
        // Not for one drawn from X-Plane's copy by now: its pads came with it.
        guard toppedUp.insert(icao).inserted, layouts[icao]?.source == .openStreetMap else {
            return topUp()
        }
        working = true
        let where_ = airport.coordinate
        Task.detached(priority: .utility) {
            let merged = await Self.fetchEnds(icao: icao, at: where_)
            await MainActor.run {
                self.working = false
                if let merged, let layout = Self.parse(merged, icao: icao),
                   self.layouts[icao]?.source == .openStreetMap {
                    self.layouts[icao] = layout
                }
                self.start()
            }
        }
    }

    /// Stopways and blast pads for a layout saved before the query asked for them,
    /// merged into what is on disk and written back marked complete.
    ///
    /// Those two tags rather than the whole airport again. Nothing else in the answer has
    /// changed, and asking a free, shared server for every taxiway on a field to find its
    /// four stopways is minutes of its time for seconds of news. An airport with none is
    /// marked complete all the same, so it is not asked again.
    private static func fetchEnds(icao: String, at where_: Coordinate) async -> Data? {
        guard let onDisk = try? Data(contentsOf: file(for: icao)),
              var top = try? JSONSerialization.jsonObject(with: onDisk) as? [String: Any],
              let elements = top["elements"] as? [[String: Any]]
        else { return nil }
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = endsQuery(icao: icao, at: where_).data(using: .utf8)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  remark(in: data) == nil,
                  let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let found = answer["elements"] as? [[String: Any]]
            else { continue }
            // An empty answer is only news if the server knows the field. The Swiss mirror
            // holds Switzerland and answers everywhere else with a perfectly good nothing,
            // which taken at its word would mark Heathrow as having no stopways for good.
            // So the aerodrome comes back too, and an answer with neither it nor a stopway
            // in it proves nothing and is not kept.
            let ends = found.filter {
                (($0["tags"] as? [String: Any])?["aeroway"] as? String) != "aerodrome"
            }
            guard ends.count < found.count || !ends.isEmpty else { continue }
            top["elements"] = elements + ends
            top[completeKey] = completeness
            guard let merged = try? JSONSerialization.data(withJSONObject: top) else { return nil }
            try? merged.write(to: file(for: icao), options: .atomic)
            return merged
        }
        return nil
    }

    /// Only the stopways and blast pads, for a layout that has everything else.
    nonisolated static func endsQuery(icao: String, at where_: Coordinate) -> String {
        let around = "(around:4000,\(figure(where_.latitude)),\(figure(where_.longitude)))"
        return """
        [out:json][timeout:60];
        (
          way["aeroway"="aerodrome"]["icao"="\(icao)"];
          relation["aeroway"="aerodrome"]["icao"="\(icao)"];
        )->.field;
        .field map_to_area->.apt;
        (
          way["aeroway"~"^(stopway|blast_pad)$"](area.apt);
          way["aeroway"~"^(stopway|blast_pad)$"]\(around);
        );
        out geom;
        .field out tags;
        """
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
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
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
                try? marked(data).write(to: file(for: icao))
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
          way["aeroway"~"^(runway|taxiway|taxilane|apron|stopway|blast_pad)$"](area.apt);
          way["aeroway"~"^(runway|taxiway|taxilane|apron|stopway|blast_pad)$"]\
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
        var displaced: [AirportLayout.Way] = []
        var pads: [AirportLayout.Way] = []
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

            // The ends of a runway that are not the runway proper. Kept apart before
            // anything is joined: a displaced threshold's stretch often carries no ref
            // and was drawn as a little runway of its own, piano keys at both ends, and
            // where it does carry the runway's ref it was chained on, which put the
            // threshold's paint at the end of the concrete instead of at the threshold.
            let role = tags["runway"] as? String
            let isPad = kind == "stopway" || kind == "blast_pad"
                || (kind == "runway" && (role == "stopway" || role == "blast_pad"))
            let isDisplaced = kind == "runway" && role == "displaced_threshold"
            if isPad || isDisplaced {
                guard outline == nil,
                      let geometry = element["geometry"] as? [[String: Any]] else { continue }
                let line: [SIMD3<Double>] = geometry.compactMap { point in
                    guard let latitude = point["lat"] as? Double,
                          let longitude = point["lon"] as? Double else { return nil }
                    return Coordinate(latitude: latitude, longitude: longitude).direction
                }
                guard line.count >= 2 else { continue }
                // No width of its own means the runway's, which is found when it is
                // matched to one.
                let width = (tags["width"] as? String).flatMap(metres) ?? 0
                let way = AirportLayout.Way(ref: ref, width: width, directions: line,
                                            cap: SphericalCap(line), surface: .runway)
                if isPad { pads.append(way) } else { displaced.append(way) }
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
            let way = AirportLayout.Way(ref: ref, width: width, directions: directions,
                                        cap: cap, surface: surface)
            if surface == .runway { runways.append(way) } else { taxiways.append(way) }
        }

        guard !(runways.isEmpty && taxiways.isEmpty && aprons.isEmpty) else { return nil }
        runways = joined(runways)

        // Everything after this point is worked out on the field's own plane, so the plane
        // comes first — from what is mapped, which is the field.
        let frame = AirportFrame(covering: runways.flatMap(\.directions)
                                    + taxiways.flatMap(\.directions))

        // Displaced stretches, chained where they were split, and any that meet no runway
        // taken back as runway.
        let found = attached(chained(displaced), to: runways, in: frame)
        let sections = found.attached
        if !found.orphans.isEmpty { runways = joined(runways + found.orphans) }

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
        let paved = runways.map { way -> AirportLayout.Way in
            let named = AirportLayout.Way(ref: way.ref, width: way.width,
                                          directions: way.directions, cap: way.cap,
                                          surface: way.surface,
                                          names: AirportLayout.paintedNumbers(of: way, in: frame))
            return AirportLayout.Way(ref: way.ref, width: way.width, directions: way.directions,
                                     cap: way.cap, surface: way.surface,
                                     paved: covered(way, runway: true),
                                     edges: AirportLayout.edges(of: way, in: frame),
                                     keys: AirportLayout.thresholdBars(of: way, in: frame),
                                     zones: AirportLayout.touchdownZones(of: way, in: frame),
                                     names: named.names,
                                     centreline: AirportLayout.centreline(of: named, in: frame))
        }
        let taxied = taxiways.map { way in
            AirportLayout.Way(ref: way.ref, width: way.width, directions: way.directions,
                              cap: way.cap, surface: way.surface,
                              paved: covered(way, runway: false))
        }

        let holds = bars(for: holdPoints, along: taxied + paved, in: frame)
        let ends = runwayEnds(displaced: sections, pads: pads, runways: runways, in: frame)
        return AirportLayout(icao: icao, runways: paved, taxiways: taxied,
                             aprons: aprons, pavement: pavement, stands: stands,
                             holds: holds, ends: ends, frame: frame, fetched: Date())
    }

    /// Each displaced threshold and pad, matched to the runway end it belongs to and
    /// painted.
    ///
    /// Matched by where it meets a runway: a displaced stretch shares the threshold's node
    /// with the runway proper, and a pad starts where the runway, or its displaced
    /// stretch, stops. One that meets nothing is left out — without knowing which end is
    /// the runway's, there is no knowing which way its arrows or chevrons point.
    nonisolated static func runwayEnds(displaced: [AirportLayout.Way],
                                       pads: [AirportLayout.Way],
                                       runways: [AirportLayout.Way],
                                       in frame: AirportFrame) -> [AirportLayout.RunwayEnd] {
        typealias End = (at: SIMD2<Double>, width: Double)
        var ends: [End] = []
        for way in runways {
            let line = way.directions.map(frame.plane)
            guard let first = line.first, let last = line.last, line.count >= 2 else { continue }
            ends.append((first, way.width))
            ends.append((last, way.width))
        }

        // Which of a way's two ends is within reach of one of these, and that one.
        func meeting(_ line: [SIMD2<Double>], _ ends: [End], within reach: Double)
        -> (end: End, first: Bool)? {
            guard let head = line.first, let tail = line.last else { return nil }
            var best: (end: End, first: Bool, distance: Double)?
            for end in ends {
                for (point, first) in [(head, true), (tail, false)] {
                    let distance = simd_distance(point, end.at)
                    if distance <= reach, distance < (best?.distance ?? .infinity) {
                        best = (end, first, distance)
                    }
                }
            }
            return best.map { ($0.end, $0.first) }
        }

        var out: [AirportLayout.RunwayEnd] = []
        var beyond: [End] = []   // the outer ends of displaced stretches, where a pad starts
        for way in displaced {
            let line = way.directions.map(frame.plane)
            guard let (end, first) = meeting(line, ends, within: 15) else { continue }
            // Running from the outer end to the threshold.
            let towards = first ? Array(line.reversed()) : line
            let width = way.width > 0 ? way.width : end.width
            out.append(displacedEnd(towards, width: width, in: frame))
            beyond.append((towards[0], width))
        }
        for way in pads {
            let line = way.directions.map(frame.plane)
            guard let (end, first) = meeting(line, ends + beyond, within: 30) else { continue }
            // Running from the runway's end outwards.
            let outwards = first ? line : Array(line.reversed())
            let width = way.width > 0 ? way.width : end.width
            out.append(padEnd(outwards, width: width, in: frame))
        }
        return out
    }

    /// A displaced threshold's stretch, painted the FAA's way: a threshold bar across the
    /// runway at the threshold, a row of arrowheads just before it, and arrows down the
    /// middle pointing at it where the centreline would be — a stretch you may roll on but
    /// not land on. `line` runs from the outer end to the threshold.
    nonisolated static func displacedEnd(_ line: [SIMD2<Double>], width: Double,
                                     in frame: AirportFrame) -> AirportLayout.RunwayEnd {
        let ring = band(line, width: width).map(frame.globe)
        let threshold = line[line.count - 1]
        let back = Array(line.reversed())
        let length = AirportLayout.pathLength(line)
        // Square to the way the stretch runs over its last thirty metres into the threshold,
        // not over its last segment, which can be a few metres long and a few degrees out.
        let (behind, _) = AirportLayout.walk(back, min(30, length))
        let run = threshold - behind
        let forward = simd_length(run) > 1e-9 ? simd_normalize(run)
                                              : simd_normalize(threshold - line[line.count - 2])
        let side = SIMD2(-forward.y, forward.x)
        let half = width / 2
        var marks: [AirportLayout.Paint] = []

        // The bar: three metres of white across the full width, on this side of the line.
        marks.append(AirportLayout.Paint(
            line: [frame.globe(threshold - forward * 1.5 - side * half),
                   frame.globe(threshold - forward * 1.5 + side * half)], width: 3))

        // A row of arrowheads, each a V pointing at the bar.
        let heads = max(2, Int(width * 0.8 / 11))
        for index in 0..<heads {
            let across = ((Double(index) + 0.5) / Double(heads) - 0.5) * width * 0.8
            let apex = threshold - forward * 6 + side * across
            for sign in [-1.0, 1.0] {
                marks.append(AirportLayout.Paint(
                    line: [frame.globe(apex - forward * 5 + side * (sign * 3.5)),
                           frame.globe(apex)], width: 0.9, least: 1.2))
            }
        }

        // Arrows down the middle, sixty metres apart, as long as there is room for a whole
        // one: a thirty-metre shaft and a head, pointing at the threshold.
        var tip = 30.0
        while tip + 30 <= length - 5 {
            let (at, away) = AirportLayout.walk(back, tip)
            let towards = -away
            let across = SIMD2(-towards.y, towards.x)
            marks.append(AirportLayout.Paint(line: [frame.globe(at - towards * 30),
                                                    frame.globe(at)], width: 0.9, least: 1.6))
            for sign in [-1.0, 1.0] {
                marks.append(AirportLayout.Paint(
                    line: [frame.globe(at - towards * 6 + across * (sign * 2.5)),
                           frame.globe(at)], width: 0.9, least: 1.6))
            }
            tip += 60
        }
        return AirportLayout.RunwayEnd(kind: .displaced, outline: ring, marks: marks,
                                       cap: SphericalCap(ring))
    }

    /// A stopway or a blast pad: the concrete, and yellow chevrons every thirty metres
    /// pointing back at the runway, their arms running out to the edges at forty-five
    /// degrees. `line` runs from the runway's end outwards.
    nonisolated static func padEnd(_ line: [SIMD2<Double>], width: Double,
                               in frame: AirportFrame) -> AirportLayout.RunwayEnd {
        let ring = band(line, width: width).map(frame.globe)
        let half = width / 2
        let length = AirportLayout.pathLength(line)
        var marks: [AirportLayout.Paint] = []
        var apex = 15.0
        while apex < length {
            let (at, outwards) = AirportLayout.walk(line, apex)
            let side = SIMD2(-outwards.y, outwards.x)
            for sign in [-1.0, 1.0] {
                // Past the far end of a short pad, which the drawing clips to its concrete.
                marks.append(AirportLayout.Paint(
                    line: [frame.globe(at),
                           frame.globe(at + outwards * half + side * (sign * half))],
                    width: 0.9, least: 1.2))
            }
            apex += 30
        }
        return AirportLayout.RunwayEnd(kind: .pad, outline: ring, marks: marks,
                                       cap: SphericalCap(ring))
    }

    /// A line on the plane widened into a closed ring, half the width either side.
    nonisolated private static func band(_ line: [SIMD2<Double>], width: Double) -> [SIMD2<Double>] {
        let half = width / 2
        var left: [SIMD2<Double>] = [], right: [SIMD2<Double>] = []
        for (index, at) in line.enumerated() {
            let before = index > 0 ? line[index - 1] : at
            let after = index < line.count - 1 ? line[index + 1] : at
            let along = after - before
            guard simd_length(along) > 1e-9 else { continue }
            let forward = simd_normalize(along)
            let sideways = SIMD2(-forward.y, forward.x) * half
            left.append(at - sideways)
            right.append(at + sideways)
        }
        return left + right.reversed()
    }

    /// Ways that meet end to end, chained into one line each, whatever their refs.
    ///
    /// For displaced stretches, which OpenStreetMap splits wherever a taxiway crosses and
    /// which often carry no ref to group them by: two pieces of one stretch are one
    /// stretch, with one threshold bar, not two.
    nonisolated static func chained(_ ways: [AirportLayout.Way]) -> [AirportLayout.Way] {
        joined(ways.map { way in
            AirportLayout.Way(ref: "\u{0}", width: way.width, directions: way.directions,
                              cap: way.cap, surface: way.surface)
        }).map { chain in
            // Its own pieces' ref and width, not the whole airport's: every piece went in
            // under one ref to be chained, so the chain's width is the widest stretch on
            // the field, and a stretch on a thirty-metre runway would be drawn at forty-six.
            let pieces = ways.filter { chain.directions.contains($0.directions[0]) }
            return AirportLayout.Way(ref: pieces.first { !$0.ref.isEmpty }?.ref ?? "",
                                     width: pieces.map(\.width).max() ?? 0,
                                     directions: chain.directions, cap: chain.cap,
                                     surface: chain.surface)
        }
    }

    /// Displaced stretches that meet a runway end, and those that meet none.
    ///
    /// The ones that meet none are runway. Some fields are mapped with every piece of a
    /// runway tagged as displaced threshold and no runway proper at all — Kennedy's 13L/31R,
    /// Newark's 4L/22R, two of Las Vegas's — and leaving those out would take the runway
    /// off the map; drawn as runway, they are what they were before.
    nonisolated static func attached(_ sections: [AirportLayout.Way],
                                     to runways: [AirportLayout.Way],
                                     in frame: AirportFrame)
    -> (attached: [AirportLayout.Way], orphans: [AirportLayout.Way]) {
        let ends = runways.flatMap { way -> [SIMD2<Double>] in
            guard let first = way.directions.first, let last = way.directions.last else { return [] }
            return [frame.plane(first), frame.plane(last)]
        }
        var attached: [AirportLayout.Way] = [], orphans: [AirportLayout.Way] = []
        for section in sections {
            let tips = [section.directions.first, section.directions.last].compactMap { $0 }
                .map(frame.plane)
            let meets = tips.contains { tip in ends.contains { simd_distance($0, tip) <= 15 } }
            if meets { attached.append(section) } else { orphans.append(section) }
        }
        return (attached, orphans)
    }

    /// One runway, however many ways OpenStreetMap drew it as.
    ///
    /// A runway is very often mapped in pieces — Logan's 4R/22L is three, split where the
    /// other runways cross it — and every piece carries the whole runway's ref. Taken one
    /// at a time, each piece's ends looked like thresholds: piano keys and a touchdown zone
    /// were painted at every join, in the middle of the runway, and the numbers twice.
    ///
    /// So the pieces of one ref are chained end to end first, by the node they share, and
    /// everything that depends on where the thresholds are is worked out on the whole line.
    /// Pieces that do not meet stay apart, since a runway with a gap in it is two runways
    /// as far as the paint is concerned; ways with no ref are left as they are, because
    /// nothing says which runway they belong to.
    nonisolated static func joined(_ ways: [AirportLayout.Way]) -> [AirportLayout.Way] {
        var byRef: [String: [AirportLayout.Way]] = [:]
        var order: [String] = []
        var loose: [AirportLayout.Way] = []
        for way in ways {
            guard !way.ref.isEmpty else { loose.append(way); continue }
            if byRef[way.ref] == nil { order.append(way.ref) }
            byRef[way.ref, default: []].append(way)
        }

        // The same node, give or take the arithmetic: about a centimetre on the ground.
        func meet(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
            simd_distance_squared(a, b) < 2.5e-18
        }

        var out: [AirportLayout.Way] = []
        for ref in order {
            var pieces = byRef[ref] ?? []
            while !pieces.isEmpty {
                var chain = pieces.removeFirst().directions
                var grew = true
                while grew {
                    grew = false
                    for (index, piece) in pieces.enumerated() {
                        let line = piece.directions
                        guard let first = line.first, let last = line.last,
                              let head = chain.first, let tail = chain.last else { continue }
                        if meet(tail, first) {
                            chain += line.dropFirst()
                        } else if meet(tail, last) {
                            chain += line.reversed().dropFirst()
                        } else if meet(head, last) {
                            chain = Array(line.dropLast()) + chain
                        } else if meet(head, first) {
                            chain = Array(line.reversed().dropLast()) + chain
                        } else {
                            continue
                        }
                        pieces.remove(at: index)
                        grew = true
                        break
                    }
                }
                let widest = byRef[ref]?.map(\.width).max() ?? 0
                out.append(AirportLayout.Way(ref: ref, width: widest, directions: chain,
                                             cap: SphericalCap(chain), surface: .runway))
            }
        }
        return out + loose
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
