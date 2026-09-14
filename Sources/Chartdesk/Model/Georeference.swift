import CoreGraphics
import Foundation

/// A point whose position is known both on the ground and on the plate.
struct GeoAnchor: Codable, Equatable {
    var coordinate: Coordinate
    /// Normalised 0…1 against the *unrotated* chart — the same space annotations use, so a
    /// calibration survives rotating the plate exactly as a drawn mark does.
    var chart: CGPoint
    var label: String
}

/// Ties a chart image to the ground, so OpenStreetMap geometry can be drawn on it.
///
/// The fit is a similarity — rotation, uniform scale and translation, with a reflection for
/// the chart's downward y axis — rather than a full affine. Ground charts are conformal at
/// airport scale, and a similarity cannot shear the airport into a wrong shape to chase a
/// mis-clicked point. It also needs only two anchors, which is two clicks.
struct ChartGeoreference: Codable, Equatable {

    var icao: String
    /// Tangent-plane origin. Working in metres east/north of a nearby point keeps the fit
    /// well conditioned and makes the residual a real distance rather than a number of degrees.
    var origin: Coordinate
    /// x = a·east − b·north + tx, and the same pair rotated for the y axis.
    var a: Double
    var b: Double
    var tx: Double
    var ty: Double
    /// Chart height ÷ width. Normalised x and y are fractions of different edges, so without
    /// this a similarity fit would be skewed on any plate that is not square.
    var aspect: Double
    var anchors: [GeoAnchor]
    var rmsMetres: Double

    private static let metresPerDegree = 111_320.0

    // MARK: Tangent plane

    private func planar(_ coordinate: Coordinate) -> (east: Double, north: Double) {
        let east = (coordinate.longitude - origin.longitude) * Self.metresPerDegree
            * cos(origin.latitude * .pi / 180)
        let north = (coordinate.latitude - origin.latitude) * Self.metresPerDegree
        return (east, north)
    }

    private func spherical(east: Double, north: Double) -> Coordinate {
        Coordinate(
            latitude: origin.latitude + north / Self.metresPerDegree,
            longitude: origin.longitude + east / (Self.metresPerDegree * cos(origin.latitude * .pi / 180))
        )
    }

    // MARK: Projection

    /// Ground position → normalised point on the unrotated plate.
    func chartPoint(_ coordinate: Coordinate) -> CGPoint {
        let (east, north) = planar(coordinate)
        let x = a * east - b * north + tx
        let yUp = b * east + a * north + ty
        return CGPoint(x: x, y: -yUp / max(aspect, 0.0001))
    }

    /// Normalised point on the plate → ground position.
    func coordinate(_ point: CGPoint) -> Coordinate {
        let u = point.x - tx
        let v = (-point.y * aspect) - ty
        let denominator = a * a + b * b
        guard denominator > 0 else { return origin }
        return spherical(east: (u * a + v * b) / denominator,
                         north: (v * a - u * b) / denominator)
    }

    /// Metres per unit of normalised chart width — how much ground a chart covers.
    var metresPerUnit: Double {
        let scale = (a * a + b * b).squareRoot()
        return scale > 0 ? 1 / scale : 0
    }

    /// Degrees clockwise from north that the chart is printed at. 0 means north-up.
    ///
    /// Negated because the fit works in a y-up plane while the reading anyone wants is the
    /// compass one: a plate drawn with north to the upper-left reads as a clockwise rotation.
    var chartBearing: Double {
        let degrees = -atan2(b, a) * 180 / .pi
        let wrapped = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return wrapped > 359.999 ? 0 : wrapped
    }

    // MARK: Fitting

    /// Least-squares similarity through every anchor. Two anchors fit exactly, which is why
    /// `rmsMetres` only starts meaning something at three — worth saying out loud in the UI
    /// rather than showing a reassuring zero.
    static func fit(icao: String, anchors: [GeoAnchor], aspect: Double) -> ChartGeoreference? {
        guard anchors.count >= 2 else { return nil }

        let origin = Coordinate(
            latitude: anchors.map(\.coordinate.latitude).reduce(0, +) / Double(anchors.count),
            longitude: anchors.map(\.coordinate.longitude).reduce(0, +) / Double(anchors.count)
        )

        var draft = ChartGeoreference(icao: icao, origin: origin, a: 1, b: 0, tx: 0, ty: 0,
                                      aspect: aspect, anchors: anchors, rmsMetres: 0)

        let plane = anchors.map { draft.planar($0.coordinate) }
        let target = anchors.map { (x: Double($0.chart.x), yUp: -Double($0.chart.y) * aspect) }

        let count = Double(anchors.count)
        let meanEast = plane.map(\.east).reduce(0, +) / count
        let meanNorth = plane.map(\.north).reduce(0, +) / count
        let meanX = target.map(\.x).reduce(0, +) / count
        let meanY = target.map(\.yUp).reduce(0, +) / count

        var numeratorA = 0.0, numeratorB = 0.0, denominator = 0.0
        for (ground, chart) in zip(plane, target) {
            let east = ground.east - meanEast
            let north = ground.north - meanNorth
            let x = chart.x - meanX
            let y = chart.yUp - meanY
            numeratorA += x * east + y * north
            numeratorB += y * east - x * north
            denominator += east * east + north * north
        }
        guard denominator > 1e-9 else { return nil }

        draft.a = numeratorA / denominator
        draft.b = numeratorB / denominator
        guard draft.a.isFinite, draft.b.isFinite, (draft.a * draft.a + draft.b * draft.b) > 0 else { return nil }

        draft.tx = meanX - (draft.a * meanEast - draft.b * meanNorth)
        draft.ty = meanY - (draft.b * meanEast + draft.a * meanNorth)

        var squared = 0.0
        for anchor in anchors {
            let predicted = draft.chartPoint(anchor.coordinate)
            let dx = Double(predicted.x - anchor.chart.x)
            let dy = Double(predicted.y - anchor.chart.y) * aspect
            squared += (dx * dx + dy * dy)
        }
        draft.rmsMetres = (squared / count).squareRoot() * draft.metresPerUnit

        return draft
    }

    /// Anchors alone cannot say whether the fit is any good when there are only two of them,
    /// so the sanity check is whether the airport lands on the plate at a sane size.
    func plausibility(coveringMetres extent: Double) -> String? {
        guard metresPerUnit > 0 else { return "The two points are too close together to fit a scale." }
        let chartCoverage = metresPerUnit
        if chartCoverage < extent * 0.3 {
            return "The airport would be far wider than the chart — check the two points are not the same feature."
        }
        if chartCoverage > extent * 12 {
            return "The airport would be a speck on the chart — check the two points are the ones you meant."
        }
        return nil
    }
}

// MARK: - Storage

/// Calibrations live beside the marks and the category corrections, keyed by the same
/// library-relative chart id.
enum GeoreferenceStore {

    private static var fileURL: URL? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Chartdesk", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("georeference.json")
    }

    static func load() -> [String: ChartGeoreference] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: ChartGeoreference].self, from: data)) ?? [:]
    }

    static func save(_ references: [String: ChartGeoreference]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(references) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
