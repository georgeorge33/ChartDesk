import Foundation

// MARK: - Observed wind

struct WindObservation: Equatable {
    /// Degrees, referenced to **true** north as METAR reports it. nil when variable.
    var direction: Int?
    var knots: Int
    var gustKnots: Int?
    var isVariable = false

    var isCalm: Bool { knots == 0 && direction == nil }

    var summary: String {
        if isCalm { return "Calm" }
        let gust = gustKnots.map { " gusting \($0)" } ?? ""
        guard let direction = direction else { return "Variable \(knots) kt\(gust)" }
        return String(format: "%03d° at %d kt%@", direction, knots, gust)
    }
}

// MARK: - Per-runway components

struct RunwayWind: Identifiable, Equatable {
    let runway: String
    /// Magnetic, from the designator.
    let magneticHeading: Int
    /// Positive into the nose, negative on the tail.
    let headwind: Double
    /// Always positive; `fromRight` says which side.
    let crosswind: Double
    let fromRight: Bool
    let gustCrosswind: Double?
    /// Signed angle from the runway's heading to the wind, -180...180, positive off the right
    /// side. Stored rather than recomputed so the diagram and these numbers cannot disagree.
    let windOffset: Double

    var id: String { runway }
    var isTailwind: Bool { headwind < -0.5 }

    var headwindLabel: String {
        let value = Int(abs(headwind).rounded())
        return isTailwind ? "\(value) kt tail" : "\(value) kt head"
    }

    var crosswindLabel: String {
        "\(Int(crosswind.rounded())) kt from the \(fromRight ? "right" : "left")"
    }

    /// For the chart-list column, which is too narrow for "from the right".
    var shortCrosswind: String {
        "\(Int(crosswind.rounded())) kt \(fromRight ? "R" : "L")"
    }

    /// Beside the crosswind leg of the diagram, where the side has to be spelled out: the
    /// arrow there shows which way the wind pushes you, not which side it comes from.
    var crosswindTag: String {
        "\(Int(crosswind.rounded())) kt cross \(fromRight ? "R" : "L")"
    }

    var shortHeadwind: String {
        "\(Int(abs(headwind).rounded())) kt \(isTailwind ? "tail" : "head")"
    }
}

// MARK: - Maths

enum WindMath {

    /// Pulls the wind group out of a raw METAR.
    ///
    /// Handles `05010KT`, gusts, `VRB`, calm, and metric units. The group is found by shape
    /// rather than position, because the report may or may not begin with `METAR`.
    static func parse(metar: String) -> WindObservation? {
        let pattern = #"\b(\d{3}|VRB)P?(\d{2,3})(?:GP?(\d{2,3}))?(KT|MPS|KMH)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: metar,
                                           range: NSRange(metar.startIndex..., in: metar))
        else { return nil }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: metar) else { return nil }
            return String(metar[range])
        }

        guard let head = group(1), let rawSpeed = group(2).flatMap({ Int($0) }) else { return nil }
        let unit = group(4) ?? "KT"
        let gust = group(3).flatMap { Int($0) }

        func knots(_ value: Int) -> Int {
            switch unit {
            case "MPS": return Int((Double(value) * 1.94384).rounded())
            case "KMH": return Int((Double(value) * 0.539957).rounded())
            default: return value
            }
        }

        if head == "VRB" {
            return WindObservation(direction: nil, knots: knots(rawSpeed),
                                   gustKnots: gust.map(knots), isVariable: true)
        }
        guard let direction = Int(head) else { return nil }
        if direction == 0 && rawSpeed == 0 {
            return WindObservation(direction: nil, knots: 0, gustKnots: nil)
        }
        return WindObservation(direction: direction, knots: knots(rawSpeed),
                               gustKnots: gust.map(knots))
    }

    /// A runway designator's magnetic heading. "04R" is 040, "9" is 090.
    static func magneticHeading(of runway: String) -> Int? {
        let digits = runway.trimmingCharacters(in: .whitespaces).uppercased().prefix { $0.isNumber }
        guard let number = Int(digits), number >= 1, number <= 36 else { return nil }
        // Runway 36 is 360°, not 0° — the same convention the wind uses.
        return number * 10
    }

    /// Splits a typed list — "04L 04R, 09/27" — into designators.
    static func runways(from text: String) -> [String] {
        let parts = text.uppercased().split(whereSeparator: { " ,;/\n\t".contains($0) })
        var seen = Set<String>()
        return parts.map(String.init).filter { magneticHeading(of: $0) != nil && seen.insert($0).inserted }
    }

    /// Head and cross components for each runway.
    ///
    /// `variationWest` matters and is easy to miss: METAR reports wind against **true** north
    /// while a runway designator is **magnetic**, so at Boston's 15°W the two references differ
    /// by 15° — enough to change a crosswind by a third in a marginal case. Positive is west.
    static func components(wind: WindObservation,
                          variationWest: Double,
                          runways list: [String]) -> [RunwayWind] {
        guard let trueDirection = wind.direction else { return [] }
        // Magnetic = true + westerly variation.
        let magneticWind = Double(trueDirection) + variationWest

        return list.compactMap { runway in
            guard let heading = magneticHeading(of: runway) else { return nil }
            let offset = signedDifference(from: Double(heading), to: magneticWind)
            let radians = offset * .pi / 180

            return RunwayWind(runway: runway,
                              magneticHeading: heading,
                              headwind: Double(wind.knots) * cos(radians),
                              crosswind: abs(Double(wind.knots) * sin(radians)),
                              fromRight: sin(radians) >= 0,
                              gustCrosswind: wind.gustKnots.map { abs(Double($0) * sin(radians)) },
                              windOffset: offset)
        }
    }

    /// Smallest signed angle from one bearing to another, in −180…180.
    static func signedDifference(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    /// The runway with the most headwind, for highlighting. Ties go to the lower designator so
    /// the choice is at least stable.
    static func best(_ winds: [RunwayWind]) -> RunwayWind? {
        winds.max { left, right in
            left.headwind == right.headwind
                ? left.magneticHeading > right.magneticHeading
                : left.headwind < right.headwind
        }
    }
}
