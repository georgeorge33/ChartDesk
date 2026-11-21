import Foundation
import simd

/// An airport's runways, taxiways, paint, holds and stands, as X-Plane's airport file has them.
///
/// The shapes a chart's ground layout is made of, which no bundled table has: the runway
/// table knows where a runway is and how long, and nothing at all about the taxiways beside
/// it. This is what turns the closest zoom from a rectangle on a field into somewhere you
/// can follow a taxi instruction.
///
/// Fetched from the X-Plane Scenery Gateway one airport at a time, and kept — an airport's
/// ground plan changes every few years, not every few minutes.
struct AirportLayout {

    /// A line down the middle of something you can taxi or land on.
    struct Way {
        /// "A", "B7", "14L/32R" — what the chart calls it, when the airport file says.
        let ref: String
        /// Metres: the runway's own width, and for a taxiway the width its wingspan letter
        /// allows.
        let width: Double
        let directions: [SIMD3<Double>]
        let cap: SphericalCap
        /// What it is. A taxiway is movement area and carries a painted centreline and a
        /// designator; a taxilane is the lead into a stand on the apron, which is pavement
        /// and nothing else.
        let surface: AirportSurface
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
             surface: AirportSurface,
             edges: [[SIMD3<Double>]] = [], keys: [[SIMD3<Double>]] = [],
             zones: [Paint] = [], names: [Painted] = [],
             centreline: [SIMD3<Double>] = []) {
            self.ref = ref
            self.width = width
            self.directions = directions
            self.cap = cap
            self.surface = surface
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

    /// A piece of pavement as its outline, the way an AMDB has it: the taxiway is a polygon
    /// and the yellow line down it a separate feature.
    struct Pavement {
        let surface: AirportSurface
        let directions: [SIMD3<Double>]
        let cap: SphericalCap
        /// Grass inside the concrete: X-Plane draws an apron round an island as one outline
        /// with a hole in it.
        var holes: [[SIMD3<Double>]] = []
    }

    /// A line painted on the ground: a centreline, an edge, a hold line, an apron's safety
    /// line, each the way it is painted.
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

    /// A stand, where an aeroplane parks.
    struct Stand {
        let ref: String
        let direction: SIMD3<Double>
    }

    /// Where you stop short of a runway, and the bar across the taxiway that says so: two
    /// points for a bar laid square across a route, more for a hold line followed the way it
    /// was painted.
    struct Hold {
        let direction: SIMD3<Double>
        let across: [SIMD3<Double>]
    }

    /// The two white lines painted down the sides of a runway.
    ///
    /// Worked out from the centreline and the width, which is all the airport file gives:
    /// X-Plane paints a runway itself, from the row that describes it. On the field's own plane this is what it sounds like: step half a width square to
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
    /// the stretch of it the stripe covers, so a runway drawn through more than its two ends
    /// is painted down its own line rather than along its first stretch — which, three
    /// degrees out over ten metres, once put Burbank's aiming point thirty-seven metres off
    /// the centreline.
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
    /// The pavement, outline by outline.
    let pavement: [Pavement]
    let stands: [Stand]
    let holds: [Hold]
    /// Displaced thresholds, stopways and blast pads.
    let ends: [RunwayEnd]
    /// The paint on the ground, a line at a time.
    let markings: [Marking]
    /// Which approved version of the airport on the Gateway this was drawn from.
    let scenery: Int
    /// The field's own plane, kept so anything worked out later is worked out on it.
    let frame: AirportFrame
    /// When it was fetched, so the panel can say how old it is.
    let fetched: Date
    /// Everything, for deciding whether any of it is on the sheet. Worked out once rather
    /// than on every tile that asks, which is every tile.
    let cap: SphericalCap

    init(icao: String, runways: [Way], taxiways: [Way], pavement: [Pavement], stands: [Stand],
         holds: [Hold], ends: [RunwayEnd], markings: [Marking], scenery: Int,
         frame: AirportFrame, fetched: Date) {
        self.icao = icao
        self.runways = runways
        self.taxiways = taxiways
        self.pavement = pavement
        self.stands = stands
        self.holds = holds
        self.ends = ends
        self.markings = markings
        self.scenery = scenery
        self.frame = frame
        self.fetched = fetched
        var everything = runways.flatMap(\.directions) + taxiways.flatMap(\.directions)
        for piece in pavement { everything.append(contentsOf: piece.directions) }
        for marking in markings { everything.append(contentsOf: marking.directions) }
        cap = SphericalCap(everything.isEmpty ? [frame.centre] : everything)
    }

    var isEmpty: Bool { runways.isEmpty && taxiways.isEmpty && pavement.isEmpty }
}

/// What a way is.
enum AirportSurface: String {
    case runway
    case taxiway
    case taxilane

    /// Metres, for a way whose width nothing says: a runway is 45 across at a field that
    /// takes jets, a taxiway 23, and a taxilane between stands 15.
    var width: Double {
        switch self {
        case .runway: return 45
        case .taxiway: return 23
        case .taxilane: return 15
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
    /// Pieces of pavement.
    let outlines: Int
    /// Painted lines.
    let markings: Int
    let stands: Int
    let holds: Int
    let bytes: Int
    let fetched: Date
    /// True when the map has it in hand, rather than only on disk.
    let loaded: Bool

    var id: String { icao }
}


// MARK: - The ends of a runway that are not the runway proper

extension AirportLayout {

    /// A displaced threshold's stretch, painted the FAA's way: a threshold bar across the
    /// runway at the threshold, a row of arrowheads just before it, and arrows down the
    /// middle pointing at it where the centreline would be — a stretch you may roll on but
    /// not land on. `line` runs from the outer end to the threshold.
    static func displacedEnd(_ line: [SIMD2<Double>], width: Double,
                                     in frame: AirportFrame) -> RunwayEnd {
        let ring = band(line, width: width).map(frame.globe)
        let threshold = line[line.count - 1]
        let back = Array(line.reversed())
        let length = pathLength(line)
        // Square to the way the stretch runs over its last thirty metres into the threshold,
        // not over its last segment, which can be a few metres long and a few degrees out.
        let (behind, _) = walk(back, min(30, length))
        let run = threshold - behind
        let forward = simd_length(run) > 1e-9 ? simd_normalize(run)
                                              : simd_normalize(threshold - line[line.count - 2])
        let side = SIMD2(-forward.y, forward.x)
        let half = width / 2
        var marks: [Paint] = []

        // The bar: three metres of white across the full width, on this side of the line.
        marks.append(Paint(
            line: [frame.globe(threshold - forward * 1.5 - side * half),
                   frame.globe(threshold - forward * 1.5 + side * half)], width: 3))

        // A row of arrowheads, each a V pointing at the bar.
        let heads = max(2, Int(width * 0.8 / 11))
        for index in 0..<heads {
            let across = ((Double(index) + 0.5) / Double(heads) - 0.5) * width * 0.8
            let apex = threshold - forward * 6 + side * across
            for sign in [-1.0, 1.0] {
                marks.append(Paint(
                    line: [frame.globe(apex - forward * 5 + side * (sign * 3.5)),
                           frame.globe(apex)], width: 0.9, least: 1.2))
            }
        }

        // Arrows down the middle, sixty metres apart, as long as there is room for a whole
        // one: a thirty-metre shaft and a head, pointing at the threshold.
        var tip = 30.0
        while tip + 30 <= length - 5 {
            let (at, away) = walk(back, tip)
            let towards = -away
            let across = SIMD2(-towards.y, towards.x)
            marks.append(Paint(line: [frame.globe(at - towards * 30),
                                                    frame.globe(at)], width: 0.9, least: 1.6))
            for sign in [-1.0, 1.0] {
                marks.append(Paint(
                    line: [frame.globe(at - towards * 6 + across * (sign * 2.5)),
                           frame.globe(at)], width: 0.9, least: 1.6))
            }
            tip += 60
        }
        return RunwayEnd(kind: .displaced, outline: ring, marks: marks,
                                       cap: SphericalCap(ring))
    }

    /// A stopway or a blast pad: the concrete, and yellow chevrons every thirty metres
    /// pointing back at the runway, their arms running out to the edges at forty-five
    /// degrees. `line` runs from the runway's end outwards.
    static func padEnd(_ line: [SIMD2<Double>], width: Double,
                               in frame: AirportFrame) -> RunwayEnd {
        let ring = band(line, width: width).map(frame.globe)
        let half = width / 2
        let length = pathLength(line)
        var marks: [Paint] = []
        var apex = 15.0
        while apex < length {
            let (at, outwards) = walk(line, apex)
            let side = SIMD2(-outwards.y, outwards.x)
            for sign in [-1.0, 1.0] {
                // Past the far end of a short pad, which the drawing clips to its concrete.
                marks.append(Paint(
                    line: [frame.globe(at),
                           frame.globe(at + outwards * half + side * (sign * half))],
                    width: 0.9, least: 1.2))
            }
            apex += 30
        }
        return RunwayEnd(kind: .pad, outline: ring, marks: marks,
                                       cap: SphericalCap(ring))
    }

    /// A line on the plane widened into a closed ring, half the width either side.
    private static func band(_ line: [SIMD2<Double>], width: Double) -> [SIMD2<Double>] {
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

}

/// Fetches airport layouts from the X-Plane Scenery Gateway and keeps them.
///
/// The Gateway is free and asks only that its server be treated considerately, so this asks
/// for one airport at a time, writes what comes back to disk, and asks about it again only a
/// month later. An airport you have zoomed into is a much better signal of what to fetch than
/// a list you have to remember to run — though the airports you have charts for can be
/// fetched in one go. An airport the Gateway has nothing for is drawn the way every airport is
/// from further out: its runways, from the bundled table.
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

    /// Asked about in this run and with nothing to draw: not on the Gateway, or not answered.
    private var refused: Set<String> = []
    /// Waiting their turn, in the order to ask. One thing at a time, always: the Gateway is
    /// free and shared, and a dozen requests at once would be rude and no faster.
    private var queued: [MapAirport] = []
    /// The flight's own fields, wanted whatever the map is showing.
    private var pinned: [MapAirport] = []
    /// Drawn from a copy a month old, and worth asking the Gateway about once the queue is
    /// quiet. Once per airport per run.
    private var checks: [String] = []
    private var checked: Set<String> = []
    /// What a fetch of many airports still has to do.
    private var batch: [String] = []
    private var batchFailures = 0
    /// True while something is being read, fetched or checked.
    private var working = false

    private init() {
        Task.detached(priority: .utility) { Self.removeOldLayouts() }
    }

    /// Where the layouts are kept.
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
        // And the test copy keeps its own however it is opened: it is newer than the app you
        // fly with, and takes away the old OpenStreetMap layouts that one may still be drawing.
        let folder = Bundle.main.isTestCopy ? "Chartdesk Testbed/layouts" : "Chartdesk/layouts"
        return support.appendingPathComponent(folder, isDirectory: true)
    }

    /// What this app fetched from OpenStreetMap before it had X-Plane's: the folder `v2`,
    /// and the first version's files loose beside it. Nothing reads either any more, so the
    /// first launch that finds them takes them away.
    nonisolated static func removeOldLayouts() {
        let manager = FileManager.default
        let old = root.appendingPathComponent("v2", isDirectory: true)
        if manager.fileExists(atPath: old.path) { try? manager.removeItem(at: old) }
        let loose = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in loose where file.pathExtension == "json" {
            try? manager.removeItem(at: file)
        }
    }

    nonisolated static let userAgent = "Chartdesk/1.1 (+https://github.com/georgeorge33/ChartDesk)"

    func layout(for icao: String) -> AirportLayout? { layouts[icao.uppercased()] }

    /// Every layout on this Mac, counted.
    ///
    /// Reads and parses the lot, which is a few milliseconds an airport — fine for a window
    /// somebody opened to look at the list, and not something to do on a frame. The set on
    /// disk is the honest answer to "what have I got": the map holds only what it has been
    /// close to since launch, and everything else is waiting in the cache.
    nonisolated static func inventory(loaded: Set<String>) -> [AirportLayoutSummary] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? manager.contentsOfDirectory(at: XPlaneGateway.directory,
                                                      includingPropertiesForKeys: keys)) ?? []
        var found: [AirportLayoutSummary] = []
        for file in files where file.pathExtension == "dat" {
            let icao = file.deletingPathExtension().lastPathComponent.uppercased()
            guard let data = try? Data(contentsOf: file),
                  let layout = XPlaneGateway.drawn(from: data, icao: icao,
                                                   scenery: XPlaneGateway.note(for: icao)?.scenery ?? 0,
                                                   fetched: Date()) else { continue }
            let about = try? file.resourceValues(forKeys: Set(keys))
            found.append(AirportLayoutSummary(
                icao: icao,
                name: WorldData.airport(icao)?.name ?? "",
                runways: layout.runways.count,
                taxiways: layout.taxiways.filter(\.isMovementArea).count,
                outlines: layout.pavement.count,
                markings: layout.markings.count,
                stands: layout.stands.count,
                holds: layout.holds.count,
                bytes: about?.fileSize ?? data.count,
                fetched: about?.contentModificationDate ?? layout.fetched,
                loaded: loaded.contains(icao)))
        }
        return found.sorted { $0.taxiways > $1.taxiways }
    }

    /// The codes the map is holding, for the list to mark.
    var held: Set<String> { Set(layouts.keys) }

    /// Throws away every layout, on disk and in hand.
    ///
    /// They come back from the Gateway a second or two each as you zoom in on a field, so
    /// this costs little; it is here for when a layout has been fetched wrong.
    ///
    /// Returns how many airports went, so whatever asked can say so.
    @discardableResult
    func deleteAll() -> Int {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: XPlaneGateway.directory,
                                                      includingPropertiesForKeys: nil)) ?? []
        var gone = 0
        // The airport files, and the notes beside them of what was asked when — which go
        // too, or an airport would be remembered as fetched with nothing on the disk.
        for file in files where file.pathExtension == "dat" || file.pathExtension == "json" {
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

    /// True when this one was asked for and had nothing, so nothing keeps promising it.
    func hasRefused(_ icao: String) -> Bool { refused.contains(icao.uppercased()) }

    /// How many are still waiting their turn.
    var waiting: Int { queued.count }

    /// The fields the loaded flight uses. Fetched whatever the map is showing, and first.
    ///
    /// The one set of layouts you know you are going to want, because you are flying there.
    /// Asking for them when the plan loads means they are on the disk by the time you are on
    /// the ground.
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

    /// In hand already, or asked and had nothing: either way there is nothing to do.
    private func isHeld(_ icao: String) -> Bool {
        let icao = icao.uppercased()
        return layouts[icao] != nil || refused.contains(icao)
    }

    /// The next thing to do, unless something is being done already: the airports the map
    /// wants first, then asking about the ones drawn from a month-old copy, then a fetch of
    /// many airports.
    private func start() {
        guard !working else { return }
        if !queued.isEmpty { return next() }
        if !checks.isEmpty { return check() }
        if !batch.isEmpty { return fetchNextOfBatch() }
    }

    /// The next airport the map wants, from the disk if it is there and the Gateway if not.
    /// Read off the main thread either way: Logan's airport file is twenty-five thousand lines.
    private func next() {
        let airport = queued.removeFirst()
        let icao = airport.icao.uppercased()
        guard !isHeld(icao) else { return start() }
        working = true
        Task.detached(priority: .userInitiated) {
            let found = await Self.obtain(icao: icao) {
                await MainActor.run { self.fetching = icao }
            }
            await MainActor.run {
                self.fetching = nil
                self.working = false
                switch found.answer {
                case .arrived(let layout):
                    self.failure = nil
                    self.layouts[icao] = layout
                case .nothing:
                    // Its runways from the table, as from further out, and no more.
                    self.refused.insert(icao)
                case .refused(let problem):
                    // Once per run per airport, rather than on every frame the map is near it.
                    self.refused.insert(icao)
                    self.failure = problem
                }
                if found.recheck, !self.checked.contains(icao) { self.checks.append(icao) }
                self.start()
            }
        }
    }

    /// What came back for an airport, or why nothing did.
    enum Answer {
        case arrived(AirportLayout)
        /// The Gateway has nothing for it worth drawing.
        case nothing
        case refused(String)
    }

    /// What `next` found for an airport, and whether it is worth asking about again.
    struct Obtained {
        var answer: Answer
        /// Drawn from a copy a month old.
        var recheck = false
    }

    /// One airport: the copy on this Mac if it is here, and the Gateway if it is not.
    nonisolated static func obtain(icao: String,
                                   announce: @Sendable () async -> Void) async -> Obtained {
        let note = XPlaneGateway.note(for: icao)
        if note?.status == .layout, let layout = XPlaneGateway.cached(icao) {
            return Obtained(answer: .arrived(layout), recheck: note?.isStale ?? false)
        }
        // Asked lately and told there is nothing.
        if let note, note.status != .layout, !note.isStale {
            return Obtained(answer: .nothing)
        }
        await announce()
        switch await XPlaneGateway.refresh(icao) {
        case .layout(let layout, _): return Obtained(answer: .arrived(layout))
        case .absent: return Obtained(answer: .nothing)
        case .failed(let problem): return Obtained(answer: .refused(problem))
        }
    }

    /// Asks the Gateway about one airport drawn from a month-old copy, and draws the newer
    /// version instead if one has been approved since.
    private func check() {
        let icao = checks.removeFirst()
        guard checked.insert(icao).inserted else { return start() }
        working = true
        Task.detached(priority: .utility) {
            let outcome = await XPlaneGateway.refresh(icao)
            await MainActor.run {
                self.working = false
                if case .layout(let layout, let changed) = outcome, changed,
                   self.layouts[icao] != nil {
                    self.layouts[icao] = layout
                }
                self.start()
            }
        }
    }

    /// Every one of these airports from the Gateway, one after another, so they are on this
    /// Mac before the map wants them. One the Gateway has nothing for is counted, and drawn
    /// with its runways only.
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
            // Turned away earlier in this run, or on the map already from an older version.
            refused.remove(icao)
            if changed, layouts[icao] != nil { layouts[icao] = layout }
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
}
