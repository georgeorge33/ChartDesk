import Foundation

/// Each airport's magnetic variation, worked out for today from the World Magnetic Model
/// rather than typed in from a chart.
///
/// The model needs only where the airport is. The bundled airport table places the six
/// thousand fields with a scheduled service, and the runway table five thousand more — KGHG
/// Marshfield among them. An airport neither of them places has no variation here, and the
/// Runways tab says so rather than quietly turning the wind by nothing.
enum MagneticVariation {

    /// NOAA's coefficients, bundled as `WMM.COF` just as NOAA issues them. Nil only if a
    /// build left the file out.
    static let model: MagneticModel? = {
        guard let url = Bundle.main.url(forResource: "WMM", withExtension: "COF"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MagneticModel(text)
    }()

    /// The variation at an airport, in degrees west — the sign a chart's "VAR 14°W" and
    /// `WindMath` both use, so an east variation comes out negative — or nil where it cannot
    /// be known.
    static func west(at icao: String?, on date: Date = .now) -> Double? {
        guard let code = icao?.uppercased(), let model, let place = position(of: code),
              let east = model.declination(latitude: place.latitude,
                                           longitude: place.longitude,
                                           year: MagneticModel.decimalYear(date))
        else { return nil }
        return -east
    }

    /// As a chart prints it: "14°W", "1°E", or "0°" on the line where there is none.
    static func text(_ west: Double) -> String {
        let degrees = Int(abs(west).rounded())
        guard degrees > 0 else { return "0°" }
        return "\(degrees)°" + (west > 0 ? "W" : "E")
    }

    private static func position(of code: String) -> Coordinate? {
        WorldData.airport(code)?.coordinate ?? runwayPositions[code]
    }

    /// A runway end for each airport the runway table has, for those the airport table leaves
    /// out. Read the first time one of those is asked about, and only then: a mile either way
    /// makes no difference the model could show.
    private static let runwayPositions: [String: Coordinate] = {
        var found: [String: Coordinate] = [:]
        for runway in WorldData.loadRunways() where found[runway.airport] == nil {
            found[runway.airport] = runway.low
        }
        return found
    }()
}
