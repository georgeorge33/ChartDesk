import Foundation
import simd

/// A taxi route across an airport: where it runs, what it is called, where you hold.
struct TaxiRoute {
    /// The line to draw, on the globe.
    let directions: [SIMD3<Double>]
    /// The taxiways it uses, in order and without repeats — a clearance, near enough.
    let legs: [String]
    /// The holding positions it passes, in order.
    let holds: [String]
    /// Metres along the ground.
    let metres: Double
}

/// The taxiways of one airport, as something you can find a way across.
///
/// Rebuilt from the layout rather than fetched: the layout already has every centreline,
/// and the only thing missing is which of them touch. OpenStreetMap does not say so
/// directly — Overpass hands back coordinates and no node numbers — but two ways that meet
/// quote the identical point, because it is the identical node. Measured across the cached
/// airports that is enough to put 99–100% of the network into one connected piece.
///
/// Runways are deliberately not in it. Their nodes are, by way of the taxiways that cross
/// them, so a route can go over a runway; but nothing may run *along* one. Without that
/// rule the shortest way out of Kennedy is to taxi down 13R, which is both what the search
/// wants to do and the last thing anyone should be shown.
struct TaxiNetwork {

    /// How close a picked point has to be to the pavement to count as being on it.
    static let reach: Double = 120

    private let frame: AirportFrame
    /// Where each node is, in metres on the field's own plane.
    private let place: [SIMD2<Double>]
    private let directions: [SIMD3<Double>]
    private let edges: [[(to: Int, metres: Double, way: Int)]]
    private let ways: [AirportLayout.Way]
    private let holds: [AirportLayout.Hold]
    private let holdAt: [SIMD2<Double>]

    /// How much of the network is in its largest piece.
    ///
    /// The number that decides whether this airport can be routed at all. A field mapped in
    /// pieces will happily return a route between two points that happen to share a piece
    /// and refuse every other pair, which is worse than not offering.
    let wholeness: Double

    init(_ layout: AirportLayout) {
        let frame = layout.frame
        self.frame = frame
        self.ways = layout.taxiways
        self.holds = layout.holds
        self.holdAt = layout.holds.map { frame.plane($0.direction) }

        var index: [Int64: Int] = [:]
        var place: [SIMD2<Double>] = []
        var directions: [SIMD3<Double>] = []
        var edges: [[(to: Int, metres: Double, way: Int)]] = []

        func node(_ d: SIMD3<Double>) -> Int {
            let k = Self.key(d)
            if let n = index[k] { return n }
            index[k] = place.count
            place.append(frame.plane(d))
            directions.append(d)
            edges.append([])
            return place.count - 1
        }

        for (w, way) in layout.taxiways.enumerated() {
            var previous: Int?
            for direction in way.directions {
                let here = node(direction)
                if let p = previous, p != here {
                    let metres = simd_length(place[p] - place[here])
                    edges[p].append((here, metres, w))
                    edges[here].append((p, metres, w))
                }
                previous = here
            }
        }

        self.place = place
        self.directions = directions
        self.edges = edges

        // The largest piece, as a share of the whole.
        var seen = [Bool](repeating: false, count: place.count)
        var biggest = 0
        for start in 0..<place.count where !seen[start] {
            var stack = [start]
            seen[start] = true
            var size = 0
            while let here = stack.popLast() {
                size += 1
                for edge in edges[here] where !seen[edge.to] {
                    seen[edge.to] = true
                    stack.append(edge.to)
                }
            }
            biggest = max(biggest, size)
        }
        wholeness = place.isEmpty ? 0 : Double(biggest) / Double(place.count)
    }

    var isEmpty: Bool { place.isEmpty }

    /// Overpass prints seven decimal places, so two ways at one node round to one key.
    private static func key(_ d: SIMD3<Double>) -> Int64 {
        let c = Coordinate(d)
        return Int64((c.latitude * 1e7).rounded()) &* 4_000_000_000
             &+ Int64((c.longitude * 1e7).rounded())
    }

    /// The nearest point of pavement to somewhere on the field, if there is one near enough.
    func nearest(to direction: SIMD3<Double>) -> Int? {
        let at = frame.plane(direction)
        var best: (Int, Double)?
        for (index, point) in place.enumerated() where !edges[index].isEmpty {
            let away = simd_length(point - at)
            if away < (best?.1 ?? .greatestFiniteMagnitude) { best = (index, away) }
        }
        guard let found = best, found.1 <= Self.reach else { return nil }
        return found.0
    }

    /// Where a node is, for drawing the ends of a route.
    func direction(of node: Int) -> SIMD3<Double> { directions[node] }

    /// The shortest way from one to the other, or nothing if they are not joined.
    ///
    /// Dijkstra over metres of tarmac. No heuristic: an airport is a few thousand nodes and
    /// the search is over before the arithmetic to guide it would have paid for itself.
    func route(from: Int, to: Int) -> TaxiRoute? {
        guard from != to, from < place.count, to < place.count else { return nil }
        var cost = [Double](repeating: .greatestFiniteMagnitude, count: place.count)
        var cameFrom = [Int](repeating: -1, count: place.count)
        var viaWay = [Int](repeating: -1, count: place.count)
        var queue = Heap()
        cost[from] = 0
        queue.push(from, 0)

        while let (here, sofar) = queue.pop() {
            if here == to { break }
            guard sofar <= cost[here] else { continue }
            for edge in edges[here] where sofar + edge.metres < cost[edge.to] {
                cost[edge.to] = sofar + edge.metres
                cameFrom[edge.to] = here
                viaWay[edge.to] = edge.way
                queue.push(edge.to, cost[edge.to])
            }
        }
        guard cost[to] < .greatestFiniteMagnitude else { return nil }

        var path: [SIMD3<Double>] = []
        var legs: [String] = []
        var passed: [String] = []
        var here = to
        while here != -1 {
            path.append(directions[here])
            // Only the movement area is named. The lead off a stand is pavement you are
            // pushed onto, not a taxiway anyone reads out.
            let w = viaWay[here]
            if w >= 0, ways[w].isMovementArea {
                let name = AirportLayout.designator(ways[w].ref)
                if !name.isEmpty, legs.last != name { legs.append(name) }
            }
            for (index, at) in holdAt.enumerated()
            where simd_length(at - place[here]) < 25 && !holds[index].ref.isEmpty {
                let name = holds[index].ref
                if passed.last != name { passed.append(name) }
            }
            if here == from { break }
            here = cameFrom[here]
        }
        return TaxiRoute(directions: path.reversed(), legs: legs.reversed(),
                         holds: passed.reversed(), metres: cost[to])
    }

    /// A plain binary heap, because sorting the frontier every step is the whole cost of the
    /// search and this is the textbook way not to.
    private struct Heap {
        private var items: [(node: Int, cost: Double)] = []

        mutating func push(_ node: Int, _ cost: Double) {
            items.append((node, cost))
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].cost < items[parent].cost else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> (Int, Double)? {
            guard !items.isEmpty else { return nil }
            let top = items[0]
            items[0] = items[items.count - 1]
            items.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                if right < items.count, items[right].cost < items[smallest].cost { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
            return (top.node, top.cost)
        }
    }
}
