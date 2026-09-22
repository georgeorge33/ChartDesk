import AppKit
import simd
import MapKit
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
    /// Whether openAIP's table is on this Mac, which decides whether it can be drawn.
    @ObservedObject private var openAIP = OpenAIPStore.shared
    /// Apple Maps, when the base map is one of its two.
    /// Airport ground layouts, fetched one airport at a time.
    @ObservedObject private var ground = AirportLayoutStore.shared

    @State private var camera = MapCamera()
    /// The camera as the current drag began, so a drag is absolute rather than a running sum.
    @State private var size: CGSize = .zero
    /// Where the map sits in the window, so a scroll elsewhere is left alone.
    @State private var frame: CGRect = .zero
    @State private var didFit = false
    /// Set once you drag or zoom, after which the map stops framing things for you.
    @State private var userMoved = false
    @State private var showsLayers = false
    /// What the map view is showing. The camera above is derived from it rather than the
    /// other way round, because the gesture happens in the map view.
    @State private var mapRect = MKMapRect.world
    /// Pending "what should we be fetching" work, waiting for the map to stop moving.
    @State private var settling: Task<Void, Never>?

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
            // The map underneath, and it owns the panning and the zooming. Everything above
            // is drawn against the rectangle it reports, so the chart follows the map rather
            // than the two being kept in step.
            AppleMapLayer(configuration: browser.baseMap.configuration,
                          rect: $mapRect,
                          chart: chartFrame) { shown in
                // One write each, and only where something changed. This runs on every
                // frame the map moves, and each state change is a pass through the view
                // body — four of them a frame is three redraws nobody asked for.
                mapRect = shown
                let (centre, width) = MercatorProjection.camera(of: shown, in: size)
                var wanted = camera
                wanted.centre = centre
                wanted.worldWidth = width
                if wanted != camera { camera = wanted }
                if !userMoved { userMoved = true }
            }
            // Transparent, and out of the way of the mouse: a click belongs to the map.
            canvas
                .allowsHitTesting(false)
            overlay
            // On its own, in the far corner: the layer switches are not map controls and
            // belong away from them.
            layers
            // And in the opposite corner, where the data came from.
            credit
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
        // The flight is fetched after the window opens, so the first layout often has no route
        // to frame. Framing it when it lands is the difference between opening on your flight
        // and opening on the whole world.
        .onChange(of: waypoints.count) { _, count in
            guard count > 1, !userMoved else { return }
            fitRoute()
        }
        // The fields this flight uses are wanted whatever the map is showing: you are going
        // to be on the ground at both ends of it.
        .onChange(of: flight.plan?.airfields.map(\.icao) ?? []) { _, _ in keepFlightLayouts() }
        .onAppear {
            // The coarsest tier as well as the wanted one, so there is always something to
            // fall back on while a finer one is read.
            geography.request(.coarse)
            geography.request(camera.detail)
            if camera.showsRunways { geography.requestRunways() }
            openAIP.refresh()
            requestLayers()
            keepFlightLayouts()
        }
        .onChange(of: browser.showsAirspace) { _, _ in requestLayers() }
        .onChange(of: browser.showsStateBorders) { _, _ in requestLayers() }
        .onChange(of: browser.showsCityNames) { _, _ in requestLayers() }
        // Zooming past a threshold is the only thing that calls for another tier, and the
        // request is idempotent: the store ignores one it already holds or is already reading.
        .onChange(of: camera.detail) { _, detail in
            geography.request(detail)
        }
        // Which airports are near enough to be worth a layout changes with the camera,
        // and working that out is not something to do on every frame of a drag.
        .onChange(of: camera) { _, _ in settle() }
        .onChange(of: camera.showsRunways) { _, shows in
            if shows { geography.requestRunways() }
        }
        .onDisappear {
        }
    }

    // MARK: - Drawing

    private var canvas: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            draw(in: &context, size: canvasSize)
        }
    }

    /// What is still drawn over the map rather than by it: the frontiers, the state lines
    /// and the graticule. Lines with no writing on them, which lag the map by a frame
    /// during a pan and have nothing to come loose from. Everything with a name on it is
    /// MapKit's, in one pass, because two passes on two timetables cannot keep their
    /// labels off each other.
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Against the map's own rectangle rather than a camera rebuilt from a centre and a
        // zoom. Reconstructing it would be close, and close is a runway beside its
        // photograph instead of on it.
        let sheet = MapSheet(rect: mapRect, size: size)

        // Frontiers, which are the one thing a photograph cannot show you. Not over
        // Apple's own map, which draws its own: two sets of frontiers a pixel apart is
        // worse than either alone.
        if !appleDrawsPlaces, let world = geography.best(for: camera.detail) {
            for shape in world.borders where sheet.mayShow(shape.cap) {
                context.stroke(sheet.path(line: shape.directions),
                               with: .color(Color(nsColor: Theme.border)),
                               style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
        }

        // State and province borders, fainter than a frontier between countries.
        if browser.showsStateBorders, !appleDrawsPlaces,
           camera.worldWidth >= MapLayerRoom.statesFrom {
            for shape in geography.states where sheet.mayShow(shape.cap) {
                context.stroke(sheet.path(line: shape.directions),
                               with: .color(Color(nsColor: Theme.stateBorder)),
                               lineWidth: 0.6)
            }
        }

        graticule(in: &context, sheet: sheet)
    }

    /// True when the view is close enough for the ground layout. Always drawn at that range:
    /// this close in, the shape of the field is the map.
    private var drawsGroundLayout: Bool {
        metresAcross <= MapLayerRoom.layoutWithin
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
        // Only while the globe is being looked at as a globe. Meridians thirty degrees apart
        // say which way it is turned; zoomed in on a city they are two grey lines ruled across
        // the view, saying nothing and getting in the way of what does. The cut is where the
        // deepest geography takes over, which is the same point the view stops being a globe
        // and starts being a place.
        guard camera.worldWidth < MapDetail.fineFrom else { return }

        let colour = Color(nsColor: Theme.separator).opacity(0.5)
        for line in Self.graticuleLines {
            context.stroke(sheet.path(line: line), with: .color(colour), lineWidth: 0.5)
        }
    }

    /// Asks for whichever layer tables are switched on.
    private func requestLayers() {
        if browser.showsAirspace { geography.requestAirspace() }
        if browser.showsStateBorders { geography.requestStates() }
        if browser.showsCityNames { geography.requestCities() }
        // The ground plans of the fields in view, biggest first, from ten times further out
        // than they are drawn — a layout takes a minute or two to arrive, and asking on the
        // way down means it is there when you get there.
        if metresAcross <= MapLayerRoom.layoutFetchWithin {
            ground.want(WorldData.airports(within: max(metresAcross / 2, 5_000),
                                           of: camera.centre))
        }
    }

    /// Holds on to the ground layouts for the flight's own airfields.
    private func keepFlightLayouts() {
        let fields = (plan?.airfields ?? []).compactMap { WorldData.airport($0.icao) }
        guard !fields.isEmpty else { return }
        ground.alwaysKeep(fields)
    }

    private var degreesAcross: Double { camera.degreesAcross(in: size) }

    /// How much ground the view spans, near enough. What the ground layout's thresholds are
    /// written in, because a kilometre is a kilometre whatever size the window is.
    private var metresAcross: Double { degreesAcross * 111_000 }

    private func zoom(by factor: CGFloat, around point: CGPoint?) {
        userMoved = true
        camera.zoom(by: factor, around: point, in: size)
    }

    /// Frames the flight, or the world when there is no flight loaded.
    /// Framing counts as putting the map back the way it was, so it clears that flag.
    /// Points the map at the camera, for the moves that are not gestures.
    private func show(_ wanted: MapCamera) {
        camera = wanted
        guard size.width > 0 else { return }
        mapRect = MercatorProjection.rect(centre: wanted.centre,
                                          worldWidth: Double(wanted.worldWidth), in: size)
    }

    private func fitRoute() {
        userMoved = false
        let points = waypoints.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            + pinned.map(\.coordinate)
        guard points.count > 1 else {
            // A globe filling the panel: its circumference is pi times its width on screen.
            show(MapCamera(centre: Coordinate(latitude: 25, longitude: -20),
                           worldWidth: max(min(size.width, size.height) * .pi, 900)))
            return
        }
        var wanted = camera
        wanted.fit(points, in: size)
        show(wanted)
    }


    // MARK: - Controls

    /// The Layers button, top right.
    private var layers: some View {
        Button {
            showsLayers.toggle()
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.ngSeparator)
        }
        .help("Layers")
        .popover(isPresented: $showsLayers, arrowEdge: .bottom) {
            MapLayerPanel()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

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
            }
            .controlSize(.small)

            Text(readout)
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

    /// Who to credit for what is actually on the sheet, in the far corner.
    ///
    /// Only for what is drawn: a credit for a layer that is switched off is noise, and a
    /// credit for one that is switched on but whose table is missing is a lie. Two of these
    /// are required — OpenStreetMap's by ODbL, openAIP's by CC BY-NC — and the other two are
    /// not, and are here because a map should say where it came from.
    private var credits: [String] {
        var found: [String] = []
        found.append("Natural Earth · borders and places")
        if browser.showsAirspace, !geography.airspace.isEmpty,
           !browser.airspaceClasses.isEmpty, camera.worldWidth >= MapLayerRoom.airspaceFrom {
            found.append("\(OpenAIP.attribution) · \(OpenAIP.licence)")
        }
        found.append("OurAirports · airports and runways")
        found.append(contentsOf: browser.baseMap.attribution)
        return found
    }

    /// What MapKit should draw for us, inside its own pass: the ground, the airspace, the
    /// runways, the towns, the airports and the route — everything with writing on it.
    ///
    /// None of the zoom thresholds are applied here. The renderer knows the zoom exactly,
    /// on the frame it is drawing, where this would be a frame behind it.
    private var chartFrame: ChartFrame {
        ChartFrame(layouts: drawsGroundLayout ? held : [],
                   showsGroundLayout: drawsGroundLayout,
                   showsStands: camera.worldWidth >= MapLayerRoom.standsFrom,
                   airspace: geography.airspace,
                   airspaceKinds: browser.showsAirspace ? browser.airspaceClasses : [],
                   runways: geography.runways,
                   cities: browser.showsCityNames && !appleDrawsPlaces ? geography.cities : [],
                   waypoints: waypoints,
                   airports: pinned,
                   onRoute: Set((plan?.airfields ?? []).map { $0.icao.uppercased() }))
    }

    /// Every layout in hand. The renderer culls them itself against whatever rectangle
    /// MapKit hands it, which is not the same rectangle as the view.
    private var held: [AirportLayout] {
        ground.layouts.values.sorted { $0.icao < $1.icao }
    }

    /// Works out what to fetch, once the map has stopped moving.
    ///
    /// This used to run on every camera change, which was fine when the camera only moved
    /// on a drag or a scroll notch. The map view moves it every frame now, and the work is
    /// not frame work: `WorldData.airports` walks all seventy-odd thousand airports on
    /// earth, which is about six milliseconds, and a frame at 120 Hz is eight. Asking on
    /// every one of them is most of a frame spent deciding what to download.
    ///
    /// Nothing is lost by waiting. These are all requests for things that take a second or
    /// a minute to arrive, and a fifth of a second after you stop moving is soon enough —
    /// it is arguably better, because a pan across a continent no longer queues a layout
    /// for every field it passes over.
    private func settle() {
        settling?.cancel()
        settling = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            requestLayers()
        }
    }

    /// True when the base is Apple's own map, which already has coastlines, frontiers,
    /// state lines and town names on it.
    ///
    /// Everything this app draws that Apple also draws is held back there. Not over the
    /// imagery: a photograph has no borders and no names, so those are exactly what it
    /// needs from us.
    private var appleDrawsPlaces: Bool { browser.baseMap == .appleMap }

    private var credit: some View {
        VStack(alignment: .trailing, spacing: 1) {
            ForEach(credits, id: \.self) { line in
                // Apple's own mark for Apple's own maps: the logo is in SF Symbols, which
                // is where a Mac app is meant to get it from.
                if line == BaseMap.appleAttribution {
                    HStack(spacing: 2) {
                        Image(systemName: "apple.logo").font(.system(size: 4.5))
                        Text(line)
                    }
                    .font(.ngCredit)
                    .foregroundStyle(.tertiary)
                } else {
                    Text(line)
                        .font(.ngCredit)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // On something, like the rest of the furniture: over a stack of airspace these are
        // four lines of grey text on a field of magenta, and unreadable without it.
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.ngSeparator)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // The map is underneath and takes every click; this is four lines of text.
        .allowsHitTesting(false)
    }

    /// Where the map is looking, how wide, and which of the two it is looking through.
    private var readout: String {
        "\(across) across · \(position) · \(browser.baseMap.name)"
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
