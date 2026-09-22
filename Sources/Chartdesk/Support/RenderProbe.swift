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
/// The overlay is drawn the way MapKit draws it — in 512-point tiles, each told the zoom
/// scale of the level below, with the true scale handed over separately — so what comes
/// out is what the tiles would show, seams included.
enum RenderProbe {

    static func runIfAsked() {
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
        guard let data = try? Data(contentsOf: AirportLayoutStore.file(for: icao)),
              let layout = AirportLayoutStore.parse(data, icao: icao) else {
            FileHandle.standardError.write("no cached layout for \(icao)\n".data(using: .utf8)!)
            return false
        }

        // What the parser made of the runways, since that is where most of what can go
        // wrong with the paint goes wrong.
        for way in layout.runways {
            let ends = [way.directions.first, way.directions.last].compactMap { $0 }
                .map { Coordinate($0) }
                .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
            print("runway \(way.ref.isEmpty ? "?" : way.ref): \(way.directions.count) points, "
                  + "\(Int(way.width))m wide, ends \(ends.joined(separator: " → ")), "
                  + "\(way.keys.count) keys, \(way.zones.count) zones, "
                  + "names \(way.names.map(\.text))")
        }

        let view = CGSize(width: 1100, height: 700)
        let pixels = 2.0
        let centre = looking ?? Coordinate(layout.frame.centre)
        let latitude = centre.latitude * .pi / 180
        let perMetre = MKMapSize.world.width / (40_075_017 * max(cos(latitude), 0.02))
        let wide = metresAcross * perMetre
        let middle = MKMapPoint(CLLocationCoordinate2D(latitude: centre.latitude,
                                                       longitude: centre.longitude))
        let rect = MKMapRect(x: middle.x - wide / 2,
                             y: middle.y - wide * Double(view.height / view.width) / 2,
                             width: wide, height: wide * Double(view.height / view.width))

        let renderer = ChartRenderer(overlay: ChartOverlay())
        renderer.frame = ChartFrame(layouts: [layout], showsGroundLayout: true,
                                    showsStands: metresAcross <= 1_500)
        let truth = Double(view.width) / rect.width
        renderer.page = rect.width / Double(view.width)

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
                renderer.draw(piece, zoomScale: MKZoomScale(level), in: context)
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
        print("drew \(icao) at \(Int(metresAcross)) m across into \(out.path)")
        return true
    }
}
#endif
