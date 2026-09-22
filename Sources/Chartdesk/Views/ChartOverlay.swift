import AppKit
import MapKit
import SwiftUI
import simd

/// The chart layers, drawn by MapKit rather than over it.
///
/// A canvas laid on top of a map view can only ever follow it. MapKit draws, the delegate
/// reports the new rectangle, SwiftUI schedules a redraw, and the chart arrives a frame
/// later — which at a kilometre across is the taxiway sitting off the tarmac for as long as
/// your hand is moving. Nothing tunes that away, because the two are rendered on separate
/// timetables.
///
/// An overlay renderer is on MapKit's timetable. It is handed the same transform the base
/// is drawn with, in the same pass, so the two cannot come apart: the taxiway is welded to
/// the photograph rather than aimed at it.
///
/// Drawing happens in `MKMapPoint`, which for an overlay bounding the world is exactly the
/// renderer's own coordinate space — checked against a real renderer, `point(for:)` is the
/// identity. So the shapes are built by the same code as before and MapKit owns every
/// transform after that.
final class ChartOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: MKMapRect.world.midX, y: MKMapRect.world.midY).coordinate
    }
    /// The whole world: the chart has something to say almost anywhere.
    var boundingMapRect: MKMapRect { .world }
}

/// What the renderer needs to know to draw a frame. Handed over whole rather than read
/// piecemeal, because it is read from MapKit's thread and the view's state is not.
///
/// Nothing in here depends on the zoom. The renderer knows the zoom exactly and every
/// threshold that depends on it is its business; this is only what there is to draw.
struct ChartFrame {
    // The airport's own ground.
    var layouts: [AirportLayout] = []
    var showsGroundLayout = false
    /// Stands are hundreds of numbers at a big field, and only worth the room at the very
    /// closest zooms.
    var showsStands = false

    /// The whole airspace table, and which classes are switched on. None is the layer
    /// switched off.
    var airspace: [MapAirspace] = []
    var airspaceKinds: Set<AirspaceClass> = []

    /// The bundled runway table, which draws every field that has no layout of its own.
    var runways: [MapRunway] = []
    /// Towns and cities, when they are drawn at all: over the imagery and not over
    /// Apple's own map, which has its own.
    var cities: [MapCity] = []

    /// The flight, and the airports worth a marker whatever the zoom — in the order they
    /// claim room for their names, the flight's own first.
    var waypoints: [FlightPlan.Waypoint] = []
    var airports: [MapAirport] = []
    var onRoute: Set<String> = []

    /// What would make the drawing different. Compared instead of the things themselves,
    /// which are thousands of points each and are only ever swapped whole.
    var stamp: String {
        [
            "\(showsGroundLayout)\(showsStands)",
            // With how many ends each has: a layout topped up with its stopways comes back
            // under the same ICAO, and by the ICAO alone it would never be drawn again.
            layouts.map { "\($0.icao):\($0.ends.count)" }.joined(separator: ","),
            "\(airspace.count):\(airspace.first?.name ?? ""):\(airspace.last?.name ?? "")",
            airspaceKinds.map(\.rawValue).sorted().joined(),
            "\(runways.count):\(cities.count)",
            waypoints.map(\.ident).joined(separator: " "),
            airports.map(\.icao).joined(separator: ","),
            onRoute.sorted().joined(separator: ","),
        ].joined(separator: "|")
    }
}

final class ChartRenderer: MKOverlayRenderer {

    // MARK: - What it is told

    /// Everything the renderer is told, behind one lock. Tiles are drawn on MapKit's own
    /// queue, several at a time, while the view writes from the main thread — and a frame
    /// is a dozen arrays, which read while being replaced is freed memory.
    private let lock = NSLock()
    private var current = ChartFrame()
    private var scale: Double = 0
    private var shown = MKMapRect.null
    private var settled: Settled?

    var frame: ChartFrame {
        get { lock.withLock { current } }
        set {
            lock.withLock { current = newValue }
            setNeedsDisplay()
        }
    }

    /// How many map points go to one point on the screen, as the map view is actually
    /// showing it.
    ///
    /// Not `1 / zoomScale`, which is what an overlay renderer is handed and which is
    /// quantised to powers of two: MapKit rasterises a tile at the level below and scales
    /// the result up until the next level is reached. A line asked to be two points thick
    /// therefore grew to nearly four before snapping back, and so did the writing, which
    /// is what made the letters breathe with the zoom. The map view is asked for the real
    /// figure instead, and the drawing is sized by that.
    var page: Double {
        get { lock.withLock { scale } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard scale != newValue else { return false }
                scale = newValue
                return true
            }
            if changed { setNeedsDisplay() }
        }
    }

    /// What the map view is showing, which decides which of the thousands of airspace and
    /// town labels are worth finding room for. It moves on every frame of a pan and
    /// redraws nothing — except the first time, when every tile drawn before it had
    /// nothing to go on.
    var view: MKMapRect {
        get { lock.withLock { shown } }
        set {
            let first = lock.withLock { () -> Bool in
                defer { shown = newValue }
                return shown.isNull && !newValue.isNull
            }
            if first { setNeedsDisplay() }
        }
    }

    // MARK: - Drawing

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let (frame, page, view) = lock.withLock { (self.current, self.scale, self.shown) }
        // Map points to the screen point: what a line width has to be divided by to come
        // out the same thickness however far in you are.
        let scale = page > 0 ? page : 1 / Double(zoomScale)
        let chart = ChartContext(cg: context, mapPointsPerScreenPoint: scale)
        let sheet = MapSheet(mapRect: mapRect, padding: 64 * scale,
                             mapPointsPerScreenPoint: scale)
        let work = settle(frame, scale: scale, view: view, chart: chart)

        // Bottom to top. The ground under the airspace, because by the time it draws the
        // view is a few kilometres across and the airspace is a tint over the whole field;
        // the route over everything, because it is the thing you are flying; and all of
        // the writing last, so no field's concrete and no ring's edge buries a name.
        if frame.showsGroundLayout {
            for layout in frame.layouts where sheet.mayShow(layout.cap) {
                Self.ground(layout, in: chart, sheet: sheet)
            }
        }
        for ring in work.rings {
            Self.airspace(ring, in: chart, sheet: sheet)
        }
        for strip in work.strips {
            Self.runway(strip, in: chart, sheet: sheet)
        }
        let near = sheet.panel
        for place in work.places where near.contains(place) {
            chart.dot(at: place, radius: 1.5, Theme.place.withAlphaComponent(0.8))
        }
        for marker in work.markers where near.contains(marker.point) {
            let colour = marker.onRoute ? Theme.route : Theme.mapSecondary
            chart.dot(at: marker.point, radius: 3.5, colour)
            chart.circle(at: marker.point, radius: 5.5, width: 1, colour.withAlphaComponent(0.5))
        }
        for leg in work.legs {
            Self.route(leg, in: chart, sheet: sheet)
        }
        for fix in work.fixes where near.contains(fix.point) {
            chart.dot(at: fix.point, radius: 2.5, fix.procedure ? Theme.procedure : Theme.route)
        }
        for placed in work.writing where near.intersects(placed.room) {
            if let label = placed.label { chart.draw(label) }
        }
    }

    // MARK: - Settling a frame

    /// Everything about a frame that does not depend on the tile, worked out once and
    /// kept until the frame, the zoom or the region of interest changes.
    ///
    /// MapKit draws an overlay in tiles — a dozen calls to `draw` for one view — so a
    /// declutter that starts empty in each of them is not one decision but twelve. A
    /// label that loses its space in one tile and wins it in the next is drawn as half a
    /// label, and two labels either side of a seam never see each other at all. Labels
    /// sit at map points and only their size on the page changes with the scale, so the
    /// answer is the same for every tile at a given zoom.
    private struct Settled {
        let key: String
        let scale: Double
        let region: CGRect
        let writing: [Placed]
        let rings: [Ring]
        let strips: [Strip]
        let legs: [Leg]
        let fixes: [Fix]
        let markers: [Marker]
        let places: [CGPoint]
    }

    /// A ring of airspace that is big enough to draw at this zoom, and a box round it.
    private struct Ring {
        let space: MapAirspace
        let bounds: CGRect
        let colour: NSColor
        /// Points on the screen.
        let width: Double
        let dash: [Double]
    }

    /// A runway from the bundled table: a straight band between its two thresholds.
    private struct Strip {
        let low: CGPoint
        let high: CGPoint
        let width: Double
    }

    /// One leg of the route, as a great circle already on the sheet.
    private struct Leg {
        let points: [CGPoint]
        let bounds: CGRect
        let procedure: Bool
    }

    private struct Fix {
        let point: CGPoint
        let procedure: Bool
    }

    private struct Marker {
        let point: CGPoint
        let onRoute: Bool
    }

    /// A label and the room it was given, both in map points.
    private struct Placed {
        /// Nothing, for a reservation: room something else already fills — a runway's
        /// painted number — that no label may be put on top of.
        var label: ChartContext.Label?
        var room: CGRect
    }

    private func settle(_ frame: ChartFrame, scale: Double, view: MKMapRect,
                        chart: ChartContext) -> Settled {
        lock.lock()
        defer { lock.unlock() }
        let region = Self.region(for: view, scale: scale,
                                 keeping: settled?.scale == scale ? settled?.region : nil)
        let key = "\(frame.stamp)|\(scale)|\(region.minX),\(region.minY),\(region.width)"
        if let settled, settled.key == key { return settled }
        let made = Self.work(frame, scale: scale, view: view, region: region, key: key,
                             chart: chart)
        settled = made
        return made
    }

    /// Where labels are looked for: the view, with a good margin.
    ///
    /// Not the whole world, which for the ground's few hundred labels was fine and for
    /// airspace is eighteen thousand rings. Not the view itself either, which changes on
    /// every frame of a pan and would work everything out again on each of them. The view
    /// grown by at least its own size, and kept until the view — with room for the tiles
    /// MapKit draws beyond its edge — no longer fits inside it: a label is only ever left
    /// out for being far off the screen, and a pan works it all out again once every
    /// half a view or so rather than sixty times a second.
    private static func region(for view: MKMapRect, scale: Double,
                               keeping old: CGRect?) -> CGRect {
        let world = MKMapSize.world
        guard !view.isNull, view.width > 0, view.height > 0 else {
            // Nothing to go on: everywhere, which is right for a first frame and for a
            // picture drawn with no view at all.
            return CGRect(x: -world.width, y: -world.height,
                          width: world.width * 3, height: world.height * 3)
        }
        let shown = CGRect(x: view.minX, y: view.minY, width: view.width, height: view.height)
        let needed = shown.insetBy(dx: -640 * scale, dy: -640 * scale)
        if let old, old.contains(needed) { return old }
        return shown.insetBy(dx: -max(shown.width, 1_280 * scale),
                             dy: -max(shown.height, 1_280 * scale))
    }

    /// A dark edge round writing that has no box behind it, so that it reads over a
    /// photograph as well as over the dark map.
    private static let halo = NSColor.black.withAlphaComponent(0.7)

    private static func work(_ frame: ChartFrame, scale: Double, view: MKMapRect,
                             region: CGRect, key: String, chart: ChartContext) -> Settled {
        let world = MKMapSize.world.width
        // The whole world, because a tile's own rectangle is the thing being avoided here.
        let sheet = MapSheet(mapRect: .world, padding: 0)
        let projection = sheet.projection
        // How wide the world and the view are on the screen, in points: what every
        // threshold in the app is written in.
        let worldWidth = world / scale
        let across = view.isNull || view.width <= 0 ? 1_100 : view.width / scale
        let degreesAcross = 360 * across / worldWidth

        func interesting(_ point: CGPoint) -> Bool {
            region.contains(point)
                || region.contains(CGPoint(x: point.x + world, y: point.y))
                || region.contains(CGPoint(x: point.x - world, y: point.y))
        }

        // Every label that wants room, in the order it gets it: the airports, because a fix
        // must never push a field's name off the map; the fixes, because they are the
        // route; the writing on the ground; the runways' idents; the airspace figures; and
        // the towns, which are there to say where you are and matter least.
        var wanted: [ChartContext.Label] = []
        var painted: [CGRect] = []

        var markers: [Marker] = []
        for airport in frame.airports {
            let at = projection.point(airport.coordinate.direction)
            let onRoute = frame.onRoute.contains(airport.icao)
            markers.append(Marker(point: at, onRoute: onRoute))
            wanted.append(ChartContext.Label(
                text: airport.icao, size: 10.5, weight: .semibold,
                colour: onRoute ? Theme.route : Theme.mapSecondary, halo: halo, at: at,
                anchor: CGPoint(x: 0.5, y: 0), nudge: CGVector(dx: 0, dy: 8)))
        }

        // The route: a great circle between each pair of points, which is the way the
        // aeroplane goes, unwrapped along its length so that a leg over the antimeridian
        // is one leg and not a line back across the whole world.
        var enroute: [Leg] = [], procedures: [Leg] = []
        let points = frame.waypoints
        for index in points.indices.dropFirst() {
            let from = points[index - 1], to = points[index]
            let arc = Spherical.arc(from: Coordinate(latitude: from.latitude,
                                                     longitude: from.longitude),
                                    to: Coordinate(latitude: to.latitude,
                                                   longitude: to.longitude))
            let line = projection.visible(ring: arc)
            let leg = Leg(points: line, bounds: box(line), procedure: to.isProcedure)
            if leg.procedure { procedures.append(leg) } else { enroute.append(leg) }
        }
        var fixes: [Fix] = []
        let named = degreesAcross < 40
        for waypoint in points where !waypoint.isAirport {
            let at = projection.point(Coordinate(latitude: waypoint.latitude,
                                                 longitude: waypoint.longitude).direction)
            fixes.append(Fix(point: at, procedure: waypoint.isProcedure))
            if named {
                wanted.append(ChartContext.Label(
                    text: waypoint.ident, size: 10.5, weight: .regular,
                    colour: Theme.mapSecondary, halo: halo, at: at,
                    anchor: CGPoint(x: 0.5, y: 1), nudge: CGVector(dx: 0, dy: -9)))
            }
        }

        if frame.showsGroundLayout {
            for layout in frame.layouts {
                groundWriting(layout, in: sheet, chart: chart, stands: frame.showsStands,
                              into: &wanted, painted: &painted)
            }
        }

        // The bundled runways, once a runway is more than a few points long: closer in
        // than that, the shape of the field is what tells you where you are looking. Not
        // where a fetched layout covers the field, which has the runway's real outline and
        // draws it instead.
        var strips: [Strip] = []
        if worldWidth >= MapDetail.runwaysFrom {
            let fetched = frame.showsGroundLayout ? frame.layouts.map(\.cap) : []
            let idents = worldWidth >= 500_000
            for runway in frame.runways {
                let low = projection.point(runway.low.direction)
                guard interesting(low) else { continue }
                if fetched.contains(where: {
                    simd_dot($0.centre, runway.cap.centre) > $0.cosRadius
                }) { continue }
                let high = projection.point(runway.high.direction)
                let metres = Double(runway.widthFeet) * 0.3048
                let width = max(chart.screen(1.2),
                                metres * mapPointsPerMetre(latitude: runway.low.latitude))
                strips.append(Strip(low: low, high: high, width: width))

                let run = hypot(low.x - high.x, low.y - high.y)
                guard idents, run > chart.screen(24), !runway.ident.isEmpty else { continue }
                // Just off the threshold, on the runway's own line, the way a plate has it.
                let off = chart.screen(10) / run
                wanted.append(ChartContext.Label(
                    text: runway.ident, size: 10.5, weight: .regular, mono: true,
                    colour: Theme.runway, halo: halo,
                    at: CGPoint(x: low.x + (low.x - high.x) * off,
                                y: low.y + (low.y - high.y) * off)))
            }
        }

        // Airspace, from the zoom where a ring starts to be more than a smudge, and only
        // the rings big enough to carry two figures. The table arrives sorted quietest
        // first, so drawing in order paints the busy airspace over the quiet.
        var rings: [Ring] = []
        if !frame.airspaceKinds.isEmpty, worldWidth >= MapLayerRoom.airspaceFrom {
            let perRadian = worldWidth / (2 * .pi)
            for space in frame.airspace where frame.airspaceKinds.contains(space.klass)
                && space.cap.radius * perRadian >= MapLayerRoom.leastRadius {
                let bounds = projection.bounds(of: space.cap)
                // Only what could land in a tile. Tiles are only ever drawn inside the
                // region, so a ring wholly outside it is one every tile would test and
                // none would draw — which, kept worldwide, was fifteen thousand of them.
                let copies: [Double] = [0, world, -world]
                guard copies.contains(where: {
                    bounds.offsetBy(dx: $0, dy: 0).intersects(region)
                }) else { continue }
                let style = stroke(of: space.klass)
                let ring = Ring(space: space, bounds: bounds,
                                colour: Theme.airspace(space.klass),
                                width: style.width, dash: style.dash)
                rings.append(ring)
                let at = projection.point(space.labelAt.direction)
                guard interesting(at) else { continue }
                wanted.append(ChartContext.Label(
                    text: space.ceilingLabel, under: space.floorLabel, size: 10.5,
                    weight: .regular, mono: true, colour: ring.colour, halo: halo, at: at))
            }
        }

        var places: [CGPoint] = []
        if !frame.cities.isEmpty {
            let deepest = MapLayerRoom.cityRank(degreesAcross: degreesAcross)
            for city in frame.cities where city.rank <= deepest {
                let at = projection.point(city.direction)
                guard interesting(at) else { continue }
                places.append(at)
                wanted.append(ChartContext.Label(
                    text: city.name, size: 10.5, weight: .regular, colour: Theme.place,
                    halo: halo, at: at, anchor: CGPoint(x: 0, y: 0.5),
                    nudge: CGVector(dx: 4, dy: 0)))
            }
        }

        var crowd = Crowd(cell: chart.screen(128))
        for room in painted { crowd.reserve(room) }
        // A couple of points of air, or neighbours merely touch instead of overlapping.
        let air = chart.screen(2)
        for label in wanted {
            crowd.take(label, room: chart.bounds(of: label).insetBy(dx: -air, dy: -air),
                       spacing: label.spacing.map { chart.screen($0) })
        }

        return Settled(key: key, scale: scale, region: region, writing: crowd.placed,
                       rings: rings, strips: strips, legs: enroute + procedures,
                       fixes: fixes, markers: markers, places: places)
    }

    /// Labels that have won their room, with a grid over them so that asking whether a new
    /// one collides is a look at its neighbours rather than at every label placed so far.
    /// Airspace alone can be several thousand of them, and the old way was their square.
    private struct Crowd {
        private let cell: Double
        private(set) var placed: [Placed] = []
        private var grid: [Int64: [Int]] = [:]
        private var said: [String: [CGPoint]] = [:]

        init(cell: Double) { self.cell = max(cell, 1e-9) }

        private func cells(_ room: CGRect) -> [Int64] {
            let x0 = Int64((room.minX / cell).rounded(.down))
            let x1 = Int64((room.maxX / cell).rounded(.down))
            let y0 = Int64((room.minY / cell).rounded(.down))
            let y1 = Int64((room.maxY / cell).rounded(.down))
            var out: [Int64] = []
            for x in x0...x1 {
                for y in y0...y1 { out.append((x << 32) ^ (y & 0xFFFF_FFFF)) }
            }
            return out
        }

        mutating func reserve(_ room: CGRect) {
            add(Placed(label: nil, room: room), in: cells(room))
        }

        mutating func take(_ label: ChartContext.Label, room: CGRect, spacing: Double?) {
            let under = cells(room)
            for key in under {
                for index in grid[key] ?? [] where placed[index].room.intersects(room) {
                    return
                }
            }
            if let spacing, let before = said[label.text],
               before.contains(where: { hypot($0.x - label.at.x, $0.y - label.at.y) < spacing }) {
                return
            }
            add(Placed(label: label, room: room), in: under)
            if spacing != nil { said[label.text, default: []].append(label.at) }
        }

        private mutating func add(_ entry: Placed, in keys: [Int64]) {
            placed.append(entry)
            for key in keys { grid[key, default: []].append(placed.count - 1) }
        }
    }

    // MARK: - Airspace, runways and the route

    /// Weight and dash per kind, in points, following the chart: solid where entry is by
    /// clearance, dashed where the boundary is advisory or the area only sometimes active.
    private static func stroke(of klass: AirspaceClass) -> (width: Double, dash: [Double]) {
        switch klass {
        case .a: return (2, [])
        case .b: return (2.2, [])
        case .c: return (2, [])
        case .d: return (1.8, [5, 3])
        case .e: return (1.5, [2, 3])
        case .prohibited: return (2.4, [])
        case .restricted: return (2.1, [])
        case .danger: return (2, [6, 3])
        }
    }

    /// Which copies of something might show in this tile: itself, and a world over either
    /// way where it runs across the antimeridian. The overlay bounds the one world, so the
    /// part of a leg that has crossed the seam is drawn again, shifted, where the tiles
    /// on the far side will find it.
    private static func shifts(of bounds: CGRect, in sheet: MapSheet) -> [Double] {
        let world = MKMapSize.world.width
        let copies: [Double] = [0, world, -world]
        return copies.filter { bounds.offsetBy(dx: $0, dy: 0).intersects(sheet.panel) }
    }

    private static func box(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func airspace(_ ring: Ring, in chart: ChartContext, sheet: MapSheet) {
        let copies = shifts(of: ring.bounds, in: sheet)
        guard !copies.isEmpty else { return }
        let world = MKMapSize.world.width
        var points = sheet.projection.visible(ring: ring.space.directions)
        // Unwrapped from its first point, which may be a world away from its middle when
        // the ring straddles the seam; brought back to the side its box is on.
        if let first = points.first {
            let middle = sheet.projection.point(ring.space.cap.centre).x
            let off = ((middle - first.x) / world).rounded() * world
            if off != 0 { points = points.map { CGPoint(x: $0.x + off, y: $0.y) } }
        }
        let dash = ring.dash.map { chart.screen($0) }
        let period = dash.reduce(0, +)
        for shift in copies {
            let moved = shift == 0 ? points : points.map { CGPoint(x: $0.x + shift, y: $0.y) }
            chart.fill(sheet.path(ring: moved), ring.colour.withAlphaComponent(0.07))
            for run in sheet.runs(moved, closed: true) {
                let phase = period > 0 ? run.from.truncatingRemainder(dividingBy: period) : 0
                chart.stroke(run.path, ring.colour, width: chart.screen(ring.width),
                             dash: dash, phase: phase)
            }
        }
    }

    private static func runway(_ strip: Strip, in chart: ChartContext, sheet: MapSheet) {
        let reach = strip.width / 2 + chart.screen(1)
        let box = CGRect(x: min(strip.low.x, strip.high.x), y: min(strip.low.y, strip.high.y),
                         width: abs(strip.high.x - strip.low.x),
                         height: abs(strip.high.y - strip.low.y))
            .insetBy(dx: -reach, dy: -reach)
        guard box.intersects(sheet.panel) else { return }
        var path = Path()
        path.move(to: strip.low)
        path.addLine(to: strip.high)
        chart.stroke(path, Theme.runway, width: strip.width, cap: .butt)
    }

    private static func route(_ leg: Leg, in chart: ChartContext, sheet: MapSheet) {
        let colour = leg.procedure ? Theme.procedure : Theme.route
        let width = chart.screen(leg.procedure ? 2.5 : 2)
        for shift in shifts(of: leg.bounds.insetBy(dx: -width, dy: -width), in: sheet) {
            let moved = shift == 0
                ? leg.points : leg.points.map { CGPoint(x: $0.x + shift, y: $0.y) }
            for run in sheet.runs(moved, closed: false) {
                chart.stroke(run.path, colour, width: width, cap: .round, join: .round)
            }
        }
    }

    /// Metres into map points at a latitude: Mercator stretches by 1/cos φ.
    private static func mapPointsPerMetre(latitude: Double) -> Double {
        MKMapSize.world.width / (40_075_017 * max(cos(latitude * .pi / 180), 0.02))
    }

    // MARK: - The ground

    /// The writing on the ground: taxiway designators, runway numbers at the ends they
    /// belong to, the holding positions, and the stands closest in.
    ///
    /// In here with the tarmac rather than on the canvas above it, because a designator
    /// that lags the taxiway it names is worse than no designator — it is a label pointing
    /// at the wrong piece of concrete.
    private static func groundWriting(_ layout: AirportLayout, in sheet: MapSheet,
                                      chart: ChartContext, stands: Bool,
                                      into found: inout [ChartContext.Label],
                                      painted: inout [CGRect]) {
        for way in layout.taxiways where !way.ref.isEmpty && way.isMovementArea {
            guard let at = middle(of: way, sheet: sheet) else { continue }
            found.append(ChartContext.Label(text: AirportLayout.designator(way.ref),
                                            colour: Theme.taxiLine, box: .black,
                                            border: Theme.taxiLine, at: at, spacing: 160))
        }
        // Each runway number once: painted on the runway when it is big enough to read
        // there, and in a label at the threshold when it is not. Both would be the same
        // figures twice, a few metres apart.
        let metre = Self.mapPointsPerMetre(at: layout)
        for way in layout.runways where !way.ref.isEmpty {
            var paintedHere = Set<String>()
            for name in way.names {
                let height = name.height * metre
                guard chart.paintedHeight(inMapPoints: height) >= Self.paintedFrom else {
                    continue
                }
                let centre = sheet.projection.point(name.centre)
                let ahead = sheet.projection.point(name.ahead)
                painted.append(chart.paintedBounds(
                    name.text, centre: centre,
                    facing: CGVector(dx: ahead.x - centre.x, dy: ahead.y - centre.y),
                    capHeight: height))
                paintedHere.insert(name.text)
            }
            for (number, at) in AirportLayout.numbers(of: way)
            where !paintedHere.contains(number) {
                found.append(ChartContext.Label(text: number, colour: .white,
                                                box: NSColor.black.withAlphaComponent(0.85),
                                                border: NSColor.white.withAlphaComponent(0.7),
                                                at: sheet.projection.point(at)))
            }
        }
        for hold in layout.holds where !hold.ref.isEmpty {
            found.append(ChartContext.Label(text: hold.ref, colour: Theme.holdShort,
                                            box: .black, border: Theme.holdShort,
                                            at: sheet.projection.point(hold.direction),
                                            spacing: 160))
        }
        guard stands else { return }
        for stand in layout.stands where !stand.ref.isEmpty {
            found.append(ChartContext.Label(text: stand.ref, size: 9, weight: .regular,
                                            colour: Theme.stand,
                                            box: NSColor.black.withAlphaComponent(0.8),
                                            at: sheet.projection.point(stand.direction)))
        }
    }

    /// The middle of a way, where its letter goes.
    private static func middle(of way: AirportLayout.Way, sheet: MapSheet) -> CGPoint? {
        guard !way.directions.isEmpty else { return nil }
        return sheet.projection.point(way.directions[way.directions.count / 2])
    }

    /// Metres into map points, at this airport's latitude and not at the equator.
    /// Mercator stretches by 1/cos φ, so the equator's figure would draw Boston's taxiways
    /// a quarter narrower than they are and Svalbard's at half.
    private static func mapPointsPerMetre(at layout: AirportLayout) -> Double {
        let latitude = Coordinate(layout.frame.centre).latitude * .pi / 180
        return MKMapSize.world.width / (40_075_017 * max(cos(latitude), 0.02))
    }

    /// How tall a runway's painted number has to be on the screen, in points, before it
    /// is painted on the runway. Below this the figures are a smudge on the threshold, and
    /// the number goes in a label beside the runway instead.
    private static let paintedFrom: Double = 7

    /// The airport's own ground, in map points.
    private static func ground(_ layout: AirportLayout, in chart: ChartContext,
                               sheet: MapSheet) {
        let metre = Self.mapPointsPerMetre(at: layout)
        let wide = { (metres: Double) in metres * metre }

        // The taxiways get only their paint: both base maps are Apple's and both already
        // have the taxiway tarmac in the picture. The aprons and the taxiway pavement are
        // still parsed and still cached, and simply not filled.
        //
        // The runway is different, and is drawn the way a ground chart draws it: a solid
        // dark band the full width of the concrete, and on it, in white, the piano keys,
        // the touchdown zone and the aiming point, the broken centreline and each end's
        // number across the threshold. Everything painted is in metres, because it is
        // paint and should grow with the ground; the lines that are there to be seen
        // rather than to be to scale stay the same on the screen however far in you are.
        // The ends that are not the runway proper, under it. A displaced stretch is runway
        // concrete you may roll on but not land on, painted with arrows at the threshold
        // instead of a centreline; a stopway or blast pad is concrete nobody should be on,
        // painted with yellow chevrons pointing back at the runway.
        for end in layout.ends where sheet.mayShow(end.cap) {
            let outline = sheet.path(ring: MapShape(directions: end.outline, cap: end.cap))
            chart.fill(outline, Theme.runwaySurface)
            // The same faint edge as the runway's, or over the dark map it has none.
            chart.stroke(outline, Theme.runwayMarking.withAlphaComponent(0.35),
                         width: chart.screen(1))
            let colour = end.kind == .pad ? Theme.taxiLine : Theme.runwayMarking
            chart.clipped(to: outline) {
                for mark in end.marks {
                    // Round where it is a line to follow, so an arrow's head and a
                    // chevron's apex meet in a point rather than a notch.
                    chart.stroke(sheet.path(straight: mark.line), colour,
                                 width: max(wide(mark.width), chart.screen(mark.least)),
                                 cap: mark.least > 0 ? .round : .butt)
                }
            }
        }

        for way in layout.runways where sheet.mayShow(way.cap) {
            if way.edges.count == 2 {
                let outline = way.edges[0] + way.edges[1].reversed()
                chart.fill(sheet.path(ring: MapShape(directions: outline, cap: way.cap)),
                           Theme.runwaySurface)
                // A hairline at the edge, faint. Over a light photograph the band's own
                // edge is enough; over Apple's dark map it is not, quite.
                for edge in way.edges {
                    chart.stroke(sheet.path(straight: edge),
                                 Theme.runwayMarking.withAlphaComponent(0.35),
                                 width: chart.screen(1))
                }
            }
            for bar in way.keys {
                chart.stroke(sheet.path(straight: bar), Theme.runwayMarking, width: wide(2.5),
                             cap: .butt)
            }
            for zone in way.zones {
                chart.stroke(sheet.path(straight: zone.line), Theme.runwayMarking,
                             width: wide(zone.width), cap: .butt)
            }
        }

        let line = chart.screen(2.2)
        for way in layout.taxiways where way.isMovementArea && sheet.mayShow(way.cap) {
            chart.stroke(sheet.path(curve: way.directions), Theme.taxiLine,
                         width: line, cap: .round, join: .round)
        }
        for way in layout.runways where sheet.mayShow(way.cap) {
            // Thirty-six metres of paint and twenty-four of gap, which is the FAA's 120ft
            // and 80ft; narrower than a taxiway line, the way the reference draws it.
            chart.stroke(sheet.path(straight: way.centreline), Theme.runwayMarking,
                         width: chart.screen(1.6), dash: [wide(36), wide(24)])
            for name in way.names {
                let height = wide(name.height)
                guard chart.paintedHeight(inMapPoints: height) >= Self.paintedFrom else {
                    continue
                }
                let centre = sheet.projection.point(name.centre)
                let ahead = sheet.projection.point(name.ahead)
                chart.paint(name.text, centre: centre,
                            facing: CGVector(dx: ahead.x - centre.x, dy: ahead.y - centre.y),
                            capHeight: height, colour: Theme.runwayMarking)
            }
        }
        for hold in layout.holds where hold.across.count == 2 {
            chart.stroke(sheet.path(line: hold.across), Theme.holdShort,
                         width: line * 1.6, cap: .butt)
        }
    }
}
