import Foundation

/// Picks out the parts of an ATIS worth colouring.
///
/// An ATIS is a wall of capitals, and the handful of values you actually need are buried in the
/// middle of crane and hold-short advisories. Two tiers rather than a colour per field, because
/// six colours is a rainbow you have to decode:
///
/// - **key** — the letter and the wind, marked whatever their value, because they are what you
///   read every single time.
/// - **caution** — a value worth a second look: visibility or ceiling low enough to matter,
///   temperature or pressure away from the ordinary, or weather that changes the plan.
///
/// Everything else stays plain, which is the point: the marks only mean something if most of
/// the report is unmarked.
enum AtisMarkup {

    enum Kind {
        case key
        case caution
    }

    struct Span {
        let range: Range<String.Index>
        let kind: Kind
    }

    // MARK: Thresholds
    //
    // Each of these is a boundary where the answer to "can I do this?" changes, rather than a
    // round number: below 3 SM an approach stops being visual and minima start to matter; below
    // a 1000 ft ceiling you are on instruments; 3°C is where ice becomes a question on the
    // ground and in the climb, and 30°C is where performance does; outside 1000-1030 hPa the
    // altimetry error is large enough to be worth thinking about.

    static let lowVisibilityMiles = 3.0
    static let lowVisibilityMetres = 5000.0
    static let lowCeilingFeet = 1000.0
    static let lowTemperature = 3.0
    static let highTemperature = 30.0
    static let lowPressureHPa = 1000.0
    static let highPressureHPa = 1030.0

    /// Weather that changes the plan rather than merely the view. Mist, haze and light rain are
    /// deliberately absent — marking those would mark half the reports in Europe.
    ///
    /// `VA` and `GS` are absent for a different reason. In the plain-English half of an American
    /// ATIS they mean visual approach and glideslope, and "VA 4L" is not volcanic ash any more
    /// than "RWY 4R GS OTS" is hail.
    private static let hazardousWeather = ["TS", "FZ", "FG", "GR", "PL", "FC", "SQ", "SS", "DS"]

    // MARK: - Marking up

    /// Spans to colour, in order and never overlapping.
    static func spans(in text: String) -> [Span] {
        var found: [(Span, Int)] = []

        func add(_ pattern: String, _ kind: Kind, group: Int = 0,
                 within limit: Range<String.Index>? = nil,
                 when accept: (String) -> Bool = { _ in true }) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let searched = NSRange(limit ?? text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: searched) {
                guard let marked = Range(match.range(at: group), in: text) else { continue }
                // The test reads the whole match, so a pattern can decide on a capture it does
                // not colour -- "CEILING 400 OVC" is judged on the number and marked on both.
                guard let all = Range(match.range, in: text), accept(String(text[all])) else { continue }
                found.append((Span(range: marked, kind: kind), found.count))
            }
        }

        // The information letter, spoken or coded: "INFO B", "INFORMATION BRAVO".
        add(#"\bINFO(?:RMATION)?\s+[A-Z]+\b"#, .key)

        // The wind. Coded as a METAR group, or spelled out the way a controller says it.
        add(#"\b(?:WIND\s+)?(?:\d{3}|VRB)P?\d{2,3}(?:GP?\d{2,3})?(?:KT|MPS|KMH)\b"#, .key)
        add(#"\bWIND\s+(?:CALM|LIGHT AND VARIABLE)\b"#, .key)
        add(#"\bWIND\s+(?:\d{3}|VRB)\s*(?:AT|/)\s*\d{1,3}(?:\s*(?:KT|KNOTS))?\b"#, .key)

        // Visibility. Statute miles carry their own unit; metres have to be labelled, since a
        // bare four-digit number in an ATIS is as likely to be a frequency or a time.
        add(#"\bM?(?:\d{1,2} \d/\d|\d/\d|\d{1,2})SM\b"#, .caution) { match in
            guard let miles = statuteMiles(match) else { return false }
            return miles < lowVisibilityMiles
        }
        add(#"\bVIS(?:IBILITY)?\s+(\d{3,4})\b"#, .caution) { match in
            guard let metres = Double(digits(match)) else { return false }
            return metres < lowVisibilityMetres
        }
        // An RVR is only ever reported when the visibility is already a problem.
        add(#"\bRVR\s*\d{3,4}\b"#, .caution)
        add(#"\bR\d{2}[LCR]?/[MP]?\d{4}(?:V[MP]?\d{4})?(?:FT|[UDN])?\b"#, .caution)

        // Ceiling: the lowest broken or overcast layer, or a vertical visibility.
        add(#"\b(?:BKN|OVC|VV)\d{3}\b"#, .caution) { match in
            guard let hundreds = Double(digits(match)) else { return false }
            return hundreds * 100 < lowCeilingFeet
        }
        add(#"\b(?:CEILING|CIG)\s+\d{3,5}\b"#, .caution) { match in
            guard let feet = Double(digits(match)) else { return false }
            return feet < lowCeilingFeet
        }

        // Temperature and dew point, together as they are reported.
        add(#"\b(M|MINUS )?\d{1,2}/(M|MINUS )?\d{1,2}\b"#, .caution) { match in
            guard let celsius = temperature(match) else { return false }
            return celsius <= lowTemperature || celsius >= highTemperature
        }
        add(#"\bTEMP(?:ERATURE)?\s+(?:M|MINUS\s+)?\d{1,2}\b"#, .caution) { match in
            guard let celsius = temperature(match) else { return false }
            return celsius <= lowTemperature || celsius >= highTemperature
        }

        // Pressure, in either unit and under any of its names.
        add(#"\bA\d{4}\b"#, .caution) { match in
            guard let hundredths = Double(digits(match)) else { return false }
            return outsideOrdinary(hPa: hundredths / 100 * 33.8639)
        }
        add(#"\b(?:ALTIMETER|ALTIMETER SETTING)\s+\d{4}\b"#, .caution) { match in
            guard let hundredths = Double(digits(match)) else { return false }
            return outsideOrdinary(hPa: hundredths / 100 * 33.8639)
        }
        add(#"\bQ(?:NH)?\s?\d{3,4}\b"#, .caution) { match in
            guard let hPa = Double(digits(match)) else { return false }
            return outsideOrdinary(hPa: hPa)
        }

        // Present weather, judged on what it is rather than that it is there, and looked for
        // only in the coded run at the top of the report. Past the pressure group an ATIS is
        // plain English, where these two-letter codes mean other things entirely.
        add(#"(?<![A-Z])[+-]?(?:VC)?(?:TS|FZ|SH|BL|DR|MI|BC|PR)*(?:DZ|RA|SN|SG|IC|PL|GR|GS|UP|BR|FG|FU|VA|DU|SA|HZ|PY|PO|SQ|FC|SS|DS)(?![A-Z])"#,
            .caution, within: codedRun(of: text)) { match in
            if match.hasPrefix("+") { return true }
            return hazardousWeather.contains { match.contains($0) }
        }

        // Sorted, and overlaps dropped: a doubled mark reads as a mistake, and the earlier
        // pattern is the more specific one.
        let sorted = found.sorted {
            $0.0.range.lowerBound == $1.0.range.lowerBound
                ? $0.1 < $1.1
                : $0.0.range.lowerBound < $1.0.range.lowerBound
        }
        var kept: [Span] = []
        for (span, _) in sorted {
            if let last = kept.last, span.range.lowerBound < last.range.upperBound { continue }
            kept.append(span)
        }
        return kept
    }

    /// The coded run at the top of a report: everything up to and including the pressure group,
    /// which is the last coded field before a controller starts talking about taxiways.
    static func codedRun(of text: String) -> Range<String.Index> {
        let pattern = #"\b(?:A\d{4}|Q\d{3,4}|QNH\s?\d{3,4}|ALTIMETER\s+\d{4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            // No pressure group to end it, so there is nothing better to go on than all of it.
            return text.startIndex..<text.endIndex
        }
        return text.startIndex..<range.upperBound
    }

    // MARK: - Age

    /// The Zulu time group a report carries — "SFO ATIS INFO X 1756Z" — resolved against the
    /// clock. An ATIS is reissued at least hourly, so an age much past that says you are
    /// reading one that has been superseded.
    static func issueTime(in text: String, now: Date) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{2})(\d{2})Z\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text),
              let hour = Int(text[hourRange]), let minute = Int(text[minuteRange]),
              hour < 24, minute < 60 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        guard let issued = calendar.date(from: parts) else { return nil }
        // Nothing is issued in the future, so a report that looks it came from yesterday.
        return issued > now.addingTimeInterval(120)
            ? calendar.date(byAdding: .day, value: -1, to: issued)
            : issued
    }

    // MARK: - Reading values out of a group

    private static func digits(_ text: String) -> String {
        String(text.reversed().prefix { $0.isNumber }.reversed())
    }

    /// "10SM", "1 1/2SM", "3/4SM", "M1/4SM".
    static func statuteMiles(_ group: String) -> Double? {
        let body = group
            .replacingOccurrences(of: "SM", with: "")
            .replacingOccurrences(of: "M", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        var total = 0.0
        for part in body.split(separator: " ") {
            if part.contains("/") {
                let halves = part.split(separator: "/")
                guard halves.count == 2,
                      let top = Double(halves[0]), let bottom = Double(halves[1]), bottom != 0
                else { return nil }
                total += top / bottom
            } else {
                guard let whole = Double(part) else { return nil }
                total += whole
            }
        }
        return total
    }

    /// The air temperature out of "18/11", "M05/M08" or "TEMPERATURE MINUS 5".
    static func temperature(_ group: String) -> Double? {
        let first = group
            .replacingOccurrences(of: "TEMPERATURE", with: "")
            .replacingOccurrences(of: "TEMP", with: "")
            .split(separator: "/")
            .first
            .map(String.init) ?? group
        let negative = first.contains("MINUS") || first.trimmingCharacters(in: .whitespaces).hasPrefix("M")
        let value = first.filter(\.isNumber)
        guard let magnitude = Double(value) else { return nil }
        return negative ? -magnitude : magnitude
    }

    private static func outsideOrdinary(hPa: Double) -> Bool {
        hPa < lowPressureHPa || hPa > highPressureHPa
    }
}
