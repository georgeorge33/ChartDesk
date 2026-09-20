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
    /// Shaded relief, rendered here from raw elevation.
    case terrain
    /// Apple's imagery.
    case satellite

    var id: String { rawValue }

    /// Where a layer's tiles come from, which is not the same question for all of them.
    enum Source {
        /// Drawn from the tables in the app; no tiles at all.
        case drawn
        /// Rendered on demand by MapKit, a snapshot at a time.
        case appleMaps
        /// Fetched over HTTP from a tile server, `{z}/{x}/{y}`.
        case web(String)
    }

    var source: Source {
        switch self {
        case .vector: return .drawn
        case .terrain:
            return .web("https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png")
        case .satellite: return .appleMaps
        }
    }

    var name: String {
        switch self {
        case .vector: return "Drawn"
        case .terrain: return "Terrain"
        case .satellite: return "Satellite"
        }
    }

    var detail: String {
        switch self {
        case .vector:
            return "Coastline, lakes and borders, drawn from the tables in the app. Always "
                 + "there, network or no network."
        case .terrain:
            return "Shaded relief and height, drawn here from raw elevation rather than "
                 + "fetched as a picture. Kept on this Mac once fetched, so anywhere you "
                 + "have looked works offline."
        case .satellite:
            return "Apple Maps imagery. Needs the network every time — Apple does not "
                 + "permit an app to keep a copy."
        }
    }

    /// True for the one whose tiles come from Apple, which changes what must be credited
    /// and what may be kept.
    var isAppleMaps: Bool {
        if case .appleMaps = source { return true }
        return false
    }

    var needsNetwork: Bool {
        if case .drawn = source { return false }
        return true
    }

    /// Tile servers hand out what they hand out; MapKit renders whatever is asked for.
    var tilePixels: Int {
        switch source {
        case .drawn: return 0
        case .appleMaps: return Int(MapTile.applePoints) * 2      // Retina doubles the ask
        case .web: return 256
        }
    }

    /// How many device pixels one tile pixel is meant to cover: one, always.
    ///
    /// Drawing a tile server's 256-pixel squares at 256 *points* is what a slippy map does
    /// on a screen with one pixel to the point, and on a Retina screen it magnifies every
    /// tile twofold — which is what a blurry map looks like. The terrain tiles are 256 square and there is no
    /// Retina set, so the answer is to fetch one level deeper and draw at half the size: four
    /// times the tiles, and the difference between reading "Reichenau" and not.
    var tileScale: CGFloat { 2 }

    /// As deep as the source goes. Past this the warp magnifies the deepest tiles, which is
    /// what every map does at the bottom of its pyramid.
    var deepestZoom: Int {
        switch self {
        case .vector: return 0
        // Measured: z16 is a 404 everywhere. The elevation itself is coarser than that
        // in most of the world anyway — 30 m from SRTM is about a z12 pixel.
        case .terrain: return 15
        case .satellite: return 20
        }
    }

    /// True for the one whose tiles are a measurement rather than a picture, and so have
    /// to be rendered before they can be drawn.
    var rendersElevation: Bool { self == .terrain }

    /// Tiles from a server may be kept; Apple's may not.
    var cachesOnDisk: Bool {
        if case .web = source { return true }
        return false
    }

    /// Shown on the map whenever the layer is drawn, because both of these ask for it.
    var attribution: [String] {
        switch self {
        case .vector: return []
        case .terrain:
            // The full list names eleven national surveys and is too long for a corner of
            // a map, so the map carries the short form and the Layers panel carries the
            // link. LICENSES.md has it in full.
            return ["Terrain: USGS 3DEP, SRTM, GMTED2010,",
                    "Copernicus EU-DEM and others · Tilezen"]
        case .satellite: return ["Apple Maps"]
        }
    }

    @MainActor
    var configuration: MKMapConfiguration? {
        guard isAppleMaps else { return nil }
        return MKImageryMapConfiguration(elevationStyle: .flat)
    }

    /// Where to read the notices for whatever this layer is made of.
    var legal: URL? {
        switch self {
        case .vector: return nil
        case .terrain:
            return URL(string: "https://github.com/tilezen/joerd/blob/master/docs/attribution.md")
        case .satellite: return URL(string: "https://gspe21-ssl.ls.apple.com/html/attribution.html")
        }
    }

    /// Apple asks that its maps be credited where they are shown, and that the credit not be
    /// obscured. `MKMapView` draws this for you; a snapshot is a bare image, so the map draws
    /// it in the corner with the others.
    static let appleAttribution = "Apple Maps"

    /// How much to take off a base map before the overlays go over it.
    ///
    /// Both of these are made to be looked at on their own, and airspace over bright
    /// hillshading is two things competing. A third off puts the map behind the chart
    /// without turning it into a silhouette.
    static let dimming: Double = 0.32

    /// Beyond this the raster base is not drawn at all.
    ///
    /// Tiles are Mercator, which has no north pole and stretches without limit towards it; a
    /// hemisphere's worth of it is not a thing that can be asked for. Past about thirty
    /// degrees across the drawn map takes over — which is also where a base map stops
    /// telling you anything a coastline does not.
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

    /// How big an Apple tile is asked for, in points; Retina doubles it.
    ///
    /// 512 rather than the 256 a tile server uses, because these are rendered on demand
    /// rather than fetched, and the per-request cost dominates: measured over fresh ground,
    /// a view is 20 tiles this size against 54 of the smaller, and is fully sharp in 1.1
    /// seconds against 1.7.
    nonisolated(unsafe) static var applePoints: CGFloat = 512

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
        guard layer.needsNetwork else { return }
        if layer != self.layer { forget(); self.layer = layer }

        // Whatever was queued and is no longer wanted is dropped rather than fetched: a drag
        // across a continent should not spend the next minute filling in where it has been.
        queued = wanted.filter { tiles[$0] == nil && !loading.contains($0) }
        if layer.cachesOnDisk { sweepCache() }
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
        switch layer.source {
        case .drawn: loading.remove(tile)
        case .appleMaps: fetchFromApple(tile)
        case .web(let template): fetchFromServer(tile, template: template)
        }
    }

    /// MapKit renders it to order.
    private func fetchFromApple(_ tile: MapTile) {
        let options = MKMapSnapshotter.Options()
        options.mapRect = tile.rect
        options.size = CGSize(width: MapTile.applePoints, height: MapTile.applePoints)
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
                self.arrived(pixels, as: tile)
            }
        }
    }

    /// A tile server hands it over, and this one is allowed to keep it.
    ///
    /// Disk first, because a tile already fetched should never be asked for twice: it is
    /// someone else's bandwidth, their usage policy asks as much, and it is the difference
    /// between a map that works on a plane and one that does not.
    private func fetchFromServer(_ tile: MapTile, template: String) {
        let wanted = layer
        let cached = Self.cacheURL(for: tile, layer: wanted)
        guard let url = Self.address(template, tile) else {
            loading.remove(tile)
            start()
            return
        }

        Self.work.async {
            if let data = try? Data(contentsOf: cached),
               let pixels = Self.read(data, for: wanted, at: tile) {
                Task { @MainActor in
                    self.loading.remove(tile)
                    defer { self.start() }
                    guard wanted == self.layer else { return }
                    self.arrived(pixels, as: tile)
                }
                return
            }

            var request = URLRequest(url: url, timeoutInterval: 30)
            // Every tile server's usage policy asks for an agent that says who is calling,
            // and refuses the ones that do not.
            request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, response, error in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let pixels = (code == 200 && data != nil)
                    ? Self.read(data!, for: wanted, at: tile) : nil
                if let data = data, pixels != nil {
                    try? FileManager.default.createDirectory(
                        at: cached.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? data.write(to: cached)
                }
                Task { @MainActor in
                    self.loading.remove(tile)
                    defer { self.start() }
                    guard wanted == self.layer else { return }
                    guard let pixels = pixels else {
                        self.failure = error?.localizedDescription
                            ?? "the tile server answered \(code)"
                        return
                    }
                    self.arrived(pixels, as: tile)
                }
            }.resume()
        }
    }

    private func arrived(_ pixels: TilePixels, as tile: MapTile) {
        failure = nil
        keep(pixels, as: tile)
        version &+= 1
    }

    /// `{z}/{x}/{y}`, with the server's own letters spread across the tiles it asks you to.
    nonisolated static func address(_ template: String, _ tile: MapTile) -> URL? {
        let letters = ["a", "b", "c"]
        let filled = template
            .replacingOccurrences(of: "{s}", with: letters[abs(tile.x &+ tile.y) % letters.count])
            .replacingOccurrences(of: "{z}", with: "\(tile.z)")
            .replacingOccurrences(of: "{x}", with: "\(tile.x)")
            .replacingOccurrences(of: "{y}", with: "\(tile.y)")
        return URL(string: filled)
    }

    /// Where a kept tile lives. Not in the app, and not beside the charts.
    nonisolated static func cacheURL(for tile: MapTile, layer: BaseMap) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support
            .appendingPathComponent("Chartdesk/tiles/\(layer.rawValue)/\(tile.z)/\(tile.x)",
                                    isDirectory: true)
            .appendingPathComponent("\(tile.y).png")
    }

    nonisolated static let agent =
        "Chartdesk/1.1 (macOS; +https://github.com/georgeorge33/ChartDesk)"
    nonisolated static let work = DispatchQueue(label: "chartdesk.tiles", qos: .userInitiated,
                                                attributes: .concurrent)

    /// Keeps the kept tiles from growing without end.
    ///
    /// Swept once per launch, in the background, oldest first. Four hundred megabytes is
    /// several thousand tiles — every airfield you have looked at this year — and it is the
    /// user's disk, not ours.
    private var didSweep = false
    private static let mostOnDisk = 400 * 1_048_576

    private func sweepCache() {
        guard !didSweep else { return }
        didSweep = true
        Self.work.async {
            let manager = FileManager.default
            let root = Self.cacheURL(for: MapTile(z: 0, x: 0, y: 0), layer: .terrain)
                .deletingLastPathComponent()      // …/terrain/0/0
                .deletingLastPathComponent()      // …/terrain/0
                .deletingLastPathComponent()      // …/terrain
                .deletingLastPathComponent()      // …/tiles
            guard let walk = manager.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey])
            else { return }

            var found: [(url: URL, size: Int, used: Date)] = []
            var total = 0
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentAccessDateKey]),
                      let size = values.fileSize else { continue }
                total += size
                found.append((url, size, values.contentAccessDate ?? .distantPast))
            }
            guard total > Self.mostOnDisk else { return }

            for tile in found.sorted(by: { $0.used < $1.used }) {
                guard total > Self.mostOnDisk else { break }
                try? manager.removeItem(at: tile.url)
                total -= tile.size
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
    /// A tile, ready to draw.
    ///
    /// The terrain layer's tiles are heights rather than a picture, so they are painted on
    /// the way past — here, once, rather than on every warp, and off the main thread with
    /// the decode. What is written to the cache is the untouched bytes from the server, so
    /// changing how terrain is drawn does not mean fetching it all again.
    nonisolated private static func read(_ data: Data, for layer: BaseMap,
                                         at tile: MapTile) -> TilePixels? {
        guard let pixels = read(data) else { return nil }
        if layer.rendersElevation { TerrainShading.paint(pixels, at: tile) }
        return pixels
    }

    nonisolated private static func read(_ data: Data) -> TilePixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return read(image)
    }

    nonisolated private static func read(_ image: NSImage) -> TilePixels? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return nil }
        return read(source)
    }

    nonisolated private static func read(_ source: CGImage) -> TilePixels? {
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
                     tileSide: Int, deepest: Int = 20) -> Int {
        let wanted = Double(worldWidth) * Double(scale)
            * cos(min(abs(latitude), 85) * .pi / 180) / Double(tileSide)
        guard wanted > 1 else { return 0 }
        return max(0, min(deepest, Int(log2(wanted).rounded())))
    }

    /// The same, for whichever layer is drawing: its tiles are its own size, and its pyramid
    /// stops where it stops.
    static func zoom(for layer: BaseMap, worldWidth: CGFloat, latitude: Double) -> Int {
        guard layer.tilePixels > 0 else { return 0 }
        return zoom(worldWidth: worldWidth, scale: layer.tileScale, latitude: latitude,
                    tileSide: layer.tilePixels, deepest: layer.deepestZoom)
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
        // A view wrapped round the back of the globe asks for the whole world; the drawn
        // map covers those, and this refuses rather than fetching a thousand tiles. Generous
        // on purpose: a wrapped view is hundreds of tiles across, while a legitimate one is
        // as many as the window has room for — and when this read 12, raising the zoom by a
        // level to sharpen the map made ordinary views exceed it and draw nothing at all.
        guard most.x - least.x < 64, most.y - least.y < 64,
              (most.x - least.x + 1) * (most.y - least.y + 1) <= 260
        else { return [] }

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

                        let u = (source.u0 + (gx - Double(tileX)) * source.span)
                            * Double(source.side) - 0.5
                        let v = (source.v0 + (gy - Double(tileY)) * source.span)
                            * Double(source.side) - 0.5

                        // Between four pixels rather than the nearest one. A tile server's
                        // squares are drawn two device pixels wide on a Retina screen and
                        // the deepest zooms magnify them further still; taking the nearest
                        // makes that a staircase, and weighing the four around it makes it
                        // a photograph of a map.
                        let leftX = Int(u.rounded(.down)), topY = Int(v.rounded(.down))
                        let acrossWeight = u - Double(leftX), downWeight = v - Double(topY)
                        let x0 = min(max(leftX, 0), source.side - 1)
                        let y0 = min(max(topY, 0), source.side - 1)
                        let x1 = min(x0 + 1, source.side - 1)
                        let y1 = min(y0 + 1, source.side - 1)

                        let topLeft = (y0 * source.side + x0) * 4
                        let topRight = (y0 * source.side + x1) * 4
                        let bottomLeft = (y1 * source.side + x0) * 4
                        let bottomRight = (y1 * source.side + x1) * 4
                        let leftShare = 1 - acrossWeight, topShare = 1 - downWeight
                        let topLeftShare = leftShare * topShare
                        let topRightShare = acrossWeight * topShare
                        let bottomLeftShare = leftShare * downWeight
                        let bottomRightShare = acrossWeight * downWeight

                        for channel in 0..<3 {
                            let blended =
                                Double(source.bytes[topLeft + channel]) * topLeftShare
                                + Double(source.bytes[topRight + channel]) * topRightShare
                                + Double(source.bytes[bottomLeft + channel]) * bottomLeftShare
                                + Double(source.bytes[bottomRight + channel]) * bottomRightShare
                            out[at + channel] = UInt8(min(max(blended, 0), 255))
                        }
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
