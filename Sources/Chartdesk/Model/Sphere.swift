import CoreGraphics
import Foundation
import simd

// What is left of the sphere after the map was flattened.
//
// The map is Mercator now and MapKit draws the base, but the tables the app holds are still
// points on a ball: a coordinate's direction as a unit vector, and the cap that bounds a
// shape. Both survive the change intact, because neither was ever about the projection —
// one dot product still answers "could any of this be on screen" whatever the sheet is.

extension Coordinate {

    /// The point on the unit sphere this coordinate names.
    var direction: SIMD3<Double> {
        let latitude = self.latitude * .pi / 180
        let longitude = self.longitude * .pi / 180
        let ring = cos(latitude)
        return SIMD3(ring * cos(longitude), ring * sin(longitude), sin(latitude))
    }

    init(_ direction: SIMD3<Double>) {
        latitude = asin(min(max(direction.z, -1), 1)) * 180 / .pi
        longitude = atan2(direction.y, direction.x) * 180 / .pi
    }
}

/// The smallest cap of the sphere holding a shape — a centre and an angle out from it.
///
/// What a bounding box was for Mercator. A box of longitudes and latitudes says nothing useful
/// on a globe: near a pole it wraps the whole world, and it cannot answer the one question
/// worth asking, which is whether any of this shape is on the side of the sphere facing us.
struct SphericalCap {
    /// Unit vector to the middle of the shape.
    let centre: SIMD3<Double>
    /// The cosine and sine of the angle out to the furthest point.
    ///
    /// Kept as a cosine rather than an angle because that is what a dot product gives: finding
    /// the cap costs one dot per point of a shape instead of one arc cosine, and across the
    /// deepest tier that is 380,000 of them saved at load.
    let cosRadius: Double
    let sinRadius: Double

    var radius: Double { acos(min(max(cosRadius, -1), 1)) }

    init(_ directions: [SIMD3<Double>]) {
        var sum = SIMD3<Double>.zero
        for direction in directions { sum += direction }
        // A shape spread evenly round the globe sums to nothing; anything will do for it, and
        // the radius below comes out large enough to keep it whatever it is.
        let middle = simd_length(sum) > 1e-9 ? simd_normalize(sum) : SIMD3(0, 0, 1)

        var closest = 1.0
        for direction in directions {
            closest = min(closest, simd_dot(middle, direction))
        }
        centre = middle
        cosRadius = closest
        sinRadius = (1 - closest * closest).squareRoot()
    }
}
