import AppKit
import Foundation
import MapKit
import simd

/// What the map draws underneath everything else.
///
/// Drawn geography is the default and always will be: it is the only one that works with the
/// network off, which is most of the point of this app. The other two are Apple Maps, by way
/// of `MKMapSnapshotter` — no key, no account, and Apple carries the licensing of the
/// imagery itself. What they cost is the network: Apple does not permit an app to keep its
/// own copy of map imagery, so unlike the coastline these cannot be built once and kept.
enum BaseMap: String, CaseIterable, Identifiable {

    /// Natural Earth and OpenStreetMap, drawn as shapes. Works on a plane.
    case vector
    /// Apple's standard map with realistic elevation: relief and place names.
    case topographic
    /// Apple's imagery.
    case satellite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .vector: return "Drawn"
        case .topographic: return "Topographic"
        case .satellite: return "Satellite"
        }
    }

    var detail: String {
        switch self {
        case .vector:
            return "Coastline, lakes and borders, drawn from the tables in the app. The only "
                 + "one that works with the network off."
        case .topographic:
            return "Apple Maps with terrain relief and place names. Needs the network."
        case .satellite:
            return "Apple Maps imagery. Needs the network."
        }
    }

    /// Which of these is Apple's, and so needs the network and the credit.
    var isAppleMaps: Bool { self != .vector }

    @MainActor
    var configuration: MKMapConfiguration? {
        switch self {
        case .vector: return nil
        case .topographic: return MKStandardMapConfiguration(elevationStyle: .realistic)
        case .satellite: return MKImageryMapConfiguration(elevationStyle: .flat)
        }
    }

    /// Apple asks that its maps be credited where they are shown, and that the credit not be
    /// obscured. `MKMapView` draws this for you; a snapshot is a bare image, so the map draws
    /// it in the corner with the others.
    static let attribution = "Apple Maps"
    static let legal = URL(string: "https://gspe21-ssl.ls.apple.com/html/attribution.html")!

    /// Beyond this the raster base is not drawn at all.
    ///
    /// Apple's snapshots are Mercator, which has no north pole and stretches without limit
    /// towards it; a hemisphere's worth of it is not a thing that can be asked for. Past
    /// about thirty degrees across the drawn map takes over — which is also where imagery
    /// stops telling you anything a coastline does not.
    static let widest: Double = 30
}

/// One square of the Mercator pyramid, numbered the way every slippy map numbers them.
///
/// Tiles rather than one snapshot of the whole view, because the whole view has to be
/// fetched again the moment anything moves, and a tile does not: pan by half a screen and
/// most of what you are looking at is already in hand. Measured: a 2800×2400 snapshot of a
/// view costs 1.3 seconds inside MapKit, and a tile costs 0.37 — and then costs nothing at
/// all the next time it is wanted.
struct MapTile: Hashable {

    /// How big a tile is asked for, in points; Retina doubles it, so the pixels are twice
    /// this.
    ///
    /// 512 rather than the 256 every slippy map uses, because these are not fetched from a
    /// tile server but rendered on demand, and the per-request cost dominates: measured over
    /// fresh ground, a view is 20 tiles this size against 54 of the smaller, and is fully
    /// sharp in 1.1 seconds against 1.7.
    nonisolated(unsafe) static var points: CGFloat = 512
    static var pixels: Int { Int(points) * 2 }

    let z: Int
    let x: Int
    let y: Int

    /// How many tiles span the world at this zoom.
    var across: Int { 1 << z }

    /// The tile's square in Apple's own Mercator coordinates.
    ///
    /// Asked for as a `mapRect` rather than as a region in degrees, which makes the snapshot
    /// exactly the tile: checked against `MKMapSnapshot.point(for:)`, the corners land on
    /// (0, 512) and (512, 0) to within a hundredth of a point. Nothing has to be fitted.
    var rect: MKMapRect {
        let side = MKMapSize.world.width / Double(across)
        return MKMapRect(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
    }

    /// The tile one level out that contains this one.
    var parent: MapTile? { z > 0 ? MapTile(z: z - 1, x: x / 2, y: y / 2) : nil }
}

/// A tile's pixels, square, rows running down from the north.
///
/// Its own allocation rather than an array, so that the warp can hold pointers into a dozen
/// tiles at once without nesting a dozen `withUnsafeBufferPointer` calls around its loop.
final class TilePixels {
    let bytes: UnsafeMutablePointer<UInt8>
    let side: Int
    let count: Int

    init(side: Int) {
        self.side = side
        count = side * side * 4
        bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        bytes.initialize(repeating: 0, count: count)
    }

    deinit { bytes.deallocate() }
}

/// Apple Maps, a tile at a time, kept for as long as there is room.
///
/// Held in memory only. Apple does not permit an app to keep its own copy of map imagery, so
/// nothing here is ever written to disk; quit the app and it is gone.
@MainActor
final class BaseMapStore: ObservableObject {

    static let shared = BaseMapStore()

    /// Bumped whenever a tile lands, which is what tells the map to draw again.
    @Published private(set) var version = 0
    /// Set when Apple Maps could not be reached, so the panel can say so rather than leaving
    /// a blank base map and no explanation.
    @Published private(set) var failure: String?

    private var tiles: [MapTile: TilePixels] = [:]
    private var order: [MapTile] = []
    private var bytesHeld = 0
    private var loading: Set<MapTile> = []
    private var queued: [MapTile] = []
    private var layer: BaseMap = .vector

    /// How many snapshots to have in flight at once.
    ///
    /// Measured over fresh ground, twenty-odd tiles: one at a time takes 12.6 seconds to
    /// finish, two 5.5, four 2.6, six 2.7, ten 6.5. They contend — past four, more of them
    /// is slower, and the first tile takes longer to arrive as well.
    var atOnce = 4
    /// Roughly two hundred megabytes of tiles, which is several screens' worth at Retina.
    private let mostBytes = 200 * 1_048_576

    func image(for tile: MapTile) -> TilePixels? { tiles[tile] }

    /// True once there is anything at all to draw.
    var hasTiles: Bool { !tiles.isEmpty }

    /// The tiles as the globe sees them, ready to draw straight onto the sheet.
    ///
    /// Kept until the camera moves or another tile lands, so a still map costs nothing and a
    /// moving one costs one warp a frame.
    func warped(camera: MapCamera, projection: GlobeProjection, size: CGSize,
                scale: CGFloat, z: Int) -> CGImage? {
        let key = WarpKey(version: version, z: z, centre: camera.centre,
                          worldWidth: camera.worldWidth, size: size, scale: scale)
        if key == warpedFor { return warped }
        warped = BaseMapWarp.warp(projection: projection, size: size, scale: scale, z: z) {
            tiles[$0]
        }
        warpedFor = warped == nil ? nil : key
        return warped
    }

    private var warpedFor: WarpKey?
    private var warped: CGImage?

    private struct WarpKey: Equatable {
        let version: Int
        let z: Int
        let centre: Coordinate
        let worldWidth: CGFloat
        let size: CGSize
        let scale: CGFloat
    }

    /// Asks for whichever of these are not in hand, nearest the middle of the view first.
    func request(_ wanted: [MapTile], layer: BaseMap) {
        guard layer.isAppleMaps else { return }
        if layer != self.layer { forget(); self.layer = layer }

        // Whatever was queued and is no longer wanted is dropped rather than fetched: a drag
        // across a continent should not spend the next minute filling in where it has been.
        queued = wanted.filter { tiles[$0] == nil && !loading.contains($0) }
        start()
    }

    private func start() {
        while loading.count < atOnce, !queued.isEmpty {
            let tile = queued.removeFirst()
            guard tiles[tile] == nil, !loading.contains(tile) else { continue }
            loading.insert(tile)
            fetch(tile)
        }
    }

    private func fetch(_ tile: MapTile) {
        let options = MKMapSnapshotter.Options()
        options.mapRect = tile.rect
        options.size = CGSize(width: MapTile.points, height: MapTile.points)
        if let configuration = layer.configuration {
            options.preferredConfiguration = configuration
        }
        let wanted = layer

        MKMapSnapshotter(options: options).start(with: .main) { [weak self] snapshot, error in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                self.loading.remove(tile)
                defer { self.start() }
                guard wanted == self.layer else { return }  // the layer changed under it

                guard let snapshot = snapshot, let pixels = Self.read(snapshot.image) else {
                    self.failure = error?.localizedDescription ?? "Apple Maps did not answer"
                    return
                }
                self.failure = nil
                self.keep(pixels, as: tile)
                self.version &+= 1
            }
        }
    }

    private func keep(_ pixels: TilePixels, as tile: MapTile) {
        tiles[tile] = pixels
        order.append(tile)
        bytesHeld += pixels.count
        while bytesHeld > mostBytes, let oldest = order.first {
            order.removeFirst()
            // It may have been asked for again since, in which case it is at the back too.
            if !order.contains(oldest), let dropped = tiles.removeValue(forKey: oldest) {
                bytesHeld -= dropped.count
            }
        }
    }

    /// The image's pixels, straight into a buffer laid out the way the warp reads it.
    ///
    /// Not by way of `tiffRepresentation`, which is what this did first: encoding a snapshot
    /// to TIFF and parsing it back cost 247ms for a full-view image and buys nothing.
    nonisolated private static func read(_ image: NSImage) -> TilePixels? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return nil }
        let side = min(source.width, source.height)
        guard side > 0 else { return nil }

        let pixels = TilePixels(side: side)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: pixels.bytes, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    /// Throws everything away — for a change of layer, where every tile is the wrong map.
    func forget() {
        warped = nil
        warpedFor = nil
        tiles.removeAll()
        order.removeAll()
        queued.removeAll()
        bytesHeld = 0
        failure = nil
        version &+= 1
    }
}


/// Turning a pyramid of Mercator tiles into the globe's own view of them.
enum BaseMapWarp {

    /// The tile pyramid's own zoom for this view: one tile pixel to one screen pixel.
    ///
    /// Reckoned at the view's own latitude, because Mercator's scale is a secant of it and
    /// the globe's is not: the same tile covers less ground the further north you go.
    static func zoom(worldWidth: CGFloat, scale: CGFloat, latitude: Double,
                     tileSide: Int = MapTile.pixels) -> Int {
        let wanted = Double(worldWidth) * Double(scale)
            * cos(min(abs(latitude), 85) * .pi / 180) / Double(tileSide)
        guard wanted > 1 else { return 0 }
        return max(0, min(20, Int(log2(wanted).rounded())))
    }

    /// Where a coordinate falls in the tile grid, in tiles and fractions of one.
    @inline(__always)
    static func place(latitude: Double, longitude: Double, across: Double) -> (x: Double, y: Double) {
        let x = (longitude + 180) / 360 * across
        let y = (1 - asinh(tan(min(max(latitude, -85), 85) * .pi / 180)) / .pi) / 2 * across
        return (x, y)
    }

    /// The same thing, straight from the direction the globe hands back.
    ///
    /// Mercator's northing is `asinh(tan φ)`, and on a unit sphere `sin φ` is simply the
    /// vertical component — so the whole of it collapses to `atanh(z)`. That takes the inner
    /// loop from an arc-sine, a tangent and an inverse hyperbolic sine down to one logarithm,
    /// which on five and a half million pixels is the difference between 31ms a frame and 13.
    @inline(__always)
    static func place(direction: SIMD3<Double>, across: Double) -> (x: Double, y: Double) {
        let longitude = atan2(direction.y, direction.x)
        let up = min(max(direction.z, -0.9962), 0.9962)         // ±85°, where Mercator stops
        let northing = 0.5 * log((1 + up) / (1 - up))           // atanh
        return ((longitude / (2 * .pi) + 0.5) * across,
                (0.5 - northing / (2 * .pi)) * across)
    }

    /// Which tiles a view covers.
    ///
    /// The corners and edges of the sheet put back through the globe, rather than the centre
    /// plus a span: on a sphere those are not the same thing, and the difference is exactly
    /// the corners you would leave blank.
    static func tiles(projection: GlobeProjection, size: CGSize, z: Int) -> [MapTile] {
        let across = Double(1 << z)
        var least = (x: Int.max, y: Int.max), most = (x: Int.min, y: Int.min)
        for stepX in 0...8 {
            for stepY in 0...8 {
                let at = CGPoint(x: Double(size.width) * Double(stepX) / 8,
                                 y: Double(size.height) * Double(stepY) / 8)
                guard let direction = projection.direction(at: at) else { continue }
                let corner = Coordinate(direction)
                let (x, y) = place(latitude: corner.latitude, longitude: corner.longitude,
                                   across: across)
                least = (min(least.x, Int(x.rounded(.down))), min(least.y, Int(y.rounded(.down))))
                most = (max(most.x, Int(x.rounded(.down))), max(most.y, Int(y.rounded(.down))))
            }
        }
        guard least.x <= most.x, least.y <= most.y else { return [] }
        // A view wrapped round the back of the globe asks for the whole world; the drawn map
        // covers those, and this refuses rather than fetching a thousand tiles.
        guard most.x - least.x < 12, most.y - least.y < 12 else { return [] }

        let middle = (x: Double(least.x + most.x) / 2, y: Double(least.y + most.y) / 2)
        var wanted: [MapTile] = []
        let limit = 1 << z
        for x in least.x...most.x {
            for y in least.y...most.y where y >= 0 && y < limit {
                // Longitude wraps; latitude does not.
                let wrapped = ((x % limit) + limit) % limit
                wanted.append(MapTile(z: z, x: wrapped, y: y))
            }
        }
        // Nearest the middle first, so the part you are looking at fills in before the edges.
        return wanted.sorted {
            hypot(Double($0.x) - middle.x, Double($0.y) - middle.y)
                < hypot(Double($1.x) - middle.x, Double($1.y) - middle.y)
        }
    }

    /// Where one tile of the grid reads its pixels from: itself, or an ancestor standing in
    /// for it until it arrives.
    private struct Source {
        let bytes: UnsafeMutablePointer<UInt8>
        let side: Int
        /// The part of that tile this one occupies, as a fraction of it.
        let u0: Double, v0: Double, span: Double
    }

    /// The tiles, redrawn as the globe sees them.
    ///
    /// Backwards, as a reprojection has to be: for every pixel of the sheet, ask the globe
    /// what direction lies under it, turn that into a latitude and longitude, and read the
    /// tile there. Drawing it the other way round — stretching the picture into place — is
    /// out by 2.8% across a three-degree view at Alpine latitudes, which is twenty-eight
    /// points on a thousand-point panel and looks exactly like a map that is wrong.
    ///
    /// Where a tile has not arrived, the nearest ancestor that has stands in for it, scaled
    /// up: blurry, and there a fifth of a second after you move rather than a second and a
    /// half. It sharpens as the tiles land, which is how every map you have used behaves.
    static func warp(projection: GlobeProjection, size: CGSize, scale: CGFloat, z: Int,
                     tile: (MapTile) -> TilePixels?) -> CGImage? {
        let wide = Int(size.width * scale), high = Int(size.height * scale)
        guard wide > 0, high > 0 else { return nil }

        let across = Double(1 << z)
        let wanted = tiles(projection: projection, size: size, z: z)
        guard !wanted.isEmpty else { return nil }

        let leastX = wanted.map(\.x).min()!, mostX = wanted.map(\.x).max()!
        let leastY = wanted.map(\.y).min()!, mostY = wanted.map(\.y).max()!
        let columns = mostX - leastX + 1, rows = mostY - leastY + 1

        // Hold every tile the table points into for as long as the loop runs.
        var held: [TilePixels] = []
        var table = [Source?](repeating: nil, count: columns * rows)
        var anything = false
        for square in wanted {
            var looking: MapTile? = square
            var up = 0
            while let candidate = looking {
                if let pixels = tile(candidate) {
                    let span = 1.0 / Double(1 << up)
                    let shift = 1 << up
                    let u0 = Double(square.x % shift) / Double(shift)
                    let v0 = Double(square.y % shift) / Double(shift)
                    held.append(pixels)
                    table[(square.y - leastY) * columns + (square.x - leastX)] =
                        Source(bytes: pixels.bytes, side: pixels.side,
                               u0: up == 0 ? 0 : u0, v0: up == 0 ? 0 : v0, span: span)
                    anything = true
                    break
                }
                looking = candidate.parent
                up += 1
                if up > 6 { break }          // six levels out is a whole continent; give up
            }
        }
        guard anything else { return nil }

        var output = [UInt8](repeating: 0, count: wide * high * 4)
        output.withUnsafeMutableBufferPointer { out in
            table.withUnsafeBufferPointer { sources in
                DispatchQueue.concurrentPerform(iterations: high) { row in
                    let y = (Double(row) + 0.5) / Double(scale)
                    var at = row * wide * 4
                    for column in 0..<wide {
                        defer { at += 4 }
                        let x = (Double(column) + 0.5) / Double(scale)
                        guard let direction = projection.direction(at: CGPoint(x: x, y: y))
                        else { continue }

                        let (gx, gy) = place(direction: direction, across: across)
                        let tileX = Int(gx.rounded(.down)), tileY = Int(gy.rounded(.down))
                        let atX = tileX - leastX, atY = tileY - leastY
                        guard atX >= 0, atX < columns, atY >= 0, atY < rows,
                              let source = sources[atY * columns + atX]
                        else { continue }

                        let u = (source.u0 + (gx - Double(tileX)) * source.span) * Double(source.side)
                        let v = (source.v0 + (gy - Double(tileY)) * source.span) * Double(source.side)
                        let sx = min(max(Int(u), 0), source.side - 1)
                        let sy = min(max(Int(v), 0), source.side - 1)
                        let from = (sy * source.side + sx) * 4
                        out[at] = source.bytes[from]
                        out[at + 1] = source.bytes[from + 1]
                        out[at + 2] = source.bytes[from + 2]
                        out[at + 3] = 255
                    }
                }
            }
        }
        held.removeAll()

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: wide, height: high, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: wide * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
