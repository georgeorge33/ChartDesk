import Foundation

/// How flyable a field is, from its METAR: the four categories and their colours.
///
/// The convention is the American one and the colours are not a choice — green, blue, red
/// and magenta are what every briefing map has used for decades, and a chart that used its
/// own would be actively misleading.
///
/// The rule is the *worse* of ceiling and visibility. A field with ten miles of visibility
/// and a two-hundred-foot overcast is LIFR, and a clear sky over half a mile of fog is too.
enum FlightCategory: String {
    case vfr = "VFR"
    case mvfr = "MVFR"
    case ifr = "IFR"
    case lifr = "LIFR"

    /// Ceiling: the lowest broken or overcast layer, or a vertical visibility.
    ///
    /// Few and scattered are not a ceiling — you can climb through them legally and see the
    /// ground between — which is why a sky of SCT002 is still VFR on this scale.
    static func of(ceilingFeet: Double?, visibilityMiles: Double?) -> FlightCategory? {
        guard ceilingFeet != nil || visibilityMiles != nil else { return nil }
        let byCeiling = ceilingFeet.map { feet -> FlightCategory in
            if feet < 500 { return .lifr }
            if feet < 1000 { return .ifr }
            if feet <= 3000 { return .mvfr }
            return .vfr
        }
        let byVisibility = visibilityMiles.map { miles -> FlightCategory in
            if miles < 1 { return .lifr }
            if miles < 3 { return .ifr }
            if miles <= 5 { return .mvfr }
            return .vfr
        }
        return [byCeiling, byVisibility].compactMap { $0 }.min { $0.severity > $1.severity }
    }

    /// Worst first, which is the order the rule above picks in.
    private var severity: Int {
        switch self {
        case .lifr: return 3
        case .ifr: return 2
        case .mvfr: return 1
        case .vfr: return 0
        }
    }

    // MARK: - Reading a METAR

    private static let remarks = try! NSRegularExpression(pattern: #"\bRMK\b"#)
    private static let milesGroup = try! NSRegularExpression(
        pattern: #"\b(M)?((?:\d{1,2} )?\d{1,2}/\d|\d{1,2})SM\b"#)
    /// A four-figure visibility in metres, accepted where a METAR puts it: after the wind,
    /// allowing for the variable-direction group that can sit between them — "29010KT
    /// 270V340 9999". On its own a bare four-figure number is as likely to be a time.
    private static let metresAfterWind = try! NSRegularExpression(
        pattern: #"(?:KT|MPS|KMH)(?:\s+\d{3}V\d{3})?\s+(\d{4})(?:[A-Z]{1,3})?\b"#)
    private static let ceilingGroup = try! NSRegularExpression(
        pattern: #"\b(?:BKN|OVC|VV)(\d{3})\b"#)
    private static let clearSky = try! NSRegularExpression(
        pattern: #"\b(CAVOK|SKC|CLR|NCD|NSC)\b"#)

    /// The category a raw METAR reports, or nothing if it does not say enough to tell.
    ///
    /// Everything after `RMK` is thrown away first. Remarks are a different grammar — sea
    /// level pressure, precise temperatures, tower observations — and reading them as though
    /// they were the body is how a decoder invents a ceiling.
    static func read(_ metar: String) -> FlightCategory? {
        let text = body(of: metar)
        let whole = NSRange(text.startIndex..., in: text)

        if clearSky.firstMatch(in: text, range: whole) != nil,
           ceilingGroup.firstMatch(in: text, range: whole) == nil,
           milesGroup.firstMatch(in: text, range: whole) == nil,
           metresAfterWind.firstMatch(in: text, range: whole) == nil {
            return .vfr
        }

        var ceiling: Double?
        for match in ceilingGroup.matches(in: text, range: whole) {
            guard let digits = Range(match.range(at: 1), in: text),
                  let hundreds = Double(text[digits]) else { continue }
            ceiling = min(ceiling ?? .greatestFiniteMagnitude, hundreds * 100)
        }

        var visibility: Double?
        if let match = milesGroup.firstMatch(in: text, range: whole),
           let range = Range(match.range, in: text),
           let miles = AtisMarkup.statuteMiles(String(text[range])) {
            // "M1/4SM" is *less than* a quarter of a mile, so it must not round up into the
            // category above. A hair under is the honest reading of it.
            visibility = match.range(at: 1).location == NSNotFound ? miles : miles - 0.01
        } else if let match = metresAfterWind.firstMatch(in: text, range: whole),
                  let digits = Range(match.range(at: 1), in: text),
                  let metres = Double(text[digits]) {
            visibility = metres / 1609.344
        }

        return of(ceilingFeet: ceiling, visibilityMiles: visibility)
    }

    private static func body(of metar: String) -> String {
        let whole = NSRange(metar.startIndex..., in: metar)
        guard let match = remarks.firstMatch(in: metar, range: whole),
              let range = Range(match.range, in: metar) else { return metar }
        return String(metar[metar.startIndex..<range.lowerBound])
    }
}
