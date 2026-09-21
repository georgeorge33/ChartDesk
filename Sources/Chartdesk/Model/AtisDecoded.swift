import Foundation

/// The figures an ATIS exists to carry, lifted out of the wall of capitals.
///
/// An ATIS is mostly advisories — cranes, closed taxiways, bird activity, readback
/// instructions — with the eight things you actually tune in for buried in the first line.
/// This pulls those eight out and leaves the rest where it is: the full text stays above,
/// because the advisories matter too and no decoder should be trusted to summarise them.
///
/// Anything it cannot read with confidence it leaves out. A missing row is honest; a wrong
/// one is worse than the raw text it was meant to save you reading.
struct AtisDecoded: Equatable {

    struct Field: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    var info: String?
    var time: String?
    var wind: String?
    var visibility: String?
    var clouds: String?
    var temperature: String?
    var dewPoint: String?
    var altimeter: String?

    /// In the order they are read out, with whatever was not found left out.
    var fields: [Field] {
        [("Info", info), ("Time", time), ("Wind", wind), ("Visibility", visibility),
         ("Clouds", clouds), ("Temp", temperature), ("Dew point", dewPoint),
         ("Altimeter", altimeter)]
            .compactMap { label, value in value.map { Field(label: label, value: $0) } }
    }

    var isEmpty: Bool { fields.isEmpty }
}

extension AtisMarkup {

    /// Reads an ATIS.
    static func decode(_ text: String) -> AtisDecoded {
        let coded = String(text[codedRun(of: text)])
        var out = AtisDecoded()
        out.info = information(in: text)
        out.time = issued(in: text)
        out.wind = wind(in: text)
        out.visibility = visibility(in: text, coded: coded)
        out.clouds = clouds(in: text)
        (out.temperature, out.dewPoint) = air(in: text, coded: coded)
        out.altimeter = pressure(in: coded)
        return out
    }

    // MARK: Pieces

    private static let informationGroup =
        try! NSRegularExpression(pattern: #"\bINFO(?:RMATION)?\s+([A-Z]+)\b"#)
    private static let windCoded = try! NSRegularExpression(
        pattern: #"\b(\d{3}|VRB)(\d{2,3})(?:G(\d{2,3}))?(KT|MPS|KMH)\b"#)
    private static let windSpoken = try! NSRegularExpression(
        pattern: #"\bWIND\s+(\d{3})\s*(?:AT|/)\s*(\d{1,3})\b"#)
    private static let windCalm = try! NSRegularExpression(
        pattern: #"\b(?:WIND\s+)?(CALM|LIGHT AND VARIABLE)\b"#)
    private static let milesGroup = try! NSRegularExpression(
        pattern: #"\bM?(?:\d{1,2} \d/\d|\d/\d|\d{1,2})SM\b"#)
    private static let metresLabelled = try! NSRegularExpression(
        pattern: #"\bVIS(?:IBILITY)?\s+(\d{3,4})\b"#)
    /// "VISIBILITY 10" — an American controller says the miles without the unit. One or two
    /// figures is miles; three or four is metres, which is what the rule above catches.
    private static let milesLabelled = try! NSRegularExpression(
        pattern: #"\bVIS(?:IBILITY)?\s+(\d{1,2})(?!\d)"#)
    /// "CEILING 3500 BROKEN", the way it is read out rather than coded.
    private static let spokenCeiling = try! NSRegularExpression(
        pattern: #"\b(?:CEILING|CIG)\s+(\d{3,5})\s+(FEW|SCATTERED|BROKEN|OVERCAST)\b"#)
    /// A bare four-figure visibility, accepted only where a METAR puts it: straight after the
    /// wind. On its own a four-figure number in an ATIS is as likely to be a frequency.
    private static let metresAfterWind = try! NSRegularExpression(
        pattern: #"(?:KT|MPS|KMH)\s+(\d{4})\b"#)
    private static let layerGroup = try! NSRegularExpression(
        pattern: #"\b(FEW|SCT|BKN|OVC|VV)(\d{3})(CB|TCU)?\b"#)
    private static let clearGroup = try! NSRegularExpression(
        pattern: #"\b(SKC|CLR|NCD|NSC|CAVOK)\b"#)
    private static let airGroup = try! NSRegularExpression(
        pattern: #"\b(M?\d{1,2})/(M?\d{1,2})\b"#)
    private static let spokenTemp = try! NSRegularExpression(
        pattern: #"\bTEMP(?:ERATURE)?\s+(MINUS\s+)?(\d{1,2})\b"#)
    private static let spokenDew = try! NSRegularExpression(
        pattern: #"\bDEW\s?POINT\s+(MINUS\s+)?(\d{1,2})\b"#)
    private static let inches = try! NSRegularExpression(
        pattern: #"\b(?:A|ALTIMETER\s+)(\d{4})\b"#)
    private static let hectopascals = try! NSRegularExpression(
        pattern: #"\bQ(?:NH)?\s?(\d{3,4})\b"#)

    private static let phonetics = [
        "ALFA": "A", "ALPHA": "A", "BRAVO": "B", "CHARLIE": "C", "DELTA": "D", "ECHO": "E",
        "FOXTROT": "F", "GOLF": "G", "HOTEL": "H", "INDIA": "I", "JULIETT": "J",
        "JULIET": "J", "KILO": "K", "LIMA": "L", "MIKE": "M", "NOVEMBER": "N", "OSCAR": "O",
        "PAPA": "P", "QUEBEC": "Q", "ROMEO": "R", "SIERRA": "S", "TANGO": "T",
        "UNIFORM": "U", "VICTOR": "V", "WHISKEY": "W", "XRAY": "X", "YANKEE": "Y",
        "ZULU": "Z",
    ]

    private static func group(_ regex: NSRegularExpression, _ text: String,
                              _ index: Int = 1) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func information(in text: String) -> String? {
        guard let word = group(informationGroup, text) else { return nil }
        if word.count == 1 { return word }
        guard let letter = phonetics[word] else { return nil }
        return "\(letter) — \(word.capitalized)"
    }

    private static func issued(in text: String) -> String? {
        guard let match = timeGroup.firstMatch(in: text,
                                               range: NSRange(text.startIndex..., in: text)),
              let hour = Range(match.range(at: 1), in: text),
              let minute = Range(match.range(at: 2), in: text) else { return nil }
        return "\(text[hour]):\(text[minute])Z"
    }

    private static func wind(in text: String) -> String? {
        let whole = NSRange(text.startIndex..., in: text)
        if let match = windCoded.firstMatch(in: text, range: whole),
           let from = Range(match.range(at: 1), in: text),
           let speed = Range(match.range(at: 2), in: text),
           let unit = Range(match.range(at: 4), in: text) {
            let bearing = text[from] == "VRB" ? "Variable" : "\(text[from])°"
            var said = "\(bearing) \(Int(text[speed]) ?? 0) \(spoken(unit: String(text[unit])))"
            if match.range(at: 3).location != NSNotFound,
               let gust = Range(match.range(at: 3), in: text) {
                said += " gusting \(Int(text[gust]) ?? 0)"
            }
            return said
        }
        if let match = windSpoken.firstMatch(in: text, range: whole),
           let from = Range(match.range(at: 1), in: text),
           let speed = Range(match.range(at: 2), in: text) {
            return "\(text[from])° \(Int(text[speed]) ?? 0) kt"
        }
        if windCalm.firstMatch(in: text, range: whole) != nil { return "Calm" }
        return nil
    }

    private static func spoken(unit: String) -> String {
        switch unit {
        case "MPS": return "m/s"
        case "KMH": return "km/h"
        default: return "kt"
        }
    }

    private static func visibility(in text: String, coded: String) -> String? {
        if let match = milesGroup.firstMatch(in: text,
                                             range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            let group = String(text[range])
            let body = group.replacingOccurrences(of: "SM", with: "")
            return group.hasPrefix("M") ? "less than \(body.dropFirst()) SM" : "\(body) SM"
        }
        if clearGroup.firstMatch(in: coded, range: NSRange(coded.startIndex..., in: coded))
            .map({ (Range($0.range, in: coded).map { String(coded[$0]) } ?? "") == "CAVOK" }) == true {
            return "CAVOK"
        }
        if let metres = group(metresLabelled, text) ?? group(metresAfterWind, coded) {
            if metres == "9999" { return "10 km or more" }
            // Coded to four figures, so "0800" is eight hundred metres and reads as noise.
            let trimmed = String(metres.drop(while: { $0 == "0" }))
            return "\(trimmed.isEmpty ? "0" : trimmed) m"
        }
        if let miles = group(milesLabelled, text) { return "\(miles) SM" }
        return nil
    }

    private static func clouds(in text: String) -> String? {
        let whole = NSRange(text.startIndex..., in: text)
        var layers: [String] = []
        for match in layerGroup.matches(in: text, range: whole) {
            guard let kind = Range(match.range(at: 1), in: text),
                  let hundreds = Range(match.range(at: 2), in: text),
                  let feet = Int(text[hundreds]) else { continue }
            var said = "\(text[kind]) \(height(feet * 100))"
            if match.range(at: 3).location != NSNotFound,
               let extra = Range(match.range(at: 3), in: text) {
                said += " \(text[extra])"
            }
            layers.append(said)
        }
        if !layers.isEmpty { return layers.joined(separator: " · ") }
        if let match = spokenCeiling.firstMatch(in: text, range: whole),
           let feet = Range(match.range(at: 1), in: text),
           let kind = Range(match.range(at: 2), in: text),
           let value = Int(text[feet]) {
            return "\(text[kind].capitalized) \(height(value))"
        }
        if let clear = group(clearGroup, text, 1) {
            return clear == "CAVOK" ? "CAVOK" : "No cloud reported"
        }
        return nil
    }

    private static func height(_ feet: Int) -> String {
        feet >= 1000 ? "\(feet / 1000),\(String(format: "%03d", feet % 1000)) ft" : "\(feet) ft"
    }

    /// Temperature and dew point, which are reported together and read apart.
    ///
    /// Only inside the coded run. Past it an ATIS is plain English and "RWY 9/27 CLSD" looks
    /// exactly like a temperature over a dew point.
    private static func air(in text: String, coded: String) -> (String?, String?) {
        let codedRange = NSRange(coded.startIndex..., in: coded)
        if let match = airGroup.firstMatch(in: coded, range: codedRange),
           let first = Range(match.range(at: 1), in: coded),
           let second = Range(match.range(at: 2), in: coded) {
            return (celsius(String(coded[first])), celsius(String(coded[second])))
        }
        let whole = NSRange(text.startIndex..., in: text)
        var temperature: String?, dew: String?
        if let match = spokenTemp.firstMatch(in: text, range: whole),
           let value = Range(match.range(at: 2), in: text) {
            let below = match.range(at: 1).location != NSNotFound
            temperature = celsius((below ? "M" : "") + text[value])
        }
        if let match = spokenDew.firstMatch(in: text, range: whole),
           let value = Range(match.range(at: 2), in: text) {
            let below = match.range(at: 1).location != NSNotFound
            dew = celsius((below ? "M" : "") + text[value])
        }
        return (temperature, dew)
    }

    private static func celsius(_ group: String) -> String? {
        let below = group.hasPrefix("M")
        guard let value = Int(group.drop(while: { $0 == "M" })) else { return nil }
        return "\(below ? -value : value)°C"
    }

    /// Both units, because an ATIS gives one and half the world flies on the other.
    private static func pressure(in coded: String) -> String? {
        let range = NSRange(coded.startIndex..., in: coded)
        if let match = inches.firstMatch(in: coded, range: range),
           let digits = Range(match.range(at: 1), in: coded),
           let hundredths = Double(coded[digits]) {
            let inHg = hundredths / 100
            return String(format: "%.2f inHg · %.0f hPa", inHg, inHg * 33.8639)
        }
        if let match = hectopascals.firstMatch(in: coded, range: range),
           let digits = Range(match.range(at: 1), in: coded),
           let hPa = Double(coded[digits]) {
            return String(format: "%.0f hPa · %.2f inHg", hPa, hPa / 33.8639)
        }
        return nil
    }
}
