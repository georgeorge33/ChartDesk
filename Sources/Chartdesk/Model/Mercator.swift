import CoreGraphics
import Foundation
import MapKit
import simd

/// The map, drawn the way a slippy map is drawn.
///
/// Deliberately the same Mercator MapKit uses, to the same world square, because the base
/// underneath is a real `MKMapView` and anything drawn over it has to land exactly where it
/// puts the same coordinate. Getting this close is not enough: a runway half a pixel off its
/// own photograph is worse than no photograph.
///
/// The one thing a sphere gave for free and this does not is the seam. A globe has no edge
/// at ±180°, so a shape crossing it needed no thought; Mercator cuts the world there, and a
/// ring that spans the cut has to be unwrapped along its own length or it draws as a band
/// straight across the map.
struct MercatorProjection {

    /// How many points the whole world is wide at this zoom.
    let worldWidth: Double
    let size: CGSize
    /// Top left of the panel, in world points.
    private let originX: Double
    private let originY: Double

    /// As far as Mercator goes. Past this the arithmetic runs away to infinity and there is
    /// nothing to show anyway — MapKit stops at the same place.
    static let limit = 85.051129

    init(centre: Coordinate, worldWidth: Double, in size: CGSize) {
        self.worldWidth = worldWidth
        self.size = size
        originX = Self.worldX(centre.longitude, worldWidth) - Double(size.width) / 2
        originY = Self.worldY(centre.latitude, worldWidth) - Double(size.height) / 2
    }

    /// Built from the map view's own visible rectangle.
    ///
    /// This is the initialiser that matters: taking the rectangle MapKit is actually
    /// showing, rather than reconstructing one from a centre and a zoom, is what makes a
    /// runway land on its own photograph. MapKit keeps the rectangle's aspect equal to the
    /// view's, so one scale serves both directions.
    init(rect: MKMapRect, in size: CGSize) {
        let across = rect.width > 0 ? rect.width : MKMapSize.world.width
        worldWidth = MKMapSize.world.width * Double(size.width) / across
        self.size = size
        let scale = Double(size.width) / across
        originX = rect.minX * scale
        originY = rect.minY * scale
    }

    /// The projection an overlay renderer wants: straight into `MKMapPoint`.
    ///
    /// Measured against a real renderer — for an overlay bounding the world, `point(for:)`
    /// is the identity, so a shape drawn in map points is a shape drawn correctly and
    /// MapKit owns every transform after that. Which is the whole reason for going this
    /// way: a thing MapKit transforms cannot come loose from the map MapKit is drawing.
    init(mapPoints across: CGSize) {
        worldWidth = MKMapSize.world.width
        size = across
        originX = 0
        originY = 0
    }

    /// What the map view should be showing for this camera.
    static func rect(centre: Coordinate, worldWidth: Double, in size: CGSize) -> MKMapRect {
        let world = MKMapSize.world.width
        let across = world * Double(size.width) / max(worldWidth, 1)
        let down = across * Double(size.height) / max(Double(size.width), 1)
        let middleX = worldX(centre.longitude, world)
        let middleY = worldY(centre.latitude, world)
        return MKMapRect(x: middleX - across / 2, y: middleY - down / 2,
                         width: across, height: down)
    }

    /// The camera a visible rectangle amounts to, for everything that still thinks in those
    /// terms — which is every zoom threshold in the app.
    static func camera(of rect: MKMapRect, in size: CGSize) -> (Coordinate, CGFloat) {
        let world = MKMapSize.world.width
        let worldWidth = world * Double(size.width) / max(rect.width, 1)
        let middle = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        return (Coordinate(latitude: middle.latitude, longitude: middle.longitude),
                CGFloat(worldWidth))
    }

    // MARK: - The projection itself

    static func worldX(_ longitude: Double, _ worldWidth: Double) -> Double {
        (longitude + 180) / 360 * worldWidth
    }

    static func worldY(_ latitude: Double, _ worldWidth: Double) -> Double {
        let clamped = min(max(latitude, -limit), limit) * .pi / 180
        // asinh(tan φ) is the Mercator northing, and the form that does not lose precision
        // near the equator the way log(tan(π/4 + φ/2)) does.
        return (1 - asinh(tan(clamped)) / .pi) / 2 * worldWidth
    }

    static func latitude(fromWorldY y: Double, _ worldWidth: Double) -> Double {
        atan(sinh((1 - 2 * y / worldWidth) * .pi)) * 180 / .pi
    }

    /// Where a direction lands on the sheet.
    ///
    /// Wrapped to whichever copy of the world is nearest the middle of the view, so a map
    /// centred on the Pacific draws Japan and California on the same sheet rather than one
    /// of them a world away.
    func point(_ direction: SIMD3<Double>) -> CGPoint {
        place(Coordinate(direction))
    }

    func place(_ coordinate: Coordinate) -> CGPoint {
        let x = Self.worldX(coordinate.longitude, worldWidth) - originX
        let y = Self.worldY(coordinate.latitude, worldWidth) - originY
        return CGPoint(x: nearestCopy(of: x), y: y)
    }

    /// The copy of a world-x nearest the middle of the panel.
    private func nearestCopy(of x: Double) -> Double {
        // Drawing in map points: there is one world and no view to centre a copy on, so a
        // coordinate keeps the x it has.
        guard worldWidth > 0, originX != 0 || originY != 0 else { return x }
        let middle = Double(size.width) / 2
        let off = x - middle
        return middle + off - (off / worldWidth).rounded() * worldWidth
    }

    /// Points to the radian at the equator — the same figure the globe's radius was, and
    /// what anything asking "how big is this on the sheet" still wants.
    var radius: Double { worldWidth / (2 * .pi) }

    /// Nothing is on the far side of a flat map, so everything faces you.
    func faces(_ direction: SIMD3<Double>) -> Bool {
        abs(Coordinate(direction).latitude) <= Self.limit
    }

    func direction(at point: CGPoint) -> SIMD3<Double>? {
        let worldY = Double(point.y) + originY
        guard worldY >= 0, worldY <= worldWidth else { return nil }
        let longitude = (Double(point.x) + originX) / worldWidth * 360 - 180
        let latitude = Self.latitude(fromWorldY: worldY, worldWidth)
        return Coordinate(latitude: latitude,
                          longitude: (longitude + 540).truncatingRemainder(dividingBy: 360) - 180)
            .direction
    }

    // MARK: - Culling

    /// Always: a flat map has no far side to hide anything on.
    func couldFace(_ cap: SphericalCap) -> Bool { true }

    /// A box that certainly contains the shape, cheaply and generously: the cap's own box
    /// on a world one unit wide, which it worked out when it was made, brought to this
    /// zoom. Arithmetic, not trigonometry, because this is asked of every shape in a table
    /// on every frame.
    func bounds(of cap: SphericalCap) -> CGRect {
        let box = cap.mercator
        let x = nearestCopy(of: box.x * worldWidth - originX)
        let y = box.y * worldWidth - originY
        let reach = box.reach * worldWidth
        return CGRect(x: x - reach, y: y - reach, width: reach * 2, height: reach * 2)
    }

    // MARK: - Shapes

    /// A ring's points, unwrapped along its own length so it does not jump the seam.
    ///
    /// Each point takes whichever copy of the world sits nearest the one before it. A ring
    /// that genuinely spans the cut then runs off one side and is clipped there, which is
    /// what it should do, rather than folding back across the whole map.
    func visible(ring: [SIMD3<Double>], steps: Double = 0) -> [CGPoint] {
        guard !ring.isEmpty else { return [] }
        var out: [CGPoint] = []
        out.reserveCapacity(ring.count)
        var previous: Double?

        for direction in ring {
            let coordinate = Coordinate(direction)
            var x = Self.worldX(coordinate.longitude, worldWidth) - originX
            let y = Self.worldY(coordinate.latitude, worldWidth) - originY
            if let last = previous, worldWidth > 0 {
                x -= ((x - last) / worldWidth).rounded() * worldWidth
            } else {
                x = nearestCopy(of: x)
            }
            previous = x
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }
}
