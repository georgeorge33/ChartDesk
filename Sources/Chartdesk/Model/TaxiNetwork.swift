// DEPRECATED — scheduled for removal in 1.0.
//
// Taxi routing did not work well enough in practice to keep: the drag-to-align calibration is
// fiddly and the drawn routes are not dependable enough to read a clearance from. It still
// ships and still works, so existing calibrations and drawn routes are left alone, but nothing
// new should be built on it and it is no longer maintained.

import Foundation

// MARK: - Coordinates

struct Coordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double
}

// MARK: - Cached network

/// An airport's ground layout as `Tools/taxi_import.py` leaves it: OpenStreetMap geometry,
/// flattened into index-addressed points. Chartdesk only ever reads these files — fetching is
/// the importer's job, which is what keeps the app itself free of network access.
struct TaxiNetwork: Decodable {

    struct Segment: Decodable {
        let refs: [String]
        let n: [Int]
        /// Apron lead-in rather than a real taxiway. Routable, but never a named leg.
        let lane: Bool?
    }

    struct Runway: Decodable {
        let ref: String
        let n: [Int]
    }

    struct Spot: Decodable {
        let ref: String
        let at: [Double]

        var coordinate: Coordinate? {
            at.count == 2 ? Coordinate(latitude: at[0], longitude: at[1]) : nil
        }
    }

    let icao: String
    let nodes: [[Double]]
    let edges: [Segment]
    let runways: [Runway]
    let stands: [Spot]
    let holds: [Spot]

    func coordinate(_ index: Int) -> Coordinate? {
        guard nodes.indices.contains(index), nodes[index].count == 2 else { return nil }
        return Coordinate(latitude: nodes[index][0], longitude: nodes[index][1])
    }

    // MARK: Loading

    static func cacheDirectory() -> URL? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Chartdesk/taxi", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func load(icao: String) -> TaxiNetwork? {
        guard let url = cacheDirectory()?.appendingPathComponent("\(icao.uppercased()).json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TaxiNetwork.self, from: data)
    }

    /// Which airports have been imported, for telling the user what is available.
    static func cachedAirports() -> [String] {
        guard let folder = cacheDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)).uppercased() }
            .sorted()
    }
}

// MARK: - Intersections

/// Where two named taxiways cross. These are what a chart is calibrated against: a runway's
/// OpenStreetMap geometry runs to the physical end of the pavement, while the chart marks the
/// displaced threshold, and those are not the same point. Two centrelines crossing are.
struct TaxiIntersection: Identifiable, Hashable {
    let first: String
    let second: String
    let coordinate: Coordinate

    var id: String { "\(first)|\(second)" }
    var label: String { "\(first) × \(second)" }
}

// MARK: - Routing

struct RouteLeg: Equatable {
    /// nil for unnamed pavement bridging two taxiways.
    let designator: String?
    let isLane: Bool
    let coordinates: [Coordinate]
}

struct TaxiRoute: Equatable {
    var legs: [RouteLeg]
    var metres: Double
    /// Named taxiways the route had to use that were never asked for. Surfaced rather than
    /// hidden: it is the difference between a route you chose and one the data chose.
    var inferred: [String]
    /// A straight line from a stand that does not join the taxi network. Drawn differently,
    /// because it is a guess at where the apron lead-in runs rather than mapped pavement.
    var approximateLeadIn: [Coordinate]?

    var coordinates: [Coordinate] {
        var out: [Coordinate] = []
        for leg in legs {
            for point in leg.coordinates where out.last != point {
                out.append(point)
            }
        }
        return out
    }
}

enum RouteOutcome: Equatable {
    case route(TaxiRoute)
    case failure(String)
}

/// The turnable graph: every way split at the nodes it shares with another way, because a
/// shared node is exactly where an aircraft could turn off.
final class TaxiGraph {

    private struct Link {
        let to: Int
        let ref: String?
        let isLane: Bool
        let metres: Double
        let path: [Int]
    }

    private struct State: Hashable {
        let node: Int
        let step: Int
        let travelled: Bool
    }

    /// An unnamed connector is allowed but not preferred; travelling along a taxiway that was
    /// not asked for is a last resort rather than forbidden, since OSM occasionally leaves a
    /// designator off the one segment that joins two others.
    private static let connectorCost = 1.6
    private static let laneCost = 2.2
    private static let unrequestedCost = 60.0

    let network: TaxiNetwork
    private var links: [Int: [Link]] = [:]
    private var nodesByDesignator: [String: Set<Int>] = [:]
    private var runwayNodes: [String: Set<Int>] = [:]

    private(set) var designators: [String] = []
    private(set) var runwayNames: [String] = []
    private(set) var adjacency: [String: Set<String>] = [:]
    private(set) var intersections: [TaxiIntersection] = []

    init(_ network: TaxiNetwork) {
        self.network = network
        build()
    }

    // MARK: Construction

    private func build() {
        var usage: [Int: Int] = [:]
        for way in network.edges {
            for node in Set(way.n) { usage[node, default: 0] += 1 }
        }
        for way in network.runways {
            for node in Set(way.n) { usage[node, default: 0] += 1 }
        }

        for way in network.edges {
            let ref = way.refs.first
            let isLane = way.lane ?? false
            var run: [Int] = way.n.isEmpty ? [] : [way.n[0]]

            for node in way.n.dropFirst() {
                run.append(node)
                let isJunction = (usage[node] ?? 0) > 1
                if isJunction || node == way.n.last {
                    if run.count > 1 { connect(run, ref: ref, isLane: isLane) }
                    run = [node]
                }
            }

            if let ref = ref, !isLane {
                nodesByDesignator[ref, default: []].formUnion(way.n)
            }
        }

        for runway in network.runways where !runway.ref.isEmpty {
            runwayNodes[runway.ref, default: []].formUnion(runway.n)
        }

        designators = nodesByDesignator.keys.sorted(by: TaxiGraph.naturalOrder)
        runwayNames = runwayNodes.keys.sorted(by: TaxiGraph.naturalOrder)
        buildAdjacency()
        buildIntersections()
    }

    /// Only crossings that can be pointed at without ambiguity are offered.
    ///
    /// A stub meets its parent more than once — A1 touches A at both ends — so "A × A1" does
    /// not identify a place. Those pairs are dropped rather than disambiguated: at Boston that
    /// costs 7 of 44 and leaves 37, which is far more than a calibration needs.
    private func buildIntersections() {
        var namesAtNode: [Int: Set<String>] = [:]
        for way in network.edges where !(way.lane ?? false) {
            guard let ref = way.refs.first else { continue }
            for node in way.n { namesAtNode[node, default: []].insert(ref) }
        }

        var nodesForPair: [String: [Int]] = [:]
        for (node, names) in namesAtNode where names.count > 1 {
            let sorted = names.sorted(by: TaxiGraph.naturalOrder)
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    nodesForPair["\(sorted[i])|\(sorted[j])", default: []].append(node)
                }
            }
        }

        intersections = nodesForPair.compactMap { key, nodes in
            guard nodes.count == 1,
                  let coordinate = network.coordinate(nodes[0]) else { return nil }
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2 else { return nil }
            return TaxiIntersection(first: parts[0], second: parts[1], coordinate: coordinate)
        }
        .sorted {
            $0.first == $1.first
                ? TaxiGraph.naturalOrder($0.second, $1.second)
                : TaxiGraph.naturalOrder($0.first, $1.first)
        }
    }

    /// The crossing furthest from everything picked so far. A fit is only as well conditioned
    /// as its points are spread out, so the panel suggests rather than leaving it to chance.
    func suggestedIntersection(avoiding taken: [Coordinate]) -> TaxiIntersection? {
        guard !intersections.isEmpty else { return nil }
        guard !taken.isEmpty else {
            // Nothing placed yet: start at one end of the field rather than the middle.
            let centre = centreOfField()
            return intersections.max {
                TaxiGraph.metres(between: centre, and: $0.coordinate)
                    < TaxiGraph.metres(between: centre, and: $1.coordinate)
            }
        }
        return intersections.max { left, right in
            let l = taken.map { TaxiGraph.metres(between: $0, and: left.coordinate) }.min() ?? 0
            let r = taken.map { TaxiGraph.metres(between: $0, and: right.coordinate) }.min() ?? 0
            return l < r
        }
    }

    private func centreOfField() -> Coordinate {
        let points = intersections.map(\.coordinate)
        guard !points.isEmpty else { return Coordinate(latitude: 0, longitude: 0) }
        return Coordinate(
            latitude: points.map(\.latitude).reduce(0, +) / Double(points.count),
            longitude: points.map(\.longitude).reduce(0, +) / Double(points.count)
        )
    }

    /// How far apart the airport's own features are, for judging whether two picked points
    /// are far enough apart to pin down a scale.
    var extentMetres: Double {
        let points = network.nodes.compactMap { row -> Coordinate? in
            row.count == 2 ? Coordinate(latitude: row[0], longitude: row[1]) : nil
        }
        guard let west = points.min(by: { $0.longitude < $1.longitude }),
              let east = points.max(by: { $0.longitude < $1.longitude }) else { return 3000 }
        return max(TaxiGraph.metres(between: west, and: east), 500)
    }

    private func connect(_ path: [Int], ref: String?, isLane: Bool) {
        guard let first = path.first, let last = path.last, first != last else { return }
        let length = distance(path)
        links[first, default: []].append(Link(to: last, ref: ref, isLane: isLane,
                                              metres: length, path: path))
        links[last, default: []].append(Link(to: first, ref: ref, isLane: isLane,
                                             metres: length, path: path.reversed()))
    }

    /// Which taxiways you could turn onto from each one. Unnamed pavement is stepped over, so
    /// a short connector between two taxiways does not hide the junction.
    private func buildAdjacency() {
        var atNode: [Int: Set<String>] = [:]
        var connectorNeighbours: [Int: Set<Int>] = [:]

        for way in network.edges {
            if let ref = way.refs.first, !(way.lane ?? false) {
                for node in way.n { atNode[node, default: []].insert(ref) }
            } else {
                for node in way.n {
                    connectorNeighbours[node, default: []].formUnion(way.n)
                }
            }
        }

        for (node, refs) in atNode {
            var pool = refs
            for neighbour in connectorNeighbours[node] ?? [] {
                pool.formUnion(atNode[neighbour] ?? [])
            }
            for ref in refs {
                adjacency[ref, default: []].formUnion(pool.subtracting([ref]))
            }
        }
    }

    // MARK: Geometry

    private func distance(_ path: [Int]) -> Double {
        var total = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
            total += TaxiGraph.metres(between: network.coordinate(a), and: network.coordinate(b))
        }
        return total
    }

    static func metres(between a: Coordinate?, and b: Coordinate?) -> Double {
        guard let a = a, let b = b else { return 0 }
        let degree = 111_320.0
        let east = (b.longitude - a.longitude) * degree * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let north = (b.latitude - a.latitude) * degree
        return (east * east + north * north).squareRoot()
    }

    /// Sorts A, A1, A2, B rather than A, A1, A10, A11, A2.
    static func naturalOrder(_ left: String, _ right: String) -> Bool {
        let a = left.split(whereSeparator: \.isNumber)
        let b = right.split(whereSeparator: \.isNumber)
        let aLetters = a.first.map(String.init) ?? left
        let bLetters = b.first.map(String.init) ?? right
        if aLetters != bLetters { return aLetters < bLetters }
        let aNumber = Int(left.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? -1
        let bNumber = Int(right.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? -1
        if aNumber != bNumber { return aNumber < bNumber }
        return left < right
    }

    // MARK: Whole taxiway

    /// Every segment carrying a designator, for "show me where K is" rather than a route.
    func extent(of designator: String) -> TaxiRoute? {
        let matching = network.edges.filter { $0.refs.first == designator && !($0.lane ?? false) }
        guard !matching.isEmpty else { return nil }

        var legs: [RouteLeg] = []
        var total = 0.0
        for way in matching {
            let points = way.n.compactMap { network.coordinate($0) }
            guard points.count > 1 else { continue }
            legs.append(RouteLeg(designator: designator, isLane: false, coordinates: points))
            total += distance(way.n)
        }
        guard !legs.isEmpty else { return nil }
        return TaxiRoute(legs: legs, metres: total, inferred: [], approximateLeadIn: nil)
    }

    // MARK: Route

    func route(taxiways: [String], destination: String?, stand: String?) -> RouteOutcome {
        if taxiways.isEmpty {
            guard let destination = destination else { return .failure("Pick a taxiway to begin.") }
            return .failure("Add a taxiway before \(destination).")
        }

        for name in taxiways where nodesByDesignator[name] == nil {
            return .failure("Taxiway \(name) is not in the imported data for \(network.icao).")
        }
        if let destination = destination, runwayNodes[destination] == nil {
            return .failure("Runway \(destination) is not in the imported data for \(network.icao).")
        }

        // A single taxiway with nowhere to go is a request to see the whole thing, not a
        // shortest path that clips the nearest metre of it.
        if taxiways.count == 1, destination == nil, stand == nil {
            if let whole = extent(of: taxiways[0]) { return .route(whole) }
        }

        guard let found = search(taxiways: taxiways, destination: destination) else {
            return .failure(destination == nil
                            ? "No connected path along \(taxiways.joined(separator: ", "))."
                            : "No connected path from \(taxiways.joined(separator: ", ")) to \(destination!).")
        }

        var result = found
        if let stand = stand {
            attachLeadIn(to: &result, stand: stand)
        }
        return .route(result)
    }

    private func search(taxiways: [String], destination: String?) -> TaxiRoute? {
        let goalNodes = destination.flatMap { runwayNodes[$0] }

        var queue = Heap<State>()
        var best: [State: Double] = [:]
        var parent: [State: (State, Link)] = [:]

        for node in nodesByDesignator[taxiways[0]] ?? [] where links[node] != nil {
            let state = State(node: node, step: 0, travelled: false)
            best[state] = 0
            queue.push(0, state)
        }
        guard !queue.isEmpty else { return nil }

        while let (cost, state) = queue.pop() {
            if cost > best[state] ?? .infinity { continue }

            let finishedTaxiways = state.step == taxiways.count - 1 && state.travelled
            let atGoal = goalNodes.map { $0.contains(state.node) } ?? true
            if finishedTaxiways && atGoal {
                return assemble(state, parent: parent, taxiways: taxiways)
            }

            for link in links[state.node] ?? [] {
                var moves: [(Int, Bool, Double)] = []

                if link.ref == taxiways[state.step] {
                    moves.append((state.step, true, link.metres))
                } else if link.ref == nil {
                    moves.append((state.step, state.travelled,
                                  link.metres * (link.isLane ? TaxiGraph.laneCost : TaxiGraph.connectorCost)))
                } else {
                    moves.append((state.step, state.travelled, link.metres * TaxiGraph.unrequestedCost))
                }

                if state.travelled, state.step + 1 < taxiways.count,
                   link.ref == taxiways[state.step + 1] {
                    moves.append((state.step + 1, true, link.metres))
                }

                for (step, travelled, weight) in moves {
                    let next = State(node: link.to, step: step, travelled: travelled)
                    let total = cost + weight
                    if total < best[next] ?? .infinity {
                        best[next] = total
                        parent[next] = (state, link)
                        queue.push(total, next)
                    }
                }
            }
        }
        return nil
    }

    private func assemble(_ end: State,
                          parent: [State: (State, Link)],
                          taxiways: [String]) -> TaxiRoute {
        var legs: [RouteLeg] = []
        var total = 0.0
        var cursor = end

        while let (previous, link) = parent[cursor] {
            let points = link.path.compactMap { network.coordinate($0) }
            legs.append(RouteLeg(designator: link.ref, isLane: link.isLane, coordinates: points))
            total += link.metres
            cursor = previous
        }
        legs.reverse()

        let requested = Set(taxiways)
        let inferred = legs.compactMap { $0.designator }
            .filter { !requested.contains($0) }
        return TaxiRoute(legs: legs,
                         metres: total,
                         inferred: Array(Set(inferred)).sorted(by: TaxiGraph.naturalOrder),
                         approximateLeadIn: nil)
    }

    /// Stands rarely join the taxi network — at many airports the apron lead-ins simply are
    /// not mapped — so the gap is bridged with a straight line and reported as a guess.
    private func attachLeadIn(to route: inout TaxiRoute, stand: String) {
        guard let spot = network.stands.first(where: { $0.ref == stand })?.coordinate,
              let head = route.coordinates.first else { return }

        if TaxiGraph.metres(between: spot, and: head) < 5 { return }
        route.approximateLeadIn = [spot, head]
    }

    func stand(named ref: String) -> Coordinate? {
        network.stands.first { $0.ref == ref }?.coordinate
    }

    var standNames: [String] {
        Array(Set(network.stands.map(\.ref).filter { !$0.isEmpty })).sorted(by: TaxiGraph.naturalOrder)
    }

    /// Every piece of pavement, for the faint overlay that shows whether a calibration lines
    /// the data up with the printed chart.
    var allPolylines: [[Coordinate]] {
        (network.edges.map { $0.n } + network.runways.map { $0.n })
            .map { $0.compactMap(network.coordinate) }
            .filter { $0.count > 1 }
    }
}

// MARK: - Priority queue

/// A plain binary heap. Swift has no standard one, and the route search needs to pop the
/// cheapest state rather than scan for it.
private struct Heap<Value> {
    private var storage: [(Double, Value)] = []

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(_ priority: Double, _ value: Value) {
        storage.append((priority, value))
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            if storage[parent].0 <= storage[child].0 { break }
            storage.swapAt(parent, child)
            child = parent
        }
    }

    mutating func pop() -> (Double, Value)? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let top = storage.removeLast()

        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < storage.count, storage[left].0 < storage[smallest].0 { smallest = left }
            if right < storage.count, storage[right].0 < storage[smallest].0 { smallest = right }
            if smallest == parent { break }
            storage.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
