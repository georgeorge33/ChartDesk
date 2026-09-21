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
    /// The full coastline, when it is on this Mac and the zoom calls for it.
    @ObservedObject private var coastline = CoastlineStore.shared
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
                          rect: $mapRect) { shown in
                mapRect = shown
                let (centre, width) = MercatorProjection.camera(of: shown, in: size)
                camera.centre = centre
                camera.worldWidth = width
                userMoved = true
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
            requestCells()
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
        // Panning and zooming both change which cells of the full coastline are in view. The
        // request is idempotent and skips whatever is already read, so asking on every step
        // of a drag costs a set lookup.
        .onChange(of: camera) { _, _ in
            requestCells()
            requestLayers()
        }
        // The first ask for a cell only starts the index reading — fifteen megabytes of it,
        // off the main thread — and returns. Without this the cells were not asked for again
        // until something else moved the camera, so choosing full detail and sitting still
        // drew the simplified coast and said "OSM full" while doing it.
        .onChange(of: coastline.isReady) { _, _ in requestCells() }
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

    /// A label wanting a place on the map. Airports ask first, so a fix never pushes an
    /// airport's name off the map.
    private struct Label {
        let text: Text
        /// A second line, with a rule between — how a chart writes a ceiling over a floor.
        var under: Text?
        /// The rule's colour, so it matches the figures rather than the furniture.
        var ruleColour: Color?
        /// Filled behind the text, the way a ground chart writes a taxiway's letter.
        var box: Color?
        /// And drawn round it.
        var border: Color?
        let at: CGPoint
        let anchor: UnitPoint

        init(text: Text, under: Text? = nil, ruleColour: Color? = nil, box: Color? = nil,
             border: Color? = nil, at: CGPoint, anchor: UnitPoint) {
            self.text = text
            self.under = under
            self.ruleColour = ruleColour
            self.box = box
            self.border = border
            self.at = at
            self.anchor = anchor
        }
    }

    /// The air above and below the rule in a stacked label.
    private static let ruleGap: CGFloat = 2

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var labels: [Label] = []
        // Against the map's own rectangle rather than a camera rebuilt from a centre and a
        // zoom. Reconstructing it would be close, and close is a runway beside its
        // photograph instead of on it.
        let sheet = MapSheet(rect: mapRect, size: size)

        // The sea is simply what is behind everything, now the map is flat. On a globe it
        // was a disc that had to be drawn; a rectangle needs no drawing, and where Apple's
        // map is showing there is a photograph of the sea there already.
        if browser.baseMap == .vector {
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(nsColor: Theme.canvas)))
        }

        // Land, then the lakes cut back out of it, then borders — all from the one level of
        // detail, since a 1:10m coast beside a 1:50m border puts the frontier out at sea.
        //
        // Only for the drawn map. It used to be drawn under the tiles and hidden by them,
        // but the map view sits underneath now, and a grey Natural Earth landmass painted
        // over Apple's own coastline is exactly as wrong as it sounds.
        if browser.baseMap == .vector, let world = geography.best(for: camera.detail) {
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
                // Filled and not outlined, unlike every other layer. The full coastline comes
                // cut into pieces on a whole-degree grid so that no single polygon is enormous,
                // and those cuts run through the middle of the land: 3,130 perfectly straight
                // segments sitting on whole degrees, in a sample of one piece in forty.
                // Stroked, they draw as coastline — which is the grid of straight lines that
                // appeared across the land close in. The edge between land and sea is the edge
                // between two fills and needs no line of its own.
                fill(coastline.shapes(in: full),
                     colour: Color(nsColor: Theme.land),
                     stroke: .clear, width: 0,
                     in: &context, sheet: sheet)
            }

            fill(world.lakes, colour: Color(nsColor: Theme.canvas),
                 stroke: Color(nsColor: Theme.coast).opacity(0.8), width: 0.5,
                 in: &context, sheet: sheet)

        }


        // Frontiers on top of it — under the imagery they would be invisible, and a border
        // is the one thing imagery cannot show you. Not over Apple's own map, which draws
        // its own: two sets of frontiers a pixel apart is worse than either alone.
        if !appleDrawsPlaces, let world = geography.best(for: camera.detail) {
            for shape in world.borders where sheet.mayShow(shape.cap) {
                context.stroke(sheet.path(line: shape.directions),
                               with: .color(Color(nsColor: Theme.border)),
                               style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
        }

        // State and province borders, fainter than a frontier between countries. Outside the
        // block above because they are a layer of their own and do not wait on a coastline.
        if browser.showsStateBorders, !appleDrawsPlaces,
           camera.worldWidth >= MapLayerRoom.statesFrom {
            for shape in geography.states where sheet.mayShow(shape.cap) {
                context.stroke(sheet.path(line: shape.directions),
                               with: .color(Color(nsColor: Theme.stateBorder)),
                               lineWidth: 0.6)
            }
        }

        graticule(in: &context, sheet: sheet)

        groundLayout(in: &context, sheet: sheet, labels: &labels)
        airspace(in: &context, sheet: sheet, labels: &labels)
        runways(in: &context, sheet: sheet, labels: &labels)
        places(in: &context, sheet: sheet, labels: &labels)

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
            guard width > 0 else { continue }
            context.stroke(path, with: .color(stroke), lineWidth: width)
        }
    }

    /// The airport's ground plan: aprons, taxiways and runways, the way a ground chart
    /// draws them.
    ///
    /// Under the airspace and over everything else, because it is the closest thing on the
    /// sheet: by the time this draws, the view is a few kilometres across and the coastline
    /// is a straight line somewhere off the edge.
    private func groundLayout(in context: inout GraphicsContext, sheet: MapSheet,
                              labels: inout [Label]) {
        guard drawsGroundLayout else { return }
        // Every field on the sheet, not only the one nearest the middle. At twenty
        // kilometres across a city's two airports are often both in view, and drawing one
        // of them as a ground plan and the other as a bare strip at the same zoom looks
        // like the map has broken rather than like a decision.
        for layout in nearbyLayouts(sheet) {
            groundLayout(layout, in: &context, sheet: sheet, labels: &labels)
        }
    }

    private func groundLayout(_ layout: AirportLayout, in context: inout GraphicsContext,
                              sheet: MapSheet, labels: inout [Label]) {
        // Metres to points, which is what turns a width tag into a line you can see.
        let perMetre = Double(camera.worldWidth) / 40_075_017

        // The tarmac, but only where there is none underneath. Over imagery the pavement is
        // already in the picture and painting grey over it hides the very thing you chose
        // that base map to see — so there, only the markings are drawn.
        if !showsAppleMap {
            for apron in layout.aprons where sheet.mayShow(apron.cap) {
                let path = sheet.path(ring: MapShape(directions: apron.directions,
                                                     cap: apron.cap))
                guard !path.isEmpty else { continue }
                context.fill(path, with: .color(Color(nsColor: Theme.apron)))
            }
            // Where somebody has drawn the outline of the tarmac, that is the tarmac.
            // Taxiway outlines go down here with the rest of the taxiway surface; the
            // runway's own wait for the runway, which is drawn over everything that
            // crosses it.
            pavement(.taxiway, of: layout, in: &context, sheet: sheet)
            // Every surface wide first, so one taxiway's tarmac cannot paint over its
            // neighbour's centreline. Skipped where the outline above is the real thing:
            // inflating the line by its width tag would only put a fatter, wronger shape
            // on top of a measured one.
            for way in layout.taxiways where !way.paved && sheet.mayShow(way.cap) {
                let line = sheet.path(curve: way.directions)
                guard !line.isEmpty else { continue }
                context.stroke(line, with: .color(Color(nsColor: Theme.taxiway)),
                               style: StrokeStyle(lineWidth: max(way.width * perMetre, 1),
                                                  lineCap: .round, lineJoin: .round))
            }
        }

        // The runway, the way a ground chart draws one: the paved strip where there is no
        // photograph of it, a white line down each edge, and the broken line down the middle.
        // The edges are drawn whatever the base map is — over imagery they are what tell you
        // where the pavement stops, which a photograph taken at dusk does not.
        let marking = Color(nsColor: Theme.runwayMarking)
        if !showsAppleMap { pavement(.runway, of: layout, in: &context, sheet: sheet) }
        for way in layout.runways where sheet.mayShow(way.cap) {
            let wide = max(way.width * perMetre, 2)
            let line = sheet.path(straight: way.directions)
            guard !line.isEmpty else { continue }
            if !showsAppleMap && !way.paved {
                context.stroke(line, with: .color(Color(nsColor: Theme.runwayAsphalt)),
                               style: StrokeStyle(lineWidth: wide, lineCap: .butt))
            }
            guard wide > 4 else { continue }        // too narrow to have sides yet
            for edge in way.edges {
                let side = sheet.path(straight: edge)
                guard !side.isEmpty else { continue }
                context.stroke(side, with: .color(marking.opacity(0.85)),
                               style: StrokeStyle(lineWidth: min(max(wide * 0.05, 0.7), 1.6)))
            }
            // The piano keys, which are what say "runway" before any number is legible.
            guard wide > 10 else { continue }
            for bar in way.keys {
                let stripe = sheet.path(straight: bar)
                guard !stripe.isEmpty else { continue }
                context.stroke(stripe, with: .color(marking),
                               style: StrokeStyle(lineWidth: max(2.5 * perMetre, 1),
                                                  lineCap: .butt))
            }
        }

        // Then the markings.
        //
        // Only on the movement area. A taxilane is the lead into a stand on the apron, and
        // the yellow line down it is not the line a clearance is read from — painting it
        // the same as a taxiway makes the ramp look like somewhere you would be told to go.
        let centreline = max(1, min(2.5, 6 * perMetre))
        for way in layout.taxiways where way.isMovementArea && sheet.mayShow(way.cap) {
            let line = sheet.path(curve: way.directions)
            guard !line.isEmpty else { continue }
            context.stroke(line, with: .color(Color(nsColor: Theme.taxiLine)),
                           style: StrokeStyle(lineWidth: centreline, lineCap: .round,
                                              lineJoin: .round))
        }
        for way in layout.runways where sheet.mayShow(way.cap) {
            let line = sheet.path(straight: way.directions)
            guard !line.isEmpty else { continue }
            // Thirty metres of paint and twenty of gap, which is what is on the ground —
            // and measured in metres rather than in points, so a dash stays on the same
            // piece of tarmac as you zoom instead of sliding along the runway.
            context.stroke(line, with: .color(Color(nsColor: Theme.runwayMarking)),
                           style: StrokeStyle(lineWidth: centreline,
                                              dash: [max(30 * perMetre, 2),
                                                     max(20 * perMetre, 1.5)]))
        }

        // Where you stop and wait: the bar painted across the taxiway, square to it.
        for hold in layout.holds where hold.across.count == 2 {
            guard sheet.projection.faces(hold.direction) else { continue }
            let bar = sheet.path(line: hold.across)
            guard !bar.isEmpty else { continue }
            context.stroke(bar, with: .color(Color(nsColor: Theme.holdShort)),
                           style: StrokeStyle(lineWidth: max(centreline * 1.6, 1.5),
                                              lineCap: .butt))
        }

        layoutLabels(layout, sheet: sheet, labels: &labels)
    }

    /// Fills the pavement of one kind that OpenStreetMap has the outline of.
    ///
    /// Drawn in two passes rather than one so the layering survives: a runway is painted
    /// over every taxiway that meets it, which is both what a ground chart does and what
    /// the inflated centrelines this replaces already did.
    private func pavement(_ surface: AirportSurface, of layout: AirportLayout,
                          in context: inout GraphicsContext, sheet: MapSheet) {
        let colour = Color(nsColor: surface == .runway ? Theme.runwayAsphalt : Theme.taxiway)
        for slab in layout.pavement
        where (slab.surface == .runway) == (surface == .runway) && sheet.mayShow(slab.cap) {
            let path = sheet.path(ring: MapShape(directions: slab.directions, cap: slab.cap))
            guard !path.isEmpty else { continue }
            context.fill(path, with: .color(colour))
        }
    }

    /// The writing on the ground: taxiway designators, runway numbers at the ends they
    /// belong to, the holding positions and, closest in, the stands.
    private func layoutLabels(_ layout: AirportLayout, sheet: MapSheet,
                              labels: inout [Label]) {
        let yellow = Color(nsColor: Theme.taxiLine)

        for way in layout.taxiways
        where !way.ref.isEmpty && way.isMovementArea && sheet.mayShow(way.cap) {
            guard let at = middle(of: way, sheet: sheet) else { continue }
            labels.append(Label(text: Text(AirportLayout.designator(way.ref))
                                    .font(.ngSmallBold)
                                    .foregroundStyle(yellow),
                                box: .black, border: yellow,
                                at: at, anchor: .center))
        }

        // A runway's number goes at the end you would be looking at it from, which is the
        // end whose bearing matches it: 14L is painted where you line up to fly 140°.
        for way in layout.runways where !way.ref.isEmpty && sheet.mayShow(way.cap) {
            for (number, at) in AirportLayout.numbers(of: way) {
                guard sheet.projection.faces(at) else { continue }
                let point = sheet.projection.point(at)
                guard point.x > 0, point.x < sheet.size.width,
                      point.y > 0, point.y < sheet.size.height else { continue }
                labels.append(Label(text: Text(number)
                                        .font(.ngSmallBold)
                                        .foregroundStyle(Color.white),
                                    box: .black.opacity(0.55),
                                    at: point, anchor: .center))
            }
        }

        for hold in layout.holds where !hold.ref.isEmpty {
            guard sheet.projection.faces(hold.direction) else { continue }
            let at = sheet.projection.point(hold.direction)
            guard at.x > 0, at.x < sheet.size.width, at.y > 0, at.y < sheet.size.height
            else { continue }
            labels.append(Label(text: Text(hold.ref)
                                    .font(.ngSmallBold)
                                    .foregroundStyle(Color(nsColor: Theme.holdShort)),
                                box: .black, border: Color(nsColor: Theme.holdShort),
                                at: at, anchor: .center))
        }

        // Stands only at the very closest zooms: there are hundreds of them at a big field
        // and they are the last thing worth the space.
        guard camera.worldWidth >= MapLayerRoom.standsFrom else { return }
        for stand in layout.stands {
            guard sheet.projection.faces(stand.direction) else { continue }
            let at = sheet.projection.point(stand.direction)
            guard at.x > 0, at.x < sheet.size.width, at.y > 0, at.y < sheet.size.height
            else { continue }
            labels.append(Label(text: Text(stand.ref)
                                    .font(.ngSmall)
                                    .foregroundStyle(Color(nsColor: Theme.stand)),
                                at: at, anchor: .center))
        }
    }

    /// The middle of a way, on the sheet, when it is on the sheet at all.
    private func middle(of way: AirportLayout.Way, sheet: MapSheet) -> CGPoint? {
        let direction = way.directions[way.directions.count / 2]
        guard sheet.projection.faces(direction) else { return nil }
        let at = sheet.projection.point(direction)
        guard at.x > 0, at.x < sheet.size.width, at.y > 0, at.y < sheet.size.height
        else { return nil }
        return at
    }

    /// True when the view is close enough for the ground layout. Always drawn at that range:
    /// this close in, the shape of the field is the map.
    private var drawsGroundLayout: Bool {
        metresAcross <= MapLayerRoom.layoutWithin
    }

    /// The layouts on the sheet, of those that have been fetched.
    ///
    /// Asked of the layouts rather than of the airport table, which is the cheap way round.
    /// There are at most a few dozen layouts in hand and each already knows the circle it
    /// covers, so this is a few dozen cap tests; going the other way meant a dot product
    /// against all seventy-odd thousand airports on earth to find the handful that might
    /// have one, twice a frame, at about six milliseconds a time.
    ///
    /// It is also the more truthful question. The old one asked which airport was nearest
    /// the middle of the view; this asks which ground plans are actually on the screen.
    private func nearbyLayouts(_ sheet: MapSheet) -> [AirportLayout] {
        ground.layouts.values
            .filter { sheet.mayShow($0.cap) }
            .sorted { $0.icao < $1.icao }
    }

    /// Airspace, in the colours a chart uses: Class B solid blue, Class C magenta, Class D
    /// blue and dashed, and prohibited, restricted and danger areas red — each ring labelled
    /// with its ceiling over its floor.
    ///
    /// Drawn quietest first so the busier airspace reads over it, with the areas to keep out
    /// of on top of everything, and filled faintly as well as outlined: a Class B is four or
    /// five shelves stacked over one another and the fill is what shows which one you are
    /// under.
    private func airspace(in context: inout GraphicsContext, sheet: MapSheet,
                          labels: inout [Label]) {
        guard browser.showsAirspace, camera.worldWidth >= MapLayerRoom.airspaceFrom
        else { return }
        let rings = geography.airspace
        let kinds = browser.airspaceClasses
        guard !rings.isEmpty, !kinds.isEmpty else { return }

        // The table arrives sorted quietest first, so one pass in order paints the busy
        // airspace over the quiet without filtering by kind eight times over.
        //
        // A ring too small to read is left out rather than drawn as a speck: openAIP has
        // four times the FAA's rings and most of them are aerodrome-sized, so at a wide view
        // they are a wash of colour with no legible figure anywhere in it.
        let least = MapLayerRoom.leastRadius
        for space in rings where kinds.contains(space.klass) && sheet.mayShow(space.cap)
            && space.cap.radius * sheet.projection.radius >= least {
            let colour = Color(nsColor: Theme.airspace(space.klass))
            let path = sheet.path(ring: MapShape(directions: space.directions,
                                                 cap: space.cap))
            guard !path.isEmpty else { continue }
            context.fill(path, with: .color(colour.opacity(0.07)))
            context.stroke(path, with: .color(colour), style: Self.stroke(of: space.klass))

            // The ceiling and floor, out towards the ring's own edge.
            let where_ = space.labelAt
            guard sheet.projection.faces(where_.direction) else { continue }
            let at = sheet.point(where_)
            guard at.x > 0, at.x < sheet.size.width, at.y > 0, at.y < sheet.size.height
            else { continue }
            labels.append(Label(text: Text(space.ceilingLabel)
                                    .font(.ngSmallMono)
                                    .foregroundStyle(colour),
                                under: Text(space.floorLabel)
                                    .font(.ngSmallMono)
                                    .foregroundStyle(colour),
                                ruleColour: colour,
                                at: at, anchor: .center))
        }
    }

    /// Weight and dash per kind, following the chart: solid where entry is by clearance,
    /// dashed where the boundary is advisory or the area is only sometimes active.
    private static func stroke(of klass: AirspaceClass) -> StrokeStyle {
        switch klass {
        case .a: return StrokeStyle(lineWidth: 2)
        case .b: return StrokeStyle(lineWidth: 2.2)
        case .c: return StrokeStyle(lineWidth: 2)
        case .d: return StrokeStyle(lineWidth: 1.8, dash: [5, 3])
        case .e: return StrokeStyle(lineWidth: 1.5, dash: [2, 3])
        case .prohibited: return StrokeStyle(lineWidth: 2.4)
        case .restricted: return StrokeStyle(lineWidth: 2.1)
        case .danger: return StrokeStyle(lineWidth: 2, dash: [6, 3])
        }
    }

    /// The names of towns and cities, as many as there is room for.
    ///
    /// Asked for in rank order — Natural Earth's own, 0 for the places that belong on a world
    /// map — so the declutterer gives the space to the ones that matter, and anything that
    /// will not fit simply does not appear.
    private func places(in context: inout GraphicsContext, sheet: MapSheet,
                        labels: inout [Label]) {
        guard browser.showsCityNames, !appleDrawsPlaces, !geography.cities.isEmpty
        else { return }
        let deepest = MapLayerRoom.cityRank(degreesAcross: degreesAcross)
        let colour = Color(nsColor: Theme.place)

        for city in geography.cities where city.rank <= deepest {
            guard sheet.projection.faces(city.direction) else { continue }
            let at = sheet.point(city.coordinate)
            guard at.x > -20, at.x < sheet.size.width + 20,
                  at.y > -10, at.y < sheet.size.height + 10 else { continue }

            let dot = CGRect(x: at.x - 1.5, y: at.y - 1.5, width: 3, height: 3)
            context.fill(Path(ellipseIn: dot), with: .color(colour.opacity(0.8)))
            labels.append(Label(text: Text(city.name).font(.ngSmall).foregroundStyle(colour),
                                at: CGPoint(x: at.x + 4, y: at.y),
                                anchor: .leading))
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

        // Where the fetched layout covers this field, it draws the runways instead: it has
        // their real outline, their markings and their width, against a straight band drawn
        // between two thresholds. The bundled table still draws every other airport on
        // earth, which is what it is for.
        let drawnByLayout = drawsGroundLayout ? nearbyLayouts(sheet).map(\.cap) : []

        let colour = Color(nsColor: Theme.runway)
        let named = camera.worldWidth >= 500_000
        // Feet across, in points. The globe is drawn to one scale at the middle of the view,
        // so this is the same arithmetic wherever on Earth the runway is — which under
        // Mercator it was not.
        let perFoot = 0.3048 / 6_371_000 * camera.radius

        for runway in geography.runways where sheet.mayShow(runway.cap) {
            if drawnByLayout.contains(where: {
                simd_dot($0.centre, runway.cap.centre) > cos($0.radius)
            }) {
                continue
            }
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
            let room = CGSize(width: 200, height: 40)
            let topSize = resolved.measure(in: room)

            // A second line sits under a rule, and the two together are what has to be
            // measured for space — kept apart from the first line's own height, which is what
            // the rule is positioned from. Using the combined height for both put the rule
            // and the floor on top of one another.
            var below: (text: GraphicsContext.ResolvedText, size: CGSize)?
            if let under = label.under {
                let resolvedBelow = context.resolve(under)
                below = (resolvedBelow, resolvedBelow.measure(in: room))
            }

            let measured = below.map {
                CGSize(width: max(topSize.width, $0.size.width),
                       height: topSize.height + Self.ruleGap * 2 + $0.size.height)
            } ?? topSize
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
            if let box = label.box {
                let around = frame.insetBy(dx: -2.5, dy: -1.5)
                let shape = Path(roundedRect: around, cornerRadius: 2)
                context.fill(shape, with: .color(box))
                if let border = label.border {
                    context.stroke(shape, with: .color(border), lineWidth: 0.8)
                }
            }
            guard let below = below else {
                context.draw(resolved, at: label.at, anchor: label.anchor)
                continue
            }

            // Ceiling over floor with a rule between, the way a chart writes it: the rule sits
            // a hair under the ceiling and the floor a hair under the rule.
            let middle = frame.midX
            context.draw(resolved, at: CGPoint(x: middle, y: frame.minY), anchor: .top)

            let ruleY = frame.minY + topSize.height + Self.ruleGap
            var rule = Path()
            rule.move(to: CGPoint(x: middle - measured.width / 2, y: ruleY))
            rule.addLine(to: CGPoint(x: middle + measured.width / 2, y: ruleY))
            context.stroke(rule, with: label.ruleColour.map { .color($0) } ?? .color(.secondary),
                           lineWidth: 0.8)

            context.draw(below.text, at: CGPoint(x: middle, y: ruleY + Self.ruleGap),
                         anchor: .top)
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

    private func route(in context: inout GraphicsContext, sheet: MapSheet,
                       labels: inout [Label]) {
        // Two passes so the enroute line and the procedure legs each read as one colour
        // rather than alternating down the route.
        for procedure in [false, true] {
            let colour = procedure ? Color.orange : Color(nsColor: Theme.route)
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
                         with: .color(waypoint.isProcedure ? Color.orange
                                                           : Color(nsColor: Theme.route)))
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
        let colour = onRoute ? Color(nsColor: Theme.route) : Color.secondary
        let box = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: box), with: .color(colour))
        context.stroke(Path(ellipseIn: box.insetBy(dx: -2, dy: -2)),
                       with: .color(colour.opacity(0.5)), lineWidth: 1)

        labels.append(Label(text: Text(airport.icao)
                                .font(.ngSmallBold)
                                .foregroundStyle(onRoute ? Color(nsColor: Theme.route)
                                                         : Color.secondary),
                            at: CGPoint(x: point.x, y: point.y + 8),
                            anchor: .top))
    }

    /// True when the zoom is close enough for the full coastline to be worth reading, and it
    /// is on this Mac.
    private var showsFullCoastline: Bool {
        camera.worldWidth >= MapDetail.fullFrom && coastline.isReady
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

    /// Asks for the cells of the full coastline the view covers.
    private func requestCells() {
        guard camera.worldWidth >= MapDetail.fullFrom, size.width > 0 else { return }
        coastline.request(MapSheet(camera: camera, size: size).coastlineCells())
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
        // Under Apple's imagery the drawn coast is there but invisible, and a credit for
        // something nobody can see is clutter rather than honesty.
        var found: [String] = []
        if !showsAppleMap {
            found.append("\(Coastline.attribution) · \(Coastline.licence)")
        }
        found.append("Natural Earth · lakes, borders, places")
        if browser.showsAirspace, !geography.airspace.isEmpty,
           !browser.airspaceClasses.isEmpty, camera.worldWidth >= MapLayerRoom.airspaceFrom {
            found.append("\(OpenAIP.attribution) · \(OpenAIP.licence)")
        }
        found.append("OurAirports · airports and runways")
        if showsAppleMap { found.append(contentsOf: browser.baseMap.attribution) }
        return found
    }

    /// True when the base is Apple's own map, which already has coastlines, frontiers,
    /// state lines and town names on it.
    ///
    /// Everything this app draws that Apple also draws is held back there. Not over the
    /// imagery — a photograph has no borders and no names, so those are exactly what it
    /// needs from us — and not over the drawn map, which has nothing else.
    private var appleDrawsPlaces: Bool { browser.baseMap == .appleMap }

    /// True when either of Apple's maps is under everything, which is when the ground
    /// layout stops painting tarmac it would be covering a photograph with.
    private var showsAppleMap: Bool {
        browser.baseMap.needsNetwork
    }

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

    /// Where the map is looking, how wide, and which of the three worlds it is drawing —
    /// so that the tier is something you can see rather than infer. An ellipsis while a finer
    /// one is still being read.
    private var readout: String {
        // Which map you are looking at, which under imagery is not the coastline tier.
        if showsAppleMap { return "\(across) across · \(position) · \(browser.baseMap.name)" }
        var tier = showsFullCoastline ? "OSM full" : "\(camera.detail)"
        if geography.isCatchingUp(to: camera.detail) {
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
