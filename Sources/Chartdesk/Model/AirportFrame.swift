import Foundation
import simd

/// An airport flattened onto its own plane: metres east and north of the middle of the field.
///
/// Azimuthal equidistant about the field's centre, which is what Navigraph's AMDB API offers
/// alongside plain latitude and longitude, and for the same reason. An airport is four
/// kilometres across, and on a piece of ground that size a sphere is a plane. Working there
/// turns every bit of derived geometry — the white lines down a runway's sides, the piano
/// keys, the bar across a holding position — into arithmetic on two numbers in metres,
/// instead of cross products and small-angle offsets against a unit sphere.
///
/// The error is not worth thinking about, which is the point of choosing this projection
/// rather than a tangent plane: azimuthal equidistant is exact along every line out of its
/// centre and stretches only across them, by θ/sin θ. Four kilometres out that is one part
/// in fifty million, or a twentieth of a millimetre at the far end of the longest runway
/// there is.
struct AirportFrame {

    /// Metres. The same figure the rest of the app measures the globe with.
    static let earthRadius = 6_371_000.0

    /// Unit vector to the middle of the field.
    let centre: SIMD3<Double>
    private let east: SIMD3<Double>
    private let north: SIMD3<Double>

    init(centre: SIMD3<Double>) {
        let middle = simd_normalize(centre)
        self.centre = middle
        // East is the way longitude increases. At a pole there is no such direction and the
        // cross product collapses; no airport is at a pole, but something has to be chosen.
        let sideways = simd_cross(SIMD3<Double>(0, 0, 1), middle)
        east = simd_length(sideways) > 1e-9 ? simd_normalize(sideways) : SIMD3(1, 0, 0)
        north = simd_cross(middle, east)
    }

    /// Centred on what is actually mapped.
    ///
    /// A published aerodrome reference point is the tidier answer and is what an AMDB uses,
    /// but the projection does not care which point on the field it is given: anywhere on
    /// the airport puts every part of it within a few kilometres of the origin, and that is
    /// the whole requirement.
    init(covering directions: [SIMD3<Double>]) {
        var sum = SIMD3<Double>.zero
        for direction in directions { sum += direction }
        self.init(centre: simd_length(sum) > 1e-9 ? sum : SIMD3(0, 0, 1))
    }

    /// Where a direction falls on the plane, in metres east and north of the centre.
    func plane(_ direction: SIMD3<Double>) -> SIMD2<Double> {
        let along = simd_dot(centre, direction)
        let out = direction - centre * along
        let across = simd_length(out)
        guard across > 1e-15 else { return .zero }
        // atan2 rather than acos: the same angle, without losing every digit that matters
        // at the small distances this is used for.
        let distance = atan2(across, along) * Self.earthRadius
        let unit = out / across
        return SIMD2(simd_dot(unit, east), simd_dot(unit, north)) * distance
    }

    /// The direction a point on the plane names.
    func globe(_ point: SIMD2<Double>) -> SIMD3<Double> {
        let distance = simd_length(point)
        guard distance > 1e-12 else { return centre }
        let angle = distance / Self.earthRadius
        let unit = point / distance
        // Unit length already: the centre and the way out from it are at right angles.
        return centre * cos(angle) + (east * unit.x + north * unit.y) * sin(angle)
    }

    /// True when a ring drawn on this plane encloses a point on it.
    ///
    /// The ordinary ray cast. Used to ask whether a centreline has its pavement mapped as
    /// an outline, which is a question about a few hundred points and a few dozen rings.
    static func encloses(_ ring: [SIMD2<Double>], _ point: SIMD2<Double>) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var previous = ring.count - 1
        for current in ring.indices {
            let a = ring[current], b = ring[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }
}
