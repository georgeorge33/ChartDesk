import AppKit
import SwiftUI

/// A map you can drag and zoom, with the loaded flight drawn on it.
///
/// Drawn rather than tiled. A tiled map would mean the network, and the rest of the app works
/// with it off; the land outline and the airports are bundled, so this works on a plane. The
/// cost is that it is a plain map — no terrain, no roads — which for looking at a route is not
/// much of a loss.
///
/// The route needs no navigation database: SimBrief's navlog gives every fix a latitude and
/// longitude, so the shape drawn here is the one the plan actually flies.
struct RouteMapView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var flight: FlightPlanStore

    /// Whichever levels of detail have been read. Shared, not owned: shutting the panel and
    /// opening it again should not mean reading the world in again.
    @ObservedObject private var geography = MapGeography.shared
    /// The full coastline, when it is on this Mac and the zoom calls for it.
    @ObservedObject private var coastline = CoastlineStore.shared

    @State private var camera = MapCamera()
    /// The camera as the current drag began, so a drag is absolute rather than a running sum.
    @State private var cameraAtDragStart: MapCamera?
    @State private var size: CGSize = .zero
    @State private var scrollMonitor: Any?
    /// Where the map sits in the window, so a scroll elsewhere is left alone.
    @State private var frame: CGRect = .zero
    @State private var didFit = false
    /// Set once you drag or zoom, after which the map stops framing things for you.
    @State private var userMoved = false
    @State private var showsLayers = false

    private var plan: FlightPlan? { flight.plan }
    private var waypoints: [FlightPlan.Waypoint] { plan?.waypoints ?? [] }

    /// Airports worth drawing whatever the zoom: the flight's, and the ones you hold charts for.
    ///
    /// The flight's come first and the order is fixed, because this is also the order labels
    /// claim space in — from a dictionary's values the loser of a collision changed run to run.
    private var pinned: [MapAirport] {
        var found: [MapAirport] = []
        var seen = Set<String>()
        for field in plan?.airfields ?? [] {
            guard let airport = WorldData.airport(field.icao), seen.insert(airport.icao).inserted
            else { continue }
            found.append(airport)
        }
        for airport in library.airports.sorted(by: { $0.code < $1.code }) {
            guard let known = WorldData.airport(airport.code), seen.insert(known.icao).inserted
            else { continue }
            found.append(known)
        }
        return found
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvas
            overlay
        }
        .background(Color(nsColor: Theme.canvas))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            size = newSize
            // The first layout is the first chance to frame the route rather than the world.
            if !didFit, newSize.width > 0 {
                didFit = true
                fitRoute()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = cameraAtDragStart ?? camera
                    cameraAtDragStart = start
                    userMoved = true
                    // Turned, not slid: whatever was grabbed stays under the finger, which is
                    // why this needs where the drag began and not only how far it has gone.
                    camera.turn(from: start, grabbing: value.startLocation,
                                to: value.location, in: size)
                }
                .onEnded { _ in cameraAtDragStart = nil }
        )
        // The flight is fetched after the window opens, so the first layout often has no route
        // to frame. Framing it when it lands is the difference between opening on your flight
        // and opening on the whole world.
        .onChange(of: waypoints.count) { _, count in
            guard count > 1, !userMoved else { return }
            fitRoute()
        }
        .onAppear {
            watchScroll()
            // The coarsest tier as well as the wanted one, so there is always something to
            // fall back on while a finer one is read.
            geography.request(.coarse)
            geography.request(camera.detail, coastline: browser.coastline)
            if camera.showsRunways { geography.requestRunways() }
            requestCells()
        }
        // Zooming past a threshold is the only thing that calls for another tier, and the
        // request is idempotent: the store ignores one it already holds or is already reading.
        .onChange(of: camera.detail) { _, detail in
            geography.request(detail, coastline: browser.coastline)
        }
        .onChange(of: browser.coastline) { _, source in
            geography.request(camera.detail, coastline: source)
            requestCells()
        }
        // Panning and zooming both change which cells of the full coastline are in view. The
        // request is idempotent and skips whatever is already read, so asking on every step
        // of a drag costs a set lookup.
        .onChange(of: camera) { _, _ in requestCells() }
        // The first ask for a cell only starts the index reading — fifteen megabytes of it,
        // off the main thread — and returns. Without this the cells were not asked for again
        // until something else moved the camera, so choosing full detail and sitting still
        // drew the simplified coast and said "OSM full" while doing it.
        .onChange(of: coastline.isReady) { _, _ in requestCells() }
        .onChange(of: camera.showsRunways) { _, shows in
            if shows { geography.requestRunways() }
        }
        .onDisappear {
            if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
            scrollMonitor = nil
        }
    }

    // MARK: - Drawing

    private var canvas: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            draw(in: &context, size: canvasSize)
        }
    }

    /// A label wanting a place on the map. Airports ask first, so a fix never pushes an
    /// airport's name off the map.
    private struct Label {
        let text: Text
        let at: CGPoint
        let anchor: UnitPoint
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var labels: [Label] = []
        let sheet = MapSheet(camera: camera, size: size)

        // The sea first, as the sphere itself. Only when the globe's edge is on the sheet:
        // zoomed in past that, the sea is simply the colour behind everything.
        let globe = Path(ellipseIn: sheet.disc)
        if sheet.showsEdge {
            context.fill(globe, with: .color(Color(nsColor: Theme.canvas)))
        }

        // Land, then the lakes cut back out of it, then borders — all from the one level of
        // detail, since a 1:10m coast beside a 1:50m border puts the frontier out at sea.
        if let world = geography.best(for: camera.detail, coastline: browser.coastline) {
            // Where the full coastline has arrived, the bundled one is held back — clipped
            // out, cell by cell. Drawing both was wrong: they disagree, and the bundled fill
            // stayed visible wherever it claimed land the finer one does not, which is a
            // permanently wrong shape rather than the momentary hole it was meant to avoid.
            let full = showsFullCoastline ? sheet.coastlineCells() : []
            let covered = full.isEmpty ? Path() : arrived(full, sheet: sheet)
            var beneath = context
            // Only when there is something to hold back. Clipping to the inverse of an empty
            // path ought to mean "everywhere", but that is not a thing to take on trust when
            // being wrong about it means a map with no land on it.
            if !covered.isEmpty {
                beneath.clip(to: covered, options: .inverse)
            }
            fill(world.land, colour: Color(nsColor: Theme.land),
                 stroke: Color(nsColor: Theme.coast), width: 0.7,
                 in: &beneath, sheet: sheet)

            if !full.isEmpty {
                fill(coastline.shapes(in: full),
                     colour: Color(nsColor: Theme.land),
                     stroke: Color(nsColor: Theme.coast), width: 0.7,
                     in: &context, sheet: sheet)
            }

            fill(world.lakes, colour: Color(nsColor: Theme.canvas),
                 stroke: Color(nsColor: Theme.coast).opacity(0.8), width: 0.5,
                 in: &context, sheet: sheet)

            for shape in world.borders where sheet.mayShow(shape.cap) {
                context.stroke(sheet.path(line: shape.directions),
                               with: .color(Color(nsColor: Theme.border)),
                               style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
        }

        graticule(in: &context, sheet: sheet)

        // What makes it read as a ball rather than a disc: the limb falls away from the light
        // the way a sphere's does. Over the geography, so the whole globe turns with it, and
        // under the route, which has to stay legible wherever it runs.
        if sheet.showsEdge {
            context.fill(globe, with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.55)]),
                center: CGPoint(x: sheet.disc.midX, y: sheet.disc.midY),
                startRadius: sheet.disc.width * 0.3,
                endRadius: sheet.disc.width * 0.52))
            context.stroke(globe, with: .color(Color(nsColor: Theme.coast).opacity(0.7)),
                           lineWidth: 1)
        }

        runways(in: &context, sheet: sheet, labels: &labels)

        // Airports before fixes, so their labels win the space.
        for airport in pinned {
            marker(airport, in: &context, sheet: sheet, labels: &labels)
        }
        if !waypoints.isEmpty {
            route(in: &context, sheet: sheet, labels: &labels)
        }
        place(labels, in: &context, size: size)
    }

    private func fill(_ shapes: [MapShape], colour: Color, stroke: Color, width: CGFloat,
                      in context: inout GraphicsContext, sheet: MapSheet) {
        for shape in shapes where sheet.mayShow(shape.cap) {
            let path = sheet.path(ring: shape)
            guard !path.isEmpty else { continue }
            context.fill(path, with: .color(colour))
            context.stroke(path, with: .color(stroke), lineWidth: width)
        }
    }

    /// Runway tarmac, once a runway is more than a few points long.
    ///
    /// The last level of detail there is: closer in than this a coastline is a straight line
    /// and a border is nowhere near, and what tells you where you are looking is the shape of
    /// the field. Idents go on only once a strip is long enough to hang one off.
    private func runways(in context: inout GraphicsContext, sheet: MapSheet,
                         labels: inout [Label]) {
        guard camera.showsRunways else { return }

        let colour = Color(nsColor: Theme.runway)
        let named = camera.worldWidth >= 500_000
        // Feet across, in points. The globe is drawn to one scale at the middle of the view,
        // so this is the same arithmetic wherever on Earth the runway is — which under
        // Mercator it was not.
        let perFoot = 0.3048 / 6_371_000 * camera.radius

        for runway in geography.runways where sheet.mayShow(runway.cap) {
            let low = sheet.point(runway.low)
            let high = sheet.point(runway.high)
            let across = max(1.2, Double(runway.widthFeet) * perFoot)

            var path = Path()
            path.move(to: low)
            path.addLine(to: high)
            context.stroke(path, with: .color(colour),
                           style: StrokeStyle(lineWidth: across, lineCap: .butt))

            let run = hypot(low.x - high.x, low.y - high.y)
            if named, run > 24, !runway.ident.isEmpty {
                // Just off the threshold, on the runway's own line, the way a plate has it.
                let at = CGPoint(x: low.x + (low.x - high.x) / run * 10,
                                 y: low.y + (low.y - high.y) / run * 10)
                labels.append(Label(text: Text(runway.ident)
                                        .font(.ngSmallMono)
                                        .foregroundStyle(colour),
                                    at: at, anchor: .center))
            }
        }
    }

    /// Draws labels in the order asked for, skipping any that would land on one already there.
    ///
    /// Without this the route reads as gibberish the moment two fixes are close together: at a
    /// continent's width "SUDDS" and "LYSTR" overlapped into "SUDLYSTR".
    private func place(_ labels: [Label], in context: inout GraphicsContext, size: CGSize) {
        var taken: [CGRect] = []
        for label in labels {
            let resolved = context.resolve(label.text)
            let measured = resolved.measure(in: CGSize(width: 200, height: 40))
            var frame = CGRect(origin: label.at, size: measured)
            frame.origin.x -= measured.width * label.anchor.x
            frame.origin.y -= measured.height * label.anchor.y
            // A couple of points of air, or neighbours merely touch instead of overlapping.
            let padded = frame.insetBy(dx: -2, dy: -1)

            guard frame.maxX > 0, frame.minX < size.width,
                  frame.maxY > 0, frame.minY < size.height,
                  !taken.contains(where: { $0.intersects(padded) })
            else { continue }

            taken.append(padded)
            context.draw(resolved, at: label.at, anchor: label.anchor)
        }
    }

    /// Meridians and parallels every 30°, faint. Without them a dark globe has no sense of
    /// which way it is turned.
    ///
    /// Worked out once: on a globe these are arcs rather than the two straight lines Mercator
    /// drew them as, and re-deriving 800 points of them every frame is trigonometry for
    /// nothing. The pen lifts where each runs round the back of the sphere.
    private static let graticuleLines: [[SIMD3<Double>]] = {
        var lines: [[SIMD3<Double>]] = []
        for longitude in stride(from: -180.0, to: 180.0, by: 30) {
            lines.append(stride(from: -88.0, through: 88.0, by: 4).map {
                Coordinate(latitude: $0, longitude: longitude).direction
            })
        }
        for latitude in stride(from: -60.0, through: 60.0, by: 30) {
            lines.append(stride(from: -180.0, through: 180.0, by: 4).map {
                Coordinate(latitude: latitude, longitude: $0).direction
            })
        }
        return lines
    }()

    private func graticule(in context: inout GraphicsContext, sheet: MapSheet) {
        let colour = Color(nsColor: Theme.separator).opacity(0.5)
        for line in Self.graticuleLines {
            context.stroke(sheet.path(line: line), with: .color(colour), lineWidth: 0.5)
        }
    }

    private func route(in context: inout GraphicsContext, sheet: MapSheet,
                       labels: inout [Label]) {
        // Two passes so the enroute line and the procedure legs each read as one colour
        // rather than alternating down the route.
        for procedure in [false, true] {
            let colour = procedure ? Color.orange : Color.ngAccentText
            let style = StrokeStyle(lineWidth: procedure ? 2.5 : 2,
                                    lineCap: .round, lineJoin: .round)
            for (index, waypoint) in waypoints.enumerated() where index > 0 {
                let previous = waypoints[index - 1]
                guard waypoint.isProcedure == procedure else { continue }
                // A great circle, which on a globe is simply the way the aeroplane goes.
                let arc = Spherical.arc(from: Coordinate(latitude: previous.latitude,
                                                         longitude: previous.longitude),
                                        to: Coordinate(latitude: waypoint.latitude,
                                                       longitude: waypoint.longitude))
                let path = sheet.path(line: arc)
                guard !path.isEmpty else { continue }
                context.stroke(path, with: .color(colour), style: style)
            }
        }

        // Fixes, with their names once there is room for them.
        let labelled = degreesAcross < 40
        for waypoint in waypoints where !waypoint.isAirport {
            let coordinate = Coordinate(latitude: waypoint.latitude,
                                        longitude: waypoint.longitude)
            guard sheet.projection.faces(coordinate.direction) else { continue }
            let point = sheet.point(coordinate)
            let dot = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dot),
                         with: .color(waypoint.isProcedure ? Color.orange : Color.ngAccentText))
            if labelled {
                labels.append(Label(text: Text(waypoint.ident)
                                        .font(.ngSmall)
                                        .foregroundStyle(.secondary),
                                    at: CGPoint(x: point.x, y: point.y - 9),
                                    anchor: .bottom))
            }
        }
    }

    private func marker(_ airport: MapAirport, in context: inout GraphicsContext,
                        sheet: MapSheet, labels: inout [Label]) {
        // Round the back of the globe, and there is nothing to draw — which is a thing a
        // sphere can say and a sheet could not.
        guard sheet.projection.faces(airport.coordinate.direction) else { return }
        let point = sheet.point(airport.coordinate)
        guard point.x > -40, point.x < sheet.size.width + 40,
              point.y > -20, point.y < sheet.size.height + 20 else { return }

        let onRoute = plan?.airfields.contains { $0.icao == airport.icao } ?? false
        let colour = onRoute ? Color.ngAccentText : Color.secondary
        let box = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: box), with: .color(colour))
        context.stroke(Path(ellipseIn: box.insetBy(dx: -2, dy: -2)),
                       with: .color(colour.opacity(0.5)), lineWidth: 1)

        labels.append(Label(text: Text(airport.icao)
                                .font(.ngSmallBold)
                                .foregroundStyle(onRoute ? Color.ngAccentText : Color.secondary),
                            at: CGPoint(x: point.x, y: point.y + 8),
                            anchor: .top))
    }

    /// True when the full coastline is chosen, close enough to be worth reading, and there.
    private var showsFullCoastline: Bool {
        browser.coastline == .openStreetMapFull
            && camera.worldWidth >= MapDetail.fullFrom
            && coastline.isReady
    }

    /// The parts of the view the full coastline has arrived for.
    ///
    /// A degree is a small thing at the zoom this runs at, so four corners describe a cell
    /// closely enough. Neighbouring cells share their edges exactly, so the union of them has
    /// no seam for the coast underneath to show through.
    private func arrived(_ wanted: [CoastlineCell], sheet: MapSheet) -> Path {
        var path = Path()
        for cell in wanted where coastline.holds(cell) {
            let west = Double(cell.longitude), east = west + 1
            let south = Double(cell.latitude), north = south + 1
            let corners = [Coordinate(latitude: south, longitude: west),
                           Coordinate(latitude: north, longitude: west),
                           Coordinate(latitude: north, longitude: east),
                           Coordinate(latitude: south, longitude: east)]
                .map { sheet.point($0) }

            path.move(to: corners[0])
            for corner in corners.dropFirst() { path.addLine(to: corner) }
            path.closeSubpath()
        }
        return path
    }

    /// Asks for the cells of the full coastline the view covers.
    private func requestCells() {
        guard browser.coastline == .openStreetMapFull,
              camera.worldWidth >= MapDetail.fullFrom,
              size.width > 0
        else { return }
        coastline.request(MapSheet(camera: camera, size: size).coastlineCells())
    }

    // MARK: - Camera

    private var degreesAcross: Double { camera.degreesAcross(in: size) }

    private func zoom(by factor: CGFloat, around point: CGPoint?) {
        userMoved = true
        camera.zoom(by: factor, around: point, in: size)
    }

    /// Frames the flight, or the world when there is no flight loaded.
    /// Framing counts as putting the map back the way it was, so it clears that flag.
    private func fitRoute() {
        userMoved = false
        let points = waypoints.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            + pinned.map(\.coordinate)
        guard points.count > 1 else {
            // A globe filling the panel: its circumference is pi times its width on screen.
            camera = MapCamera(centre: Coordinate(latitude: 25, longitude: -20),
                               worldWidth: max(min(size.width, size.height) * .pi, 900))
            return
        }
        camera.fit(points, in: size)
    }

    /// Zooming on scroll, but only for scrolls over the map.
    ///
    /// The map shares a window with the sidebar and the chart list now, and a monitor that
    /// swallowed every scroll zoomed the map while you scrolled the airport list — and, because
    /// it zoomed around a cursor that was nowhere near the map, walked the centre off to 206°W.
    private func watchScroll() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window, window.isKeyWindow,
                  let content = window.contentView
            else { return event }

            // SwiftUI's global space has its origin at the top left; an event's does not.
            let inWindow = event.locationInWindow
            let point = CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
            guard frame.contains(point) else { return event }

            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.deltaY * 10
            guard delta != 0 else { return event }

            zoom(by: 1 + delta * 0.006,
                 around: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
            return nil
        }
    }

    // MARK: - Controls

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = plan {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.headline)
                    Text(plan.pair + (plan.aircraft.map { " · \($0)" } ?? ""))
                        .font(.ngSmall)
                        .foregroundStyle(.secondary)
                    Text("\(waypoints.count) fixes"
                         + (waypoints.contains(where: \.isProcedure) ? " · SID/STAR in orange" : ""))
                        .font(.ngSmall)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No flight loaded")
                    .font(.ngSmallMedium)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button("Fit") { fitRoute() }
                    .help("Frame the flight")
                Button {
                    zoom(by: 1.4, around: nil)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button {
                    zoom(by: 1 / 1.4, around: nil)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button {
                    showsLayers.toggle()
                } label: {
                    Image(systemName: "square.3.layers.3d")
                }
                .help("Layers")
                .popover(isPresented: $showsLayers, arrowEdge: .bottom) {
                    MapLayerPanel()
                }
            }
            .controlSize(.small)

            Text(readout)
                .font(.ngSmallMono)
                .foregroundStyle(.tertiary)

            // ODbL asks for the credit wherever the data is drawn, so it goes on the map and
            // not only in the panel where the choice was made.
            if let credit = browser.coastline.attribution {
                Text(credit)
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.ngSeparator)
        }
        .padding(12)
    }

    /// Where the map is looking, how wide, and which of the three worlds it is drawing —
    /// so that the tier is something you can see rather than infer. An ellipsis while a finer
    /// one is still being read.
    private var readout: String {
        var tier = showsFullCoastline ? "OSM full" : "\(camera.detail)"
        if geography.isCatchingUp(to: camera.detail, coastline: browser.coastline) {
            tier += " …"
        } else if showsFullCoastline, size.width > 0 {
            let wanted = MapSheet(camera: camera, size: size).coastlineCells()
            if !wanted.allSatisfy(coastline.holds) { tier += " …" }
        }
        return "\(across) across · \(position) · \(tier)"
    }

    /// How wide the view is, in whatever unit says something at this zoom.
    ///
    /// Degrees stop meaning anything once the map can go down to half a metre to the point:
    /// the readout spent the last stretch of the zoom saying "0° across".
    private var across: String {
        let degrees = degreesAcross
        guard degrees < 1 else { return String(format: "%.0f°", degrees) }
        let metres = degrees / 360 * 40_075_000
        return metres >= 1_000
            ? String(format: "%.1f km", metres / 1_000)
            : String(format: "%.0f m", metres)
    }

    private var position: String {
        let lat = camera.centre.latitude
        let lon = camera.centre.longitude
        return String(format: "%.1f°%@ %.1f°%@",
                      abs(lat), lat >= 0 ? "N" : "S",
                      abs(lon), lon >= 0 ? "E" : "W")
    }
}
