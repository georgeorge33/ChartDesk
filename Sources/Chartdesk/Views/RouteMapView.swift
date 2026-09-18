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

    @State private var camera = MapCamera()
    /// The camera as the current drag began, so a drag is absolute rather than a running sum.
    @State private var cameraAtDragStart: MapCamera?
    @State private var size: CGSize = .zero
    @State private var showsLabels = true
    @State private var scrollMonitor: Any?
    /// Where the map sits in the window, so a scroll elsewhere is left alone.
    @State private var frame: CGRect = .zero
    @State private var didFit = false
    /// Set once you drag or zoom, after which the map stops framing things for you.
    @State private var userMoved = false

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
                    camera.pan(from: start, by: value.translation)
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
        .onAppear(perform: watchScroll)
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
        let visible = camera.visibleRect(in: size)

        // Land, then the lakes cut back out of it, then borders. Each shape is drawn at every
        // 360° offset that reaches the view, which is how a ring crossing the antimeridian
        // appears on both edges instead of sweeping across the middle.
        fill(WorldData.land, colour: Color(nsColor: Theme.land),
             stroke: Color(nsColor: Theme.coast), width: 0.7,
             in: &context, size: size, visible: visible)

        fill(WorldData.lakes, colour: Color(nsColor: Theme.canvas),
             stroke: Color(nsColor: Theme.coast).opacity(0.8), width: 0.5,
             in: &context, size: size, visible: visible)

        for shape in WorldData.borders {
            for shift in shifts(for: shape, visible: visible) {
                context.stroke(path(for: shape, in: size, shift: shift, closed: false),
                               with: .color(Color(nsColor: Theme.border)),
                               style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
        }

        graticule(in: &context, size: size)

        // Airports before fixes, so their labels win the space.
        for airport in pinned {
            marker(airport, in: &context, size: size, labels: &labels)
        }
        if !waypoints.isEmpty {
            route(in: &context, size: size, labels: &labels)
        }
        place(labels, in: &context, size: size)
    }

    private func fill(_ shapes: [MapShape], colour: Color, stroke: Color, width: CGFloat,
                      in context: inout GraphicsContext, size: CGSize, visible: CGRect) {
        for shape in shapes {
            for shift in shifts(for: shape, visible: visible) {
                let path = path(for: shape, in: size, shift: shift, closed: true)
                context.fill(path, with: .color(colour))
                context.stroke(path, with: .color(stroke), lineWidth: width)
            }
        }
    }

    /// Which copies of a shape reach the view: none, its own, or one wrapped round the world.
    private func shifts(for shape: MapShape, visible: CGRect) -> [Double] {
        var found: [Double] = []
        for shift in [-1.0, 0.0, 1.0] {
            if shape.bounds.offsetBy(dx: shift, dy: 0).intersects(visible) { found.append(shift) }
        }
        return found
    }

    /// One ring as a path, sampled to the detail the scale can actually show.
    ///
    /// At a whole-world zoom a 1:50m ring carries far more points than it has pixels, and
    /// drawing all of them is most of the cost of a frame. The stride asks for about two points
    /// per pixel of the shape's own width, so close in nothing is dropped.
    private func path(for shape: MapShape, in size: CGSize, shift: Double, closed: Bool) -> Path {
        let onScreen = shape.bounds.width * camera.worldWidth
        let wanted = max(16.0, Double(onScreen) * 2)
        let step = max(1, Int((Double(shape.points.count) / wanted).rounded(.down)))
        let offset = shift * camera.worldWidth

        var path = Path()
        var started = false
        var index = 0
        while index < shape.points.count {
            var point = camera.screen(shape.points[index], in: size)
            point.x += offset
            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
            index += step
        }
        // The last point matters: dropping it leaves a visible notch in a coastline.
        if step > 1, let last = shape.points.last {
            var point = camera.screen(last, in: size)
            point.x += offset
            path.addLine(to: point)
        }
        if closed { path.closeSubpath() }
        return path
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

    /// Meridians and parallels every 30°, faint. Without them a dark map has no sense of scale.
    private func graticule(in context: inout GraphicsContext, size: CGSize) {
        let colour = Color(nsColor: Theme.separator).opacity(0.5)
        for longitude in stride(from: -180.0, through: 180.0, by: 30) {
            var path = Path()
            path.move(to: screen(Coordinate(latitude: Mercator.limit, longitude: longitude), in: size))
            path.addLine(to: screen(Coordinate(latitude: -Mercator.limit, longitude: longitude), in: size))
            context.stroke(path, with: .color(colour), lineWidth: 0.5)
        }
        for latitude in stride(from: -60.0, through: 60.0, by: 30) {
            var path = Path()
            path.move(to: screen(Coordinate(latitude: latitude, longitude: -180), in: size))
            path.addLine(to: screen(Coordinate(latitude: latitude, longitude: 180), in: size))
            context.stroke(path, with: .color(colour), lineWidth: 0.5)
        }
    }

    private func route(in context: inout GraphicsContext, size: CGSize,
                       labels: inout [Label]) {
        // Two passes so the enroute line and the procedure legs each read as one colour
        // rather than alternating down the route.
        for procedure in [false, true] {
            var path = Path()
            var started = false
            for (index, waypoint) in waypoints.enumerated() where index > 0 {
                let previous = waypoints[index - 1]
                guard waypoint.isProcedure == procedure else { continue }
                let arc = Mercator.arc(from: Coordinate(latitude: previous.latitude,
                                                        longitude: previous.longitude),
                                        to: Coordinate(latitude: waypoint.latitude,
                                                       longitude: waypoint.longitude))
                for (step, coordinate) in arc.enumerated() {
                    let point = screen(coordinate, in: size)
                    if step == 0 {
                        path.move(to: point)
                        started = true
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            guard started else { continue }
            context.stroke(path,
                           with: .color(procedure ? Color.orange : Color.ngAccentText),
                           style: StrokeStyle(lineWidth: procedure ? 2.5 : 2,
                                              lineCap: .round, lineJoin: .round))
        }

        // Fixes, with their names once there is room for them.
        let labelled = showsLabels && degreesAcross < 40
        for waypoint in waypoints where !waypoint.isAirport {
            let point = screen(Coordinate(latitude: waypoint.latitude,
                                          longitude: waypoint.longitude), in: size)
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
                        size: CGSize, labels: inout [Label]) {
        let point = screen(airport.coordinate, in: size)
        guard point.x > -40, point.x < size.width + 40,
              point.y > -20, point.y < size.height + 20 else { return }

        let onRoute = plan?.airfields.contains { $0.icao == airport.icao } ?? false
        let colour = onRoute ? Color.ngAccentText : Color.secondary
        let box = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: box), with: .color(colour))
        context.stroke(Path(ellipseIn: box.insetBy(dx: -2, dy: -2)),
                       with: .color(colour.opacity(0.5)), lineWidth: 1)

        if showsLabels {
            labels.append(Label(text: Text(airport.icao)
                                    .font(.ngSmallBold)
                                    .foregroundStyle(onRoute ? Color.ngAccentText : Color.secondary),
                                at: CGPoint(x: point.x, y: point.y + 8),
                                anchor: .top))
        }
    }

    // MARK: - Camera

    private var degreesAcross: Double { camera.degreesAcross(in: size) }

    private func screen(_ coordinate: Coordinate, in size: CGSize) -> CGPoint {
        camera.screen(coordinate, in: size)
    }


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
            camera = MapCamera(centre: Coordinate(latitude: 25, longitude: -20),
                               worldWidth: max(size.width, 600))
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
                Toggle("Labels", isOn: $showsLabels)
                    .toggleStyle(.checkbox)
                    .font(.ngSmall)
            }
            .controlSize(.small)

            Text(String(format: "%.0f° across · %@", degreesAcross, position))
                .font(.ngSmallMono)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.ngSeparator)
        }
        .padding(12)
    }

    private var position: String {
        let lat = camera.centre.latitude
        let lon = camera.centre.longitude
        return String(format: "%.1f°%@ %.1f°%@",
                      abs(lat), lat >= 0 ? "N" : "S",
                      abs(lon), lon >= 0 ? "E" : "W")
    }
}
