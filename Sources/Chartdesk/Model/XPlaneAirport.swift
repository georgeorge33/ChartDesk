import Foundation
import simd

/// One airport as X-Plane's airport file has it.
///
/// The X-Plane Scenery Gateway is the airport database behind X-Plane: volunteers draw each
/// field in X-Plane's own airport editor, Laminar Research's moderators check it, and the
/// approved airports go out with the simulator and to anyone who asks the Gateway's API.
/// A simulator has to draw the ground and taxi its traffic round it, so the file holds what a
/// ground chart is made of and OpenStreetMap mostly does not: the pavement as outlines with
/// their curves, every painted line with its style, the taxi routes with their names and
/// which stretches of them are inside a runway's protected area, and the stands.
///
/// The format is `apt.dat`, a line of text per thing, each starting with a row code: 100 a
/// runway, 110 a piece of pavement, 120 a painted line, 111 to 116 the nodes of either, 1201
/// and 1202 the taxi routes, 1204 the runway zone a route is in, 1300 a stand. Only what the
/// map draws is read. The rest — frequencies, signs, the runway-use rules — stays in the file.
struct XPlaneAirport {

    struct End {
        let name: String
        let at: SIMD3<Double>
        /// Metres of runway before the threshold: rolled on, not landed on.
        let displaced: Double
        /// Metres of overrun or blast pad beyond the end, which is not runway at all.
        let pad: Double
    }

    struct Runway {
        let width: Double
        let first: End
        let second: End
    }

    /// A node of a drawn outline or line: where it is, the curve handle X-Plane's editor gave
    /// it if any, and the paint and the lights on the stretch that leaves it.
    struct Node {
        let at: SIMD3<Double>
        let handle: SIMD3<Double>?
        let line: Int
        let light: Int
    }

    struct Chain {
        var nodes: [Node]
        var closed: Bool
    }

    struct Edge {
        let from: Int
        let to: Int
        let runway: Bool
        /// ICAO's wingspan letter, A to F, for the widest aeroplane allowed on it.
        let size: Character?
        let name: String
        /// Inside a runway's protected area for arrivals or departures, which is what
        /// X-Plane's own controllers hold traffic short of.
        var inRunwayZone = false
    }

    struct Stand {
        let at: SIMD3<Double>
        let name: String
    }

    let icao: String
    var runways: [Runway] = []
    /// Each piece of pavement as its outline, then any holes in it.
    var pavements: [[Chain]] = []
    var lines: [Chain] = []
    var nodes: [Int: SIMD3<Double>] = [:]
    var edges: [Edge] = []
    var stands: [Stand] = []

    /// Worth drawing in place of OpenStreetMap: something on the ground besides the runways.
    /// Thousands of the Gateway's small fields are a runway and nothing else.
    var isUsable: Bool {
        !runways.isEmpty && (!edges.isEmpty || !pavements.isEmpty || !lines.isEmpty)
    }

    private enum Holder { case none, pavement, line, boundary }

    /// The airport with this code in an airport file, or the first airport in it when none
    /// has the code; nil when there is no airport in it at all.
    static func read(_ text: String, icao: String) -> XPlaneAirport? {
        let wanted = icao.uppercased()
        var airport = XPlaneAirport(icao: wanted)
        var holder = Holder.none
        var pending: [Node] = []
        var rings: [Chain] = []
        var reading = false
        var found = false
        var matched = false

        func finishChain(_ closed: Bool) {
            guard !pending.isEmpty else { return }
            let chain = Chain(nodes: pending, closed: closed)
            switch holder {
            case .line: airport.lines.append(chain)
            case .pavement: rings.append(chain)
            case .boundary, .none: break
            }
            pending = []
        }
        func finishShape() {
            if !pending.isEmpty { finishChain(false) }
            if holder == .pavement, !rings.isEmpty { airport.pavements.append(rings) }
            rings = []
            holder = .none
        }

        for row in text.split(whereSeparator: \.isNewline) {
            let fields = row.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = fields.first, let code = Int(head) else { continue }
            func number(_ index: Int) -> Double {
                index < fields.count ? Double(fields[index]) ?? 0 : 0
            }
            func place(_ latitude: Int) -> SIMD3<Double> {
                Coordinate(latitude: number(latitude), longitude: number(latitude + 1)).direction
            }

            // An airport's first row: 1 for a land airport, 16 a seaplane base, 17 a heliport.
            if code == 1 || code == 16 || code == 17 {
                finishShape()
                if matched { break }
                let ident = fields.count > 4 ? fields[4].uppercased() : ""
                if !found || ident == wanted {
                    airport = XPlaneAirport(icao: wanted)
                    found = true
                    matched = ident == wanted
                    reading = true
                } else {
                    reading = false
                }
                continue
            }
            guard reading else { continue }

            switch code {
            case 110:
                finishShape()
                holder = .pavement
            case 120:
                finishShape()
                holder = .line
            case 130:
                finishShape()
                holder = .boundary
            case 111...116:
                guard holder != .none else { continue }
                let curved = code == 112 || code == 114 || code == 116
                var line = 0, light = 0
                for field in fields.dropFirst(curved ? 5 : 3) {
                    guard let value = Int(field) else { continue }
                    if value >= 100 { light = value } else { line = value }
                }
                pending.append(Node(at: place(1), handle: curved ? place(3) : nil,
                                    line: line, light: light))
                if code == 113 || code == 114 {
                    finishChain(true)
                    if holder == .line { holder = .none }
                } else if code == 115 || code == 116 {
                    finishChain(false)
                    if holder == .line { holder = .none }
                }
            default:
                finishShape()
                switch code {
                case 100 where fields.count >= 26:
                    // A runway on water is a seaplane lane, and drawn as tarmac it is a grey
                    // strip across a lake.
                    guard Int(fields[2]) != 13 else { break }
                    let first = End(name: String(fields[8]), at: place(9),
                                    displaced: number(11), pad: number(12))
                    let second = End(name: String(fields[17]), at: place(18),
                                     displaced: number(20), pad: number(21))
                    airport.runways.append(Runway(width: number(1), first: first, second: second))
                case 1201 where fields.count >= 5:
                    if let id = Int(fields[4]) { airport.nodes[id] = place(1) }
                case 1202 where fields.count >= 5:
                    let kind = fields[4].lowercased()
                    let size: Character? = kind.hasPrefix("taxiway_") && kind.count == 9
                        ? kind.last.flatMap { $0.uppercased().first } : nil
                    let name = fields.count > 5 ? fields[5...].joined(separator: " ") : ""
                    airport.edges.append(Edge(from: Int(fields[1]) ?? -1, to: Int(fields[2]) ?? -1,
                                              runway: kind == "runway", size: size,
                                              name: name.trimmingCharacters(in: .whitespaces)))
                case 1204 where fields.count >= 2:
                    // "ils" is the ILS critical area, further out; the hold for the runway
                    // itself is where the arrival and departure zones start.
                    if !airport.edges.isEmpty, fields[1] == "arrival" || fields[1] == "departure" {
                        airport.edges[airport.edges.count - 1].inRunwayZone = true
                    }
                case 1300 where fields.count >= 7:
                    airport.stands.append(Stand(at: place(1),
                                                name: fields[6...].joined(separator: " ")))
                default:
                    break
                }
            }
        }
        finishShape()
        return found ? airport : nil
    }
}

// MARK: - Into a layout

extension XPlaneAirport {

    /// Drawn the way the map draws an airport, or nil if there is nothing on its ground.
    ///
    /// The runway is built from its two ends and drawn exactly as an OpenStreetMap one is —
    /// the same piano keys, touchdown zone, numbers and centreline — with its displaced
    /// thresholds and blast pads from the figures the file gives. Everything else is what the
    /// file has and OpenStreetMap does not: the paint, the holds, the routes' names.
    func layout(scenery: Int, fetched: Date) -> AirportLayout? {
        guard isUsable else { return nil }
        var anchors: [SIMD3<Double>] = []
        for runway in runways {
            anchors.append(runway.first.at)
            anchors.append(runway.second.at)
        }
        anchors.append(contentsOf: nodes.values)
        let frame = AirportFrame(covering: anchors)

        var ways: [AirportLayout.Way] = []
        var ends: [AirportLayout.RunwayEnd] = []
        for runway in runways {
            let made = Self.runway(runway, at: icao, in: frame)
            if let way = made.way { ways.append(way) }
            ends.append(contentsOf: made.ends)
        }
        let painted = Self.markings(of: lines + pavements.flatMap { $0 }, in: frame)
        return AirportLayout(icao: icao, runways: ways,
                             taxiways: Self.taxiways(edges: edges, nodes: nodes),
                             aprons: [],
                             pavement: Self.pavement(pavements, in: frame),
                             stands: Self.stands(stands),
                             holds: Self.holds(edges: edges, nodes: nodes,
                                               painted: painted.holds, in: frame),
                             ends: ends, frame: frame, fetched: fetched,
                             markings: painted.markings, source: .xPlane(scenery: scenery))
    }

    /// What a line type number is painted as.
    ///
    /// The published file format lists 1 to 9 in yellow, 20 to 22 in white, and 51 to 59 as
    /// 1 to 9 with a black border for concrete. X-Plane 12's files use more — over half of
    /// Logan's paint is codes the published table does not have — and they keep to the same
    /// pattern: fifty more is the same paint with a black border, and the tens say the colour.
    /// Read that way, the reds come out round the gates and the yellows down the taxiways,
    /// which is where they are on the ground; and the codes that carry X-Plane's centreline
    /// lights are the ones read as centrelines.
    static func paint(for code: Int) -> AirportLayout.Marking.Style? {
        guard code > 0, code < 100 else { return nil }
        let base = code > 50 ? code - 50 : code
        switch base {
        case 1, 7, 10, 11: return .init(colour: .yellow, kind: .centreline)
        case 3: return .init(colour: .yellow, kind: .edge)
        case 4: return .init(colour: .yellow, kind: .runwayHold)
        case 5, 6: return .init(colour: .yellow, kind: .hold)
        case 2, 8, 9: return .init(colour: .yellow, kind: .broken)
        case 12...19: return .init(colour: .yellow, kind: .other)
        case 22: return .init(colour: .white, kind: .broken)
        case 20...29: return .init(colour: .white, kind: .other)
        case 30...39: return .init(colour: .red, kind: .other)
        case 40...49: return .init(colour: .orange, kind: .other)
        default: return nil
        }
    }

    /// A runway, its displaced thresholds and its pads.
    private static func runway(_ runway: Runway, at icao: String, in frame: AirportFrame)
    -> (way: AirportLayout.Way?, ends: [AirportLayout.RunwayEnd]) {
        let a = frame.plane(runway.first.at), b = frame.plane(runway.second.at)
        let length = simd_distance(a, b)
        guard length > 1, runway.width > 0 else { return (nil, []) }
        let along = (b - a) / length
        // The file's ends are the ends of the concrete; each threshold is in from its end by
        // its displacement, and never so far that the two pass each other.
        let inFirst = min(max(runway.first.displaced, 0), length * 0.45)
        let inSecond = min(max(runway.second.displaced, 0), length * 0.45)
        let start = a + along * inFirst
        let finish = b - along * inSecond
        let line = [frame.globe(start), frame.globe(finish)]
        let ref = painted(runway.first.name, icao) + "/" + painted(runway.second.name, icao)
        let cap = SphericalCap(line)

        let bare = AirportLayout.Way(ref: ref, width: runway.width, directions: line, cap: cap,
                                     surface: .runway)
        let named = AirportLayout.Way(ref: ref, width: runway.width, directions: line, cap: cap,
                                      surface: .runway,
                                      names: AirportLayout.paintedNumbers(of: bare, in: frame))
        let way = AirportLayout.Way(ref: ref, width: runway.width, directions: line, cap: cap,
                                    surface: .runway,
                                    edges: AirportLayout.edges(of: bare, in: frame),
                                    keys: AirportLayout.thresholdBars(of: bare, in: frame),
                                    zones: AirportLayout.touchdownZones(of: bare, in: frame),
                                    names: named.names,
                                    centreline: AirportLayout.centreline(of: named, in: frame))

        var ends: [AirportLayout.RunwayEnd] = []
        if inFirst > 0.5 {
            ends.append(AirportLayoutStore.displacedEnd([a, start], width: runway.width, in: frame))
        }
        if inSecond > 0.5 {
            ends.append(AirportLayoutStore.displacedEnd([b, finish], width: runway.width, in: frame))
        }
        if runway.first.pad > 0.5 {
            ends.append(AirportLayoutStore.padEnd([a, a - along * runway.first.pad],
                                                  width: runway.width, in: frame))
        }
        if runway.second.pad > 0.5 {
            ends.append(AirportLayoutStore.padEnd([b, b + along * runway.second.pad],
                                                  width: runway.width, in: frame))
        }
        return (way, ends)
    }

    /// A runway end's number as it is painted: "04L" is "4L" in the United States, which
    /// paints no leading nought, and stays "04L" everywhere that does.
    private static func painted(_ name: String, _ icao: String) -> String {
        let american = icao.count == 4 && (icao.hasPrefix("K") || icao.hasPrefix("P"))
        guard american, name.count >= 2, name.hasPrefix("0"),
              let next = name.dropFirst().first, next.isNumber else { return name }
        return String(name.dropFirst())
    }

    /// The points after `from` up to and including `to`: one, or a curve's worth.
    ///
    /// A node's handle curves the stretch leaving it, and its mirror curves the stretch
    /// arriving at it — the editor keeps one handle a node and reflects it for the other
    /// side. A stretch with a handle at neither end is straight.
    private static func segment(_ from: Node, _ to: Node, in frame: AirportFrame) -> [SIMD2<Double>] {
        let start = frame.plane(from.at)
        let end = frame.plane(to.at)
        guard from.handle != nil || to.handle != nil else { return [end] }
        let first = from.handle.map { frame.plane($0) } ?? start
        let second = to.handle.map { end * 2 - frame.plane($0) } ?? end
        let reach = simd_distance(start, first) + simd_distance(first, second)
            + simd_distance(second, end)
        // A point every three metres or so, finer than any zoom the paint is drawn at.
        let steps = min(32, max(2, Int(reach / 3)))
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(steps)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let u = 1 - t
            let near = start * (u * u * u) + first * (3 * u * u * t)
            let far = second * (3 * u * t * t) + end * (t * t * t)
            points.append(near + far)
        }
        return points
    }

    /// A closed chain as a ring of points on the globe, its curves laid out.
    private static func ring(_ chain: Chain, in frame: AirportFrame) -> [SIMD3<Double>] {
        let count = chain.nodes.count
        guard count >= 3, let first = chain.nodes.first else { return [] }
        var points = [frame.plane(first.at)]
        for index in 0..<count {
            points.append(contentsOf: segment(chain.nodes[index], chain.nodes[(index + 1) % count],
                                              in: frame))
        }
        // The last point is the first again.
        points.removeLast()
        return points.map(frame.globe)
    }

    private static func pavement(_ pieces: [[Chain]], in frame: AirportFrame) -> [AirportLayout.Pavement] {
        pieces.compactMap { rings -> AirportLayout.Pavement? in
            guard let outer = rings.first else { return nil }
            let outline = ring(outer, in: frame)
            guard outline.count >= 3 else { return nil }
            let holes = rings.dropFirst().map { ring($0, in: frame) }.filter { $0.count >= 3 }
            return AirportLayout.Pavement(surface: .taxiway, directions: outline,
                                          cap: SphericalCap(outline), holes: holes)
        }
    }

    /// Every painted line, in runs of one style — a line can change its paint part of the way
    /// along — and, apart from them, the runway hold lines: those are drawn as holds.
    ///
    /// The amber lights set into a hold line count as one. Logan's file paints none of its
    /// hold lines and lights every one of them.
    private static func markings(of chains: [Chain], in frame: AirportFrame)
    -> (markings: [AirportLayout.Marking], holds: [[SIMD2<Double>]]) {
        var markings: [AirportLayout.Marking] = []
        var holds: [[SIMD2<Double>]] = []
        for chain in chains {
            let count = chain.nodes.count
            guard count >= 2 else { continue }
            var current: AirportLayout.Marking.Style?
            var run: [SIMD2<Double>] = []
            var lit: [SIMD2<Double>] = []

            func finishRun() {
                if let style = current, run.count >= 2 {
                    if style.kind == .runwayHold {
                        holds.append(run)
                    } else {
                        let line = run.map(frame.globe)
                        markings.append(AirportLayout.Marking(style: style, directions: line,
                                                              cap: SphericalCap(line)))
                    }
                }
                run = []
            }
            func finishLit() {
                if lit.count >= 2 { holds.append(lit) }
                lit = []
            }

            for index in 0..<(chain.closed ? count : count - 1) {
                let from = chain.nodes[index]
                let to = chain.nodes[(index + 1) % count]
                let here = paint(for: from.line)
                if here != current {
                    finishRun()
                    current = here
                }
                if current != nil {
                    if run.isEmpty { run.append(frame.plane(from.at)) }
                    run.append(contentsOf: segment(from, to, in: frame))
                }
                if from.light == 104 {
                    if lit.isEmpty { lit.append(frame.plane(from.at)) }
                    lit.append(contentsOf: segment(from, to, in: frame))
                } else {
                    finishLit()
                }
            }
            finishRun()
            finishLit()
        }
        return (markings, holds)
    }

    /// ICAO's taxiway width for each wingspan letter, which is what the route's letter says
    /// about the pavement under it.
    private static func width(of size: Character?) -> Double {
        switch size ?? " " {
        case "A": return 7.5
        case "B": return 10.5
        case "C": return 15
        case "D": return 18
        case "E": return 23
        case "F": return 25
        default: return AirportSurface.taxiway.width
        }
    }

    /// The taxi routes as taxiways: each name's segments joined into lines, for its letter
    /// and, further out than the paint is drawn, its centreline. Unnamed routes are lanes on
    /// the apron, and are kept for nothing but the holds.
    private static func taxiways(edges: [Edge], nodes: [Int: SIMD3<Double>]) -> [AirportLayout.Way] {
        var byName: [String: [Edge]] = [:]
        for edge in edges where !edge.runway && nodes[edge.from] != nil && nodes[edge.to] != nil {
            byName[edge.name, default: []].append(edge)
        }
        var ways: [AirportLayout.Way] = []
        for name in byName.keys.sorted() {
            guard let list = byName[name] else { continue }
            for chain in chains(of: list) {
                let line = chain.nodes.compactMap { nodes[$0] }
                guard line.count >= 2 else { continue }
                ways.append(AirportLayout.Way(ref: name, width: chain.width, directions: line,
                                              cap: SphericalCap(line),
                                              surface: name.isEmpty ? .taxilane : .taxiway))
            }
        }
        return ways
    }

    /// One name's segments joined into lines through every node where the route simply
    /// carries on, and broken where it branches or stops.
    private static func chains(of edges: [Edge]) -> [(nodes: [Int], width: Double)] {
        var around: [Int: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            around[edge.from, default: []].append(index)
            around[edge.to, default: []].append(index)
        }
        var used = [Bool](repeating: false, count: edges.count)
        var out: [(nodes: [Int], width: Double)] = []

        func walk(from start: Int, along first: Int) {
            var path = [start]
            var node = start
            var edge = first
            var widest = 0.0
            while true {
                used[edge] = true
                let step = edges[edge]
                widest = max(widest, width(of: step.size))
                node = step.from == node ? step.to : step.from
                path.append(node)
                guard let next = around[node], next.count == 2,
                      let onward = next.first(where: { !used[$0] }) else { break }
                edge = onward
            }
            out.append((path, widest))
        }

        // From every end and every junction first, so a line runs between them…
        for node in around.keys.sorted() {
            guard let list = around[node], list.count != 2 else { continue }
            for edge in list where !used[edge] {
                walk(from: node, along: edge)
            }
        }
        // …and then whatever is left, which can only be loops.
        for index in edges.indices where !used[index] {
            walk(from: edges[index].from, along: index)
        }
        return out
    }

    /// Stands by their names, leaving out the ones that are descriptions rather than names.
    private static func stands(_ stands: [Stand]) -> [AirportLayout.Stand] {
        var seen: [String: Int] = [:]
        for stand in stands { seen[stand.name, default: 0] += 1 }
        return stands.compactMap { stand -> AirportLayout.Stand? in
            // A name on more than two stands is a description — "General aviation" on twenty
            // tie-downs — and not a number anyone is looking for.
            guard (seen[stand.name] ?? 0) <= 2, let name = short(stand.name) else { return nil }
            return AirportLayout.Stand(ref: name, direction: stand.at)
        }
    }

    /// A stand's name as the number painted on the ground beside it, or nil for one that is
    /// a description rather than a name.
    ///
    /// "B12" is already that. "Gate B12" is B12, and so is the last word of a long name when
    /// it has a figure in it — Los Angeles calls its stands "Terminal 3 Pos 32" and "West
    /// Gates 419", and the gate is 32 or 419. "Weyerhauser Ramp" has no number at all.
    private static func short(_ name: String) -> String? {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for prefix in ["gate ", "stand ", "parking "] where text.lowercased().hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, rest.count <= 6 { return rest }
        }
        if text.count <= 6 { return text }
        if let last = text.split(separator: " ").last, last.count <= 5,
           last.contains(where: \.isNumber) {
            return String(last)
        }
        return text.count <= 10 ? text : nil
    }

    /// Where an aeroplane stops short of a runway, as a bar across the taxiway.
    ///
    /// The painted hold lines and the lit ones where the file has them, which are exactly where
    /// the line is. Everywhere else, where a taxi route passes into a runway's protected area:
    /// that is where X-Plane's own controllers hold traffic short, and the bar is laid square
    /// across the route there, as wide as the taxiway its letter says it is.
    private static func holds(edges: [Edge], nodes: [Int: SIMD3<Double>],
                              painted: [[SIMD2<Double>]], in frame: AirportFrame) -> [AirportLayout.Hold] {
        var holds = painted.map { line in
            AirportLayout.Hold(ref: "", direction: frame.globe(line[line.count / 2]),
                               across: line.map(frame.globe))
        }
        var touching: [Int: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            touching[edge.from, default: []].append(index)
            touching[edge.to, default: []].append(index)
        }
        for node in touching.keys.sorted() {
            guard let list = touching[node], let at = nodes[node],
                  list.contains(where: { edges[$0].inRunwayZone }),
                  let outside = list.first(where: { !edges[$0].inRunwayZone && !edges[$0].runway })
            else { continue }
            let edge = edges[outside]
            guard let away = nodes[edge.from == node ? edge.to : edge.from] else { continue }
            let here = frame.plane(at)
            let run = frame.plane(away) - here
            guard simd_length(run) > 0.5 else { continue }
            // Painted or lit already: the paint is where the line really is.
            if painted.contains(where: { distance(from: here, to: $0) < 30 }) { continue }
            let side = SIMD2(-run.y, run.x) / simd_length(run) * (width(of: edge.size) / 2)
            holds.append(AirportLayout.Hold(ref: "", direction: at,
                                            across: [frame.globe(here - side),
                                                     frame.globe(here + side)]))
        }
        return holds
    }

    /// How far a point is from the nearest part of a line, in metres on the plane.
    private static func distance(from point: SIMD2<Double>, to line: [SIMD2<Double>]) -> Double {
        guard let first = line.first else { return .infinity }
        var best = simd_distance(point, first)
        for index in 0..<(line.count - 1) {
            let a = line[index], b = line[index + 1]
            let span = b - a
            let squared = simd_length_squared(span)
            let t = squared > 1e-12 ? min(max(simd_dot(point - a, span) / squared, 0), 1) : 0
            best = min(best, simd_distance(point, a + span * t))
        }
        return best
    }
}

// MARK: - The Gateway

/// The X-Plane Scenery Gateway, and the airports from it kept on this Mac.
///
/// Two requests an airport: which version of it is the approved one, and that version — a zip
/// with the airport file in it, a megabyte for Logan and a second or so each way. The Gateway
/// is free and asks only that its server be treated considerately, so an airport is fetched
/// once, kept for good, and asked about again only after a month: a field's ground plan
/// changes every few years. Nothing walks the whole database.
///
/// The airport files are kept exactly as they came, which is the form the GPL they are under
/// calls their source, beside a note of which version each is and when it was asked about.
enum XPlaneGateway {

    static let api = "https://gateway.x-plane.com/apiv1"

    /// What is known about one airport, beside its file.
    struct Note: Codable {
        enum Status: String, Codable {
            /// Its airport file is on disk.
            case layout
            /// The Gateway does not have it.
            case missing
            /// It has it, with nothing on the ground besides the runways.
            case thin
        }
        var status: Status
        var scenery: Int?
        var checked: Date

        /// Worth asking about again: a month on for a layout, three for an airport without one.
        var isStale: Bool {
            let days: Double = status == .layout ? 30 : 90
            return Date().timeIntervalSince(checked) > days * 86_400
        }
    }

    static var directory: URL {
        AirportLayoutStore.root.appendingPathComponent("xplane", isDirectory: true)
    }

    static func file(for icao: String) -> URL {
        directory.appendingPathComponent("\(icao.uppercased()).dat")
    }

    static func noteFile(for icao: String) -> URL {
        directory.appendingPathComponent("\(icao.uppercased()).json")
    }

    static func note(for icao: String) -> Note? {
        guard let data = try? Data(contentsOf: noteFile(for: icao)) else { return nil }
        return try? JSONDecoder().decode(Note.self, from: data)
    }

    static func write(_ note: Note, for icao: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(note) else { return }
        try? data.write(to: noteFile(for: icao), options: .atomic)
    }

    /// True when this airport's file is on disk.
    static func has(_ icao: String) -> Bool {
        FileManager.default.fileExists(atPath: file(for: icao).path)
    }

    /// The airport as it is on disk, ready to draw, or nil if it is not there or will not read.
    static func cached(_ icao: String) -> AirportLayout? {
        guard let note = note(for: icao), note.status == .layout,
              let data = try? Data(contentsOf: file(for: icao)) else { return nil }
        let when = (try? file(for: icao).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return drawn(from: data, icao: icao, scenery: note.scenery ?? 0,
                     fetched: when ?? note.checked)
    }

    /// An airport file read and drawn, or nil if it has no airport or nothing on its ground.
    static func drawn(from data: Data, icao: String, scenery: Int, fetched: Date) -> AirportLayout? {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1),
              let airport = XPlaneAirport.read(text, icao: icao) else { return nil }
        return airport.layout(scenery: scenery, fetched: fetched)
    }

    enum Outcome {
        /// Drawn, and whether it is a different version from the one that was here.
        case layout(AirportLayout, changed: Bool)
        /// The Gateway has nothing worth drawing for it.
        case absent
        /// Not answered: the network, or the server. Nothing is written for it.
        case failed(String)
    }

    /// Asks which version of an airport is the approved one, and fetches it unless it is the
    /// one already here.
    static func refresh(_ icao: String) async -> Outcome {
        let code = icao.uppercased()
        guard !code.isEmpty, code.count <= 8,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return .failed("\(icao) is not an airport code") }
        let before = note(for: code)

        let lookup: (status: Int, data: Data)
        switch await get("\(api)/airport/\(code)", timeout: 30) {
        case .failure(let error): return .failed(error.localizedDescription)
        case .success(let answer): lookup = answer
        }
        if lookup.status == 404 {
            write(Note(status: .missing, scenery: nil, checked: Date()), for: code)
            return .absent
        }
        guard lookup.status == 200,
              let top = try? JSONSerialization.jsonObject(with: lookup.data) as? [String: Any],
              let airport = top["airport"] as? [String: Any]
        else { return .failed("the X-Plane Gateway answered \(lookup.status)") }
        guard let scenery = airport["recommendedSceneryId"] as? Int, scenery > 0 else {
            write(Note(status: .missing, scenery: nil, checked: Date()), for: code)
            return .absent
        }

        // The version already here: nothing to fetch, only the date to move on.
        if let before, before.scenery == scenery {
            if before.status == .layout, let kept = cached(code) {
                write(Note(status: .layout, scenery: scenery, checked: Date()), for: code)
                return .layout(kept, changed: false)
            }
            if before.status == .thin {
                write(Note(status: .thin, scenery: scenery, checked: Date()), for: code)
                return .absent
            }
        }

        let pack: (status: Int, data: Data)
        switch await get("\(api)/scenery/\(scenery)", timeout: 60) {
        case .failure(let error): return .failed(error.localizedDescription)
        case .success(let answer): pack = answer
        }
        guard pack.status == 200,
              let body = try? JSONSerialization.jsonObject(with: pack.data) as? [String: Any],
              let about = body["scenery"] as? [String: Any],
              let blob = about["masterZipBlob"] as? String,
              let zip = Data(base64Encoded: blob, options: .ignoreUnknownCharacters)
        else { return .failed("the X-Plane Gateway's copy of \(code) did not arrive whole") }
        let wanted = "\(code).DAT"
        guard let data = ZipArchive.file(in: zip, where: {
                  ($0 as NSString).lastPathComponent.uppercased() == wanted
              }) ?? ZipArchive.file(in: zip, where: { $0.lowercased().hasSuffix(".dat") })
        else { return .failed("no airport file in the X-Plane Gateway's copy of \(code)") }

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let airport = XPlaneAirport.read(text, icao: code)
        else { return .failed("the X-Plane Gateway's airport file for \(code) did not read") }
        guard let made = airport.layout(scenery: scenery, fetched: Date()) else {
            write(Note(status: .thin, scenery: scenery, checked: Date()), for: code)
            return .absent
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(for: code), options: .atomic)
            write(Note(status: .layout, scenery: scenery, checked: Date()), for: code)
        } catch {
            // Drawn all the same; it is fetched again next time.
        }
        return .layout(made, changed: true)
    }

    private static func get(_ address: String, timeout: TimeInterval) async
    -> Result<(status: Int, data: Data), Error> {
        guard let url = URL(string: address) else { return .failure(URLError(.badURL)) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(AirportLayoutStore.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data))
        } catch {
            return .failure(error)
        }
    }
}
