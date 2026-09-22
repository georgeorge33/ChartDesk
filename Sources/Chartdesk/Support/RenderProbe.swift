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

    static func runIfAsked() {
        // Every cached layout parsed and counted, for checking a change to the parser
        // against all of them at once.
        if ProcessInfo.processInfo.environment["CHARTDESK_PARSE_ALL"] != nil {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: AirportLayoutStore.directory, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension == "json" {
                let icao = file.deletingPathExtension().lastPathComponent
                guard let data = try? Data(contentsOf: file),
                      let layout = AirportLayoutStore.parse(data, icao: icao) else {
                    print("\(icao): did not parse"); continue
                }
                let displaced = layout.ends.filter { $0.kind == .displaced }.count
                let pads = layout.ends.count - displaced
                let unnamed = layout.runways.filter { $0.names.isEmpty }.map { $0.ref.isEmpty ? "?" : $0.ref }
                print("\(icao): \(layout.runways.count) runways, \(displaced) displaced, "
                      + "\(pads) pads, \(AirportLayoutStore.isComplete(data) ? "complete" : "older")"
                      + (unnamed.isEmpty ? "" : ", unnamed: \(unnamed.joined(separator: " "))"))
            }
            exit(0)
        }
        // The top-up's query for one airport, printed exactly as it would be sent.
        if let icao = ProcessInfo.processInfo.environment["CHARTDESK_ENDS_QUERY"] {
            let where_ = MainActor.assumeIsolated { WorldData.airport(icao)?.coordinate }
            print(AirportLayoutStore.endsQuery(icao: icao.uppercased(),
                                               at: where_ ?? Coordinate(latitude: 0, longitude: 0)))
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

    /// The view is 1100 by 700 points, at two pixels to the point.
    @MainActor
    private static func draw(icao: String, metresAcross: Double, to out: URL,
                             light: Bool, at looking: Coordinate?) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        var layout: AirportLayout?
        if icao != "-" {
            // CHARTDESK_RENDER_EXTRA is another Overpass answer to fold in, in memory
            // only — for trying out what a top-up would add without writing the cache.
            var cached = try? Data(contentsOf: AirportLayoutStore.file(for: icao))
            if let extra = environment["CHARTDESK_RENDER_EXTRA"],
               let more = try? Data(contentsOf: URL(fileURLWithPath: extra)),
               let base = cached,
               var top = try? JSONSerialization.jsonObject(with: base) as? [String: Any],
               let added = (try? JSONSerialization.jsonObject(with: more) as? [String: Any])?["elements"]
                   as? [[String: Any]] {
                top["elements"] = ((top["elements"] as? [[String: Any]]) ?? []) + added
                cached = try? JSONSerialization.data(withJSONObject: top)
                print("folded in \(added.count) more elements from \(extra)")
            }
            guard let data = cached,
                  let parsed = AirportLayoutStore.parse(data, icao: icao) else {
                FileHandle.standardError.write("no cached layout for \(icao)\n".data(using: .utf8)!)
                return false
            }
            layout = parsed
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

        // Something like each of Apple's two maps underneath, so the contrast is honest.
        context.setFillColor(light ? CGColor(srgbRed: 0.62, green: 0.63, blue: 0.60, alpha: 1)
                                   : CGColor(srgbRed: 0.17, green: 0.20, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

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
