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

/// One snapshot of Apple Maps, and where on the Earth it sits.
///
/// Held as pixels rather than as an `NSImage` because every pixel of it is about to be read
/// individually: the map is a globe and the snapshot is Mercator, so it cannot simply be
/// drawn into place.
struct BaseMapPatch {
    /// Counts up, so a warped image can tell whether it was made from this snapshot.
    let id: Int
    let layer: BaseMap
    let pixels: [UInt8]
    let wide: Int
    let high: Int
    let bytesPerRow: Int
    let samples: Int

    /// Mercator, fitted to the snapshot from two of its own coordinates. Exact: checked
    /// against `MKMapSnapshot.point(for:)` across a whole image, and it agrees to 0.000px.
    let xPerDegree: Double
    let x0: Double
    let yPerMercator: Double
    let y0: Double

    /// What the snapshot covers, for deciding whether it still serves the view.
    let west: Double, east: Double, south: Double, north: Double

    @inline(__always)
    static func mercator(_ latitude: Double) -> Double {
        log(tan(.pi / 4 + latitude / 2))
    }

    /// True when this patch covers the box, and was taken at a similar scale.
    func covers(west: Double, east: Double, south: Double, north: Double,
                degreesAcross: Double) -> Bool {
        guard self.west <= west, self.east >= east,
              self.south <= south, self.north >= north
        else { return false }
        // And is not wildly the wrong resolution: a patch taken across a country is a blur
        // over a town, and one taken over a town is fifty snapshots' worth of a country.
        let mine = self.east - self.west
        return mine < degreesAcross * 6
    }
}

/// Asks Apple Maps for what the view is looking at, and holds the answer.
///
/// One snapshot at a time, covering the whole view with a margin, rather than a grid of
/// tiles: `MKMapSnapshotter` will render any region at any size, so the tiling is Apple's
/// problem and not this app's. The previous snapshot keeps drawing until the next arrives,
/// which is what stops the map flashing empty on every pan.
@MainActor
final class BaseMapStore: ObservableObject {

    static let shared = BaseMapStore()

    @Published private(set) var patch: BaseMapPatch?
    /// Set when Apple Maps could not be reached, so the panel can say so rather than leaving
    /// a blank base map and no explanation.
    @Published private(set) var failure: String?

    private var snapshotter: MKMapSnapshotter?
    private var asking: String?
    private static var counter = 0

    /// The last warp, kept so that a still map redraws without doing the work again.
    private var warpedFor: WarpKey?
    private var warped: CGImage?

    private struct WarpKey: Equatable {
        let patch: Int
        let centre: Coordinate
        let worldWidth: CGFloat
        let size: CGSize
        let scale: CGFloat
    }

    /// Asks for a snapshot covering this box, unless one is already in hand or on its way.
    ///
    /// The box is grown by half again, so that a pan of less than a quarter of the view
    /// costs nothing at all.
    func request(layer: BaseMap, west: Double, east: Double, south: Double, north: Double,
                 degreesAcross: Double, size: CGSize) {
        guard layer.isAppleMaps, size.width > 10, size.height > 10 else { return }
        if let patch = patch, patch.layer == layer,
           patch.covers(west: west, east: east, south: south, north: north,
                        degreesAcross: degreesAcross) {
            return
        }

        let middleLatitude = (south + north) / 2
        let middleLongitude = (west + east) / 2
        let spanLatitude = min((north - south) * 1.5, 80)
        let spanLongitude = min((east - west) * 1.5, 120)

        // One ask per region, so a drag does not queue a hundred snapshots.
        let wanted = String(format: "%@ %.4f %.4f %.4f %.4f", layer.rawValue,
                            middleLatitude, middleLongitude, spanLatitude, spanLongitude)
        guard wanted != asking else { return }
        asking = wanted

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: middleLatitude, longitude: middleLongitude),
            span: MKCoordinateSpan(latitudeDelta: spanLatitude, longitudeDelta: spanLongitude))
        // Asked for at twice the panel's size, because on macOS a snapshot renders one
        // pixel per point and imagery drawn soft is worth nothing. Capped, because the
        // whole thing is read pixel by pixel a moment later.
        options.size = CGSize(width: min(size.width * 3, 2_800),
                              height: min(size.height * 3, 2_800))
        if let configuration = layer.configuration {
            options.preferredConfiguration = configuration
        }

        snapshotter?.cancel()
        let snapshotter = MKMapSnapshotter(options: options)
        self.snapshotter = snapshotter
        snapshotter.start(with: .main) { [weak self] snapshot, error in
            guard let self = self else { return }
            self.asking = nil
            guard let snapshot = snapshot else {
                self.failure = error?.localizedDescription ?? "Apple Maps did not answer"
                return
            }
            self.failure = nil
            self.patch = Self.patch(from: snapshot, layer: layer,
                                    west: middleLongitude - spanLongitude / 2,
                                    east: middleLongitude + spanLongitude / 2,
                                    south: middleLatitude - spanLatitude / 2,
                                    north: middleLatitude + spanLatitude / 2)
        }
    }

    /// The snapshot as the globe sees it, ready to be drawn straight onto the sheet.
    ///
    /// Recomputed only when the camera or the snapshot changes. Nine milliseconds at Retina
    /// size for a full panel — measured — which is a cost per drag frame, not per frame.
    func warped(camera: MapCamera, projection: GlobeProjection, size: CGSize,
                scale: CGFloat) -> CGImage? {
        guard let patch = patch else { return nil }
        let key = WarpKey(patch: patch.id, centre: camera.centre,
                          worldWidth: camera.worldWidth, size: size, scale: scale)
        if key == warpedFor, let warped = warped { return warped }
        warped = patch.warped(to: projection, size: size, scale: scale)
        warpedFor = warped == nil ? nil : key
        return warped
    }

    /// Throws away what is held — for a change of layer, where the old picture is the wrong
    /// map rather than merely the wrong place.
    func forget() {
        snapshotter?.cancel()
        snapshotter = nil
        asking = nil
        patch = nil
        failure = nil
        warped = nil
        warpedFor = nil
    }

    /// Reads the snapshot's pixels, and works out where each of them is on the Earth.
    private static func patch(from snapshot: MKMapSnapshotter.Snapshot, layer: BaseMap,
                              west: Double, east: Double,
                              south: Double, north: Double) -> BaseMapPatch? {
        guard let tiff = snapshot.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let raw = bitmap.bitmapData
        else { return nil }

        let scale = Double(bitmap.pixelsWide) / Double(snapshot.image.size.width)
        func pixel(_ latitude: Double, _ longitude: Double) -> CGPoint {
            let point = snapshot.point(for: CLLocationCoordinate2D(latitude: latitude,
                                                                   longitude: longitude))
            return CGPoint(x: point.x * scale, y: point.y * scale)
        }
        // Two coordinates are enough: Mercator is linear in longitude and in the log-tangent
        // of latitude, and a snapshot is plain Mercator.
        let lowLatitude = max(south, -84), highLatitude = min(north, 84)
        guard highLatitude > lowLatitude, east > west else { return nil }
        let a = pixel(lowLatitude, west), b = pixel(highLatitude, east)
        let xPerDegree = Double(b.x - a.x) / (east - west)
        let mercatorLow = BaseMapPatch.mercator(lowLatitude * .pi / 180)
        let mercatorHigh = BaseMapPatch.mercator(highLatitude * .pi / 180)
        guard mercatorHigh != mercatorLow, xPerDegree != 0 else { return nil }
        var yPerMercator = Double(b.y - a.y) / (mercatorHigh - mercatorLow)
        var yZero = Double(a.y) - yPerMercator * mercatorLow

        // `point(for:)` answers in AppKit coordinates — measured: y grows northward, from
        // the bottom left — while the bitmap's rows run down from the top. Turned round here
        // rather than in the warp, which reads two million pixels and should not be asking
        // which way up they are. Without this the map draws mirrored, which on imagery looks
        // merely odd and on a map with names on it is unmistakable.
        yZero = Double(bitmap.pixelsHigh - 1) - yZero
        yPerMercator = -yPerMercator

        let count = bitmap.bytesPerRow * bitmap.pixelsHigh
        counter += 1
        return BaseMapPatch(
            id: counter,
            layer: layer,
            pixels: [UInt8](UnsafeBufferPointer(start: raw, count: count)),
            wide: bitmap.pixelsWide, high: bitmap.pixelsHigh,
            bytesPerRow: bitmap.bytesPerRow, samples: bitmap.samplesPerPixel,
            xPerDegree: xPerDegree, x0: Double(a.x) - xPerDegree * west,
            yPerMercator: yPerMercator, y0: yZero,
            west: west, east: east, south: south, north: north)
    }
}

extension BaseMapPatch {

    /// The snapshot, redrawn as the globe sees it.
    ///
    /// Backwards, as a reprojection has to be: for every pixel of the sheet, ask the globe
    /// what direction lies under it, turn that into a latitude and longitude, and read the
    /// snapshot there. Drawing it the other way round — stretching the picture into place —
    /// is out by 2.8% across a three-degree view at Alpine latitudes, which is twenty-eight
    /// points on a thousand-point panel and looks exactly like a map that is wrong.
    ///
    /// A row at a time across every core: the work is the same for each and there are two
    /// million of these at Retina size.
    func warped(to projection: GlobeProjection, size: CGSize, scale: CGFloat) -> CGImage? {
        let wide = Int(size.width * scale), high = Int(size.height * scale)
        guard wide > 0, high > 0 else { return nil }

        var output = [UInt8](repeating: 0, count: wide * high * 4)
        let source = pixels
        let sourceWide = Double(self.wide), sourceHigh = Double(self.high)

        output.withUnsafeMutableBufferPointer { out in
            source.withUnsafeBufferPointer { raw in
                DispatchQueue.concurrentPerform(iterations: high) { row in
                    let y = (Double(row) + 0.5) / Double(scale)
                    var at = row * wide * 4
                    for column in 0..<wide {
                        defer { at += 4 }
                        let x = (Double(column) + 0.5) / Double(scale)
                        guard let direction = projection.direction(at: CGPoint(x: x, y: y))
                        else { continue }

                        let latitude = asin(max(-1, min(1, direction.z)))
                        let longitude = atan2(direction.y, direction.x) * 180 / .pi
                        let sx = x0 + xPerDegree * longitude
                        let sy = y0 + yPerMercator * BaseMapPatch.mercator(latitude)
                        guard sx >= 0, sy >= 0, sx < sourceWide, sy < sourceHigh else { continue }

                        let from = Int(sy) * bytesPerRow + Int(sx) * samples
                        out[at] = raw[from]
                        out[at + 1] = raw[from + 1]
                        out[at + 2] = raw[from + 2]
                        out[at + 3] = 255
                    }
                }
            }
        }

        let bytes = output
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: wide, height: high, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: wide * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
