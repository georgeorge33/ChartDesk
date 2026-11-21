#if DEBUG
import AppKit
import MapKit

/// Draws the chart overlay into a picture and nothing else, then quits.
///
/// For checking what the renderer draws without driving the app: no window, no map view,
/// no library, and none of the app's state is created, so nothing the app would change is
/// touched. Debug builds only.
///
///     CHARTDESK_RENDER="KBOS 2700 /tmp/out.png [dark|light] [lat,lon]" Chartdesk
///
/// The ground layout alone by default. `CHARTDESK_RENDER_LAYERS=all` adds the airspace,
/// the bundled runways, the towns, and the cached flight with its airports — all read, none
/// written — and `CHARTDESK_RENDER_ROUTE="lat,lon lat,lon …"` draws that route instead of
/// the cached one, for routes the cached flight does not fly, like one over the
/// antimeridian. An ICAO of "-" draws no layout at all. Run it from inside an app bundle
/// for the bundled tables to be found.
///
/// The overlay is drawn the way MapKit draws it — in 512-point tiles, each told the zoom
/// scale of the level below, with the true scale handed over separately — so what comes
/// out is what the tiles would show, seams included.
enum RenderProbe {

    /// `CHARTDESK_OPEN_MAP="lat,lon metres"`: open on the route map looking there, that
    /// many metres across, instead of on the flight — for seeing what the live MapKit
    /// pipeline draws without clicking through the app to get there.
    static let openAt: (centre: Coordinate, metres: Double)? = {
        guard let spec = ProcessInfo.processInfo.environment["CHARTDESK_OPEN_MAP"] else {
            return nil
        }
        let parts = spec.split(separator: " ")
        guard parts.count == 2, let metres = Double(parts[1]) else { return nil }
        let figures = parts[0].split(separator: ",").compactMap { Double($0) }
        guard figures.count == 2 else { return nil }
        return (Coordinate(latitude: figures[0], longitude: figures[1]), metres)
    }()

    /// `CHARTDESK_ZOOM_TEST`: a few seconds after opening, zoom in by half again, a step a
    /// frame the way a gesture does, so that what follows the map during motion can be
    /// looked at without anyone's hand on the mouse.
    static let zoomsItself = ProcessInfo.processInfo.environment["CHARTDESK_ZOOM_TEST"] != nil

    /// `CHARTDESK_SCROLL_TEST`: a few seconds after opening, turn the wheel in and back out
    /// again, timing it.
    static let scrollsItself = ProcessInfo.processInfo.environment["CHARTDESK_SCROLL_TEST"] != nil

    /// What the labels did while the map moved: how many times they were put on it, and
    /// how many of them were left alone, changed, added and taken off.
    @MainActor static var churn = Churn()

    struct Churn {
        private var updates = 0, labels = 0, changed = 0, added = 0, removed = 0

        mutating func record(labels: Int, changed: Int, added: Int, removed: Int) {
            updates += 1
            self.labels += labels
            self.changed += changed
            self.added += added
            self.removed += removed
        }

        var summary: String {
            "labels: \(updates) updates of \(updates > 0 ? labels / updates : 0) on average; "
                + "\(labels - changed - added) left alone, \(changed) changed, "
                + "\(added) added, \(removed) taken off"
        }
    }

    /// How long the main thread took to come back between frames of a test, and how much
    /// of that the map's own zoom call took.
    final class Ticks: @unchecked Sendable {
        private var last: Double?
        private var gaps: [Double] = []
        private var calls: [Double] = []

        func tick(_ now: Double) {
            if let last { gaps.append((now - last) * 1000) }
            last = now
        }

        func spent(_ seconds: Double) { calls.append(seconds * 1000) }

        @MainActor
        func report(annotations: Int, frame: Double) {
            func line(_ name: String, _ values: [Double]) -> String {
                let sorted = values.sorted()
                guard !sorted.isEmpty else { return "\(name): none" }
                let mean = sorted.reduce(0, +) / Double(sorted.count)
                return String(format: "%@: %d, mean %.1f ms, median %.1f, p95 %.1f, max %.1f",
                              name, sorted.count, mean, sorted[sorted.count / 2],
                              sorted[min(sorted.count - 1, sorted.count * 95 / 100)],
                              sorted.last!)
            }
            let budget = frame * 1000
            let late = gaps.filter { $0 > budget * 1.5 }.count
            let missed = gaps.reduce(0) { $0 + max(Int(($1 / budget).rounded()) - 1, 0) }
            let text = [line("gaps between notches", gaps),
                        line("time in the zoom call", calls),
                        String(format: "display frame %.1f ms; %d of %d notches late, %d frames missed; ",
                               budget, late, gaps.count, missed)
                            + "annotations on the map: \(annotations)",
                        RenderProbe.churn.summary]
                .map { "scroll test " + $0 }.joined(separator: "\n")
            FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
        }
    }

    /// `CHARTDESK_SHOW_LAYERS`: open the route map's Layers panel as the map appears.
    static let showsLayers = ProcessInfo.processInfo.environment["CHARTDESK_SHOW_LAYERS"] != nil

    /// Once the window is up: `CHARTDESK_FETCH_LAYOUTS="KBOS KBED"` fetches those airports'
    /// layouts the way Fetch Layouts for Your Airports does, and `CHARTDESK_SHOW_LAYOUTS`
    /// opens the Airport Layouts window — for watching both without a hand on the mouse.
    @MainActor
    static func appeared() {
        let environment = ProcessInfo.processInfo.environment
        if let codes = environment["CHARTDESK_FETCH_LAYOUTS"] {
            AirportLayoutStore.shared.fetchLayouts(for: codes.split(separator: " ").map(String.init))
        }
        if environment["CHARTDESK_SHOW_LAYOUTS"] != nil {
            NotificationCenter.default.post(name: .showAirportLayouts, object: nil)
        }
    }

    /// `CHARTDESK_LOG_TILES`: say, once for each zoom, what MapKit hands the renderer — the
    /// zoom scale, the true scale, and how many pixels of tile a screen point gets.
    static let logsTiles = ProcessInfo.processInfo.environment["CHARTDESK_LOG_TILES"] != nil

    static func runIfAsked() {
        // `CHARTDESK_GATEWAY="KBOS KBUR"`: each airport asked of the X-Plane Gateway the way
        // the map asks, timed, and written to the layout cache — so run it with
        // CHARTDESK_LAYOUTS pointing somewhere of its own, as a test copy does.
        if let codes = ProcessInfo.processInfo.environment["CHARTDESK_GATEWAY"] {
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                for code in codes.split(separator: " ").map(String.init) {
                    let started = Date()
                    let outcome = await XPlaneGateway.refresh(code)
                    let took = String(format: "%.2f s", -started.timeIntervalSinceNow)
                    switch outcome {
                    case .layout(let layout, let changed):
                        print("\(code): \(changed ? "fetched" : "unchanged") in \(took) — "
                              + describe(layout))
                    case .absent:
                        print("\(code): nothing worth drawing on the Gateway (\(took)), "
                              + "noted as \(XPlaneGateway.note(for: code)?.status.rawValue ?? "?")")
                    case .failed(let problem):
                        print("\(code): failed in \(took): \(problem)")
                    }
                }
                finished.signal()
            }
            finished.wait()
            exit(0)
        }
        // `CHARTDESK_PARSE_PLAN=ofp.json`: a SimBrief answer read the way a fetched one is, and
        // the airports the app would load for it.
        if let path = ProcessInfo.processInfo.environment["CHARTDESK_PARSE_PLAN"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                print("cannot read \(path)"); exit(1)
            }
            switch SimBrief.parse(data) {
            case .failure(let problem): print("did not parse: \(problem.message)")
            case .success(let plan):
                print("flight: " + plan.airfields.map { "\($0.role.badge) \($0.icao)" }.joined(separator: ", "))
                print("other alternates: \((plan.otherAirports ?? []).joined(separator: " "))")
                print("layouts loaded for: \(plan.allAirports.joined(separator: " "))")
                print("briefing: \(plan.briefing.map { "\($0.count) characters" } ?? "none"), "
                      + "PDF \(plan.briefingPDF ?? "none"), layout \(plan.layout ?? "?"), "
                      + "made \(plan.generatedAt.map { "\($0)" } ?? "?")")
                // With CHARTDESK_FLIGHT, saved there as the app saves a fetched plan, for a
                // test copy to open.
                if let out = ProcessInfo.processInfo.environment["CHARTDESK_FLIGHT"],
                   let saved = try? JSONEncoder().encode(plan) {
                    try? saved.write(to: URL(fileURLWithPath: out), options: .atomic)
                    print("saved to \(out)")
                }
            }
            exit(0)
        }
        // Every cached layout parsed and counted, for checking a change to the parser
        // against all of them at once.
        if ProcessInfo.processInfo.environment["CHARTDESK_PARSE_ALL"] != nil {
            let airportFiles = (try? FileManager.default.contentsOfDirectory(
                at: XPlaneGateway.directory, includingPropertiesForKeys: nil)) ?? []
            for file in airportFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension == "dat" {
                let icao = file.deletingPathExtension().lastPathComponent
                let started = Date()
                guard let data = try? Data(contentsOf: file),
                      let layout = XPlaneGateway.drawn(from: data, icao: icao, scenery: 0,
                                                       fetched: Date()) else {
                    print("\(icao): did not read"); continue
                }
                print("\(icao) (\(String(format: "%.0f ms", -started.timeIntervalSinceNow * 1000))): "
                      + describe(layout))
            }
            exit(0)
        }
        guard let spec = ProcessInfo.processInfo.environment["CHARTDESK_RENDER"] else { return }
        let parts = spec.split(separator: " ").map(String.init)
        guard parts.count >= 3, let across = Double(parts[1]) else {
            FileHandle.standardError.write("CHARTDESK_RENDER: ICAO metres out.png [dark|light]\n"
                .data(using: .utf8)!)
            exit(2)
        }
        let shade = parts.count > 3 ? parts[3] : "dark"
        var looking: Coordinate?
        if parts.count > 4 {
            let figures = parts[4].split(separator: ",").compactMap { Double($0) }
            if figures.count == 2 { looking = Coordinate(latitude: figures[0], longitude: figures[1]) }
        }
        let done = MainActor.assumeIsolated {
            draw(icao: parts[0].uppercased(), metresAcross: across,
                 to: URL(fileURLWithPath: parts[2]), light: shade == "light", at: looking)
        }
        exit(done ? 0 : 1)
    }

    /// Apple's map of a rectangle, dark, as the app shows it: its Map or its imagery.
    ///
    /// A map view only draws while its window can be seen, and a test copy should not put
    /// one in front of whatever you are doing to find out what it looks like. A snapshot
    /// needs no window at all.
    @MainActor
    private static func snapshot(_ rect: MKMapRect, size: CGSize, satellite: Bool) -> CGImage? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.appearance = NSAppearance(named: .darkAqua)
        options.preferredConfiguration = satellite
            ? MKImageryMapConfiguration(elevationStyle: .flat)
            : MKStandardMapConfiguration(elevationStyle: .flat)
        var picture: CGImage?
        var finished = false
        MKMapSnapshotter(options: options).start { result, error in
            if let image = result?.image {
                var frame = CGRect(origin: .zero, size: image.size)
                picture = image.cgImage(forProposedRect: &frame, context: nil, hints: nil)
            } else {
                FileHandle.standardError.write("no snapshot: \(error?.localizedDescription ?? "?")\n"
                    .data(using: .utf8)!)
            }
            finished = true
        }
        let deadline = Date(timeIntervalSinceNow: 30)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return picture
    }

    /// A layout counted up, in a line.
    private static func describe(_ layout: AirportLayout) -> String {
        let yellow = layout.markings.filter { $0.style.colour == .yellow }.count
        return "\(layout.runways.count) runways, "
            + "\(layout.ends.count) displaced or pads, "
            + "\(layout.taxiways.filter(\.isMovementArea).count) named taxiway lines, "
            + "\(layout.pavement.count) pavement, \(layout.markings.count) painted lines "
            + "(\(yellow) yellow), \(layout.holds.count) holds, \(layout.stands.count) stands"
    }

    /// The view is 1100 by 700 points, at two pixels to the point.
    @MainActor
    private static func draw(icao: String, metresAcross: Double, to out: URL,
                             light: Bool, at looking: Coordinate?) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        var layout: AirportLayout?
        // The copy on this Mac, or with CHARTDESK_RENDER_DAT an airport file read directly,
        // without the cache.
        if icao != "-", let path = environment["CHARTDESK_RENDER_DAT"] {
            let started = Date()
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let made = XPlaneGateway.drawn(from: data, icao: icao, scenery: 0,
                                                 fetched: Date()) else {
                FileHandle.standardError.write("\(path) has no layout for \(icao)\n".data(using: .utf8)!)
                return false
            }
            print(String(format: "read %@ in %.0f ms: ", path, -started.timeIntervalSinceNow * 1000)
                  + describe(made))
            layout = made
        } else if icao != "-" {
            guard let made = XPlaneGateway.cached(icao) else {
                FileHandle.standardError.write("no layout on this Mac for \(icao)\n".data(using: .utf8)!)
                return false
            }
            print("on this Mac: " + describe(made))
            layout = made
        }

        // What the parser made of the runways, since that is where most of what can go
        // wrong with the paint goes wrong.
        for way in layout?.runways ?? [] {
            let ends = [way.directions.first, way.directions.last].compactMap { $0 }
                .map { Coordinate($0) }
                .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
            print("runway \(way.ref.isEmpty ? "?" : way.ref): \(way.directions.count) points, "
                  + "\(Int(way.width))m wide, ends \(ends.joined(separator: " → ")), "
                  + "\(way.keys.count) keys, \(way.zones.count) zones, "
                  + "names \(way.names.map(\.text))")
        }
        for end in layout?.ends ?? [] {
            let middle = Coordinate(end.cap.centre)
            print(String(format: "end %@ at %.5f,%.5f: %d marks",
                         end.kind == .pad ? "pad" : "displaced", middle.latitude,
                         middle.longitude, end.marks.count))
        }

        let view = CGSize(width: 1100, height: 700)
        let pixels = 2.0
        guard let centre = looking ?? layout.map({ Coordinate($0.frame.centre) }) else {
            FileHandle.standardError.write("no layout and no lat,lon to look at\n".data(using: .utf8)!)
            return false
        }
        let latitude = centre.latitude * .pi / 180
        let perMetre = MKMapSize.world.width / (40_075_017 * max(cos(latitude), 0.02))
        let wide = metresAcross * perMetre
        let middle = MKMapPoint(CLLocationCoordinate2D(latitude: centre.latitude,
                                                       longitude: centre.longitude))
        let rect = MKMapRect(x: middle.x - wide / 2,
                             y: middle.y - wide * Double(view.height / view.width) / 2,
                             width: wide, height: wide * Double(view.height / view.width))

        var frame = ChartFrame(layouts: layout.map { [$0] } ?? [],
                               showsGroundLayout: layout != nil && metresAcross <= 20_000,
                               showsStands: metresAcross <= 1_500)
        if environment["CHARTDESK_RENDER_LAYERS"] == "all" {
            frame.airspace = WorldData.loadAirspace()
            frame.airspaceKinds = Set(AirspaceClass.allCases)
            frame.runways = WorldData.loadRunways()
            // Over the imagery only, as the app does: Apple's own map has its own towns.
            if light { frame.cities = WorldData.loadCities() }
            if let data = try? Data(contentsOf: FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Chartdesk/flight.json")),
               let plan = try? JSONDecoder().decode(FlightPlan.self, from: data) {
                frame.waypoints = plan.waypoints
                frame.airports = plan.airfields.compactMap { WorldData.airport($0.icao) }
                frame.onRoute = Set(plan.airfields.map { $0.icao.uppercased() })
            }
        }
        if let route = environment["CHARTDESK_RENDER_ROUTE"] {
            frame.waypoints = route.split(separator: " ").enumerated().compactMap { index, text in
                let figures = text.split(separator: ",").compactMap { Double($0) }
                guard figures.count == 2 else { return nil }
                return FlightPlan.Waypoint(ident: "P\(index)", latitude: figures[0],
                                           longitude: figures[1], via: nil,
                                           isProcedure: false, altitude: nil, kind: "wpt")
            }
        }
        print("frame: \(frame.airspace.count) airspace, \(frame.runways.count) runways, "
              + "\(frame.cities.count) towns, \(frame.waypoints.count) waypoints, "
              + "\(frame.airports.count) airports")

        let renderer = ChartRenderer(overlay: ChartOverlay())
        renderer.frame = frame
        let truth = Double(view.width) / rect.width
        renderer.page = rect.width / Double(view.width)
        // As the map view would say, so the region the labels are looked for in is the
        // one the app would use.
        renderer.view = rect

        let width = Int(view.width * pixels), height = Int(view.height * pixels)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }

        // Something like each of Apple's two maps underneath, so the contrast is honest — or,
        // with CHARTDESK_RENDER_BASE=map or satellite, Apple's own, from a snapshot of the
        // same rectangle, which needs the network and no window.
        context.setFillColor(light ? CGColor(srgbRed: 0.62, green: 0.63, blue: 0.60, alpha: 1)
                                   : CGColor(srgbRed: 0.17, green: 0.20, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let base = environment["CHARTDESK_RENDER_BASE"],
           let picture = snapshot(rect, size: view, satellite: base == "satellite") {
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        // MapKit's convention: y runs down the page, in map points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: truth * pixels, y: truth * pixels)
        context.translateBy(x: -rect.minX, y: -rect.minY)

        let started = Date()
        var tiles = 0, first = 0.0, rest = 0.0
        // The level below the true one, as MapKit hands it to a renderer.
        let level = pow(2, floor(log2(truth)))
        let tile = 512 / level
        var y = floor(rect.minY / tile) * tile
        while y < rect.maxY {
            var x = floor(rect.minX / tile) * tile
            while x < rect.maxX {
                let piece = MKMapRect(x: x, y: y, width: tile, height: tile)
                context.saveGState()
                // A pixel over on the far sides. MapKit renders each tile into an image of
                // its own, aligned to the pixels; drawn into one bitmap, a clip on a
                // fractional pixel lets the background through the antialiased seam and
                // draws a hairline across the map that MapKit never would.
                let spill = 1 / (truth * pixels)
                context.clip(to: CGRect(x: x, y: y, width: tile + spill, height: tile + spill))
                let before = Date()
                renderer.draw(piece, zoomScale: MKZoomScale(level), in: context)
                let took = -before.timeIntervalSinceNow * 1000
                if tiles == 0 { first = took } else { rest += took }
                tiles += 1
                context.restoreGState()
                x += tile
            }
            y += tile
        }

        // The writing, which the app places as annotation views drawn at the screen's own
        // resolution: drawn here the same way, once, over the tiles.
        if let placed = renderer.placedLabels(margin: 0) {
            let chart = ChartContext(cg: context, mapPointsPerScreenPoint: placed.scale)
            for label in placed.labels { chart.draw(label) }
            print("labels placed: \(placed.labels.count)")
        }

        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png,
                                                                         properties: [:])
        else { return false }
        do { try png.write(to: out) } catch { return false }
        // The first tile works the frame out for every tile after it, so the two halves
        // are what a zoom step costs and what a tile costs.
        print(String(format: "settling and the first tile %.1f ms; %d more tiles %.1f ms, %.1f each",
                     first, tiles - 1, rest, tiles > 1 ? rest / Double(tiles - 1) : 0))
        print("drew \(icao) at \(Int(metresAcross)) m across into \(out.path) "
              + "in \(String(format: "%.0f", -started.timeIntervalSinceNow * 1000)) ms")
        return true
    }
}
#endif
