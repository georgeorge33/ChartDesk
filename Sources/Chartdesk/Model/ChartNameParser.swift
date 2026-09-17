import Foundation

/// Everything Chartdesk can work out about a chart from its file name and folder.
struct ParsedChart {
    var airportCode: String
    var airportName: String?
    var title: String
    var category: ChartCategory
    var runway: String?
}

/// Turns a file path into a `ParsedChart`.
///
/// The rules are deliberately forgiving, because downloaded Lido charts are named in a
/// dozen different ways. Anything the parser gets wrong can be corrected in the app
/// (right-click a chart ▸ Move to Category), and the correction is remembered.
///
/// Recognised Lido chart types:
///   AFC  Airport Facility Chart      AGC  Airport Ground Chart
///   APC  Airport Parking Chart       LVC  Low Visibility Chart
///   AOI  Airport Operational Info    ADC  Aerodrome Chart
///   SID  Std Instrument Departure    SIDPT  SID procedure text    EOSID  Engine-out SID
///   STAR Std Terminal Arrival        STARPT STAR procedure text
///   IAC  Instrument Approach Chart   VAC  Visual Approach Chart   MVC  Minimum Vectoring Chart
enum ChartNameParser {

    // MARK: - Keyword tables

    private static let strongTokens: [ChartCategory: [String]] = [
        .airport: ["AFC", "AGC", "APC", "APDC", "ADC", "AOI", "AOC", "LVC", "LVP", "FAM", "GMC",
                   "TAXI", "TAXIING", "PARKING", "STAND", "STANDS", "APRON", "DOCKING",
                   "AERODROME", "HOTSPOT", "HOTSPOTS", "DEICING", "DEICE", "PUSHBACK"],
        .departure: ["SID", "SIDS", "SIDPT", "EOSID", "DEPARTURE", "DEPARTURES"],
        .arrival: ["STAR", "STARS", "STARPT", "ARRIVAL", "ARRIVALS"],
        .approach: ["IAC", "VAC", "MVC", "ILS", "RNAV", "RNP", "GLS", "GBAS", "LOC", "LLZ",
                    "VOR", "VORDME", "NDB", "IGS", "LDA", "MLS", "PAR", "SRA", "TACAN"],
        .reference: ["RFC", "TXT", "MRC", "MSA", "MINIMA", "LEGEND", "LEGENDS", "NOISE",
                     "ABATEMENT", "ENROUTE"]
    ]

    private static let weakTokens: [ChartCategory: [String]] = [
        .airport: ["AIRPORT", "GROUND", "MOVEMENT", "TERMINAL", "GATE", "GATES", "RAMP",
                   "AIRFIELD", "FACILITY"],
        .departure: ["DEP", "DEPART"],
        .arrival: ["ARR", "ARRIVE", "TRANSITION", "TRANSITIONS"],
        .approach: ["APP", "APPROACH", "APCH", "VISUAL", "CIRCLING", "CIRCLE", "MISSED"],
        .reference: ["REF", "REFERENCE", "GENERAL", "GEN", "INFO", "INFORMATION", "AREA",
                     "TEXT", "OPS", "COM", "COMM", "PROCEDURES", "RESTRICTIONS", "BRIEFING"]
    ]

    /// Used only when no whole token matched, e.g. "EDDF-ILS25C.png".
    private static let substringTokens: [ChartCategory: [String]] = [
        .airport: ["AFC", "AGC", "APC", "APDC", "ADC", "AOI", "LVC", "GMC", "10-9"],
        .departure: ["SID"],
        .arrival: ["STAR"],
        .approach: ["IAC", "VAC", "ILS", "RNAV", "RNP", "VOR", "NDB"],
        .reference: ["TXT", "MRC"]
    ]

    private static let strongWeight = 10
    private static let weakWeight = 4
    private static let folderPenalty = 4
    private static let substringWeight = 3

    /// Most specific first – decides ties.
    private static let tieBreakOrder: [ChartCategory] = [.approach, .departure, .arrival, .airport, .reference]

    /// Order in which categories claim tokens while the lookup tables are built: the first
    /// category to claim a token keeps it. Deliberately independent of
    /// `ChartCategory.displayOrder` so that reordering the tabs in the UI can never change
    /// how a filename is classified.
    private static let classificationOrder: [ChartCategory] = [.airport, .departure, .arrival, .approach, .reference]

    private struct TokenRule {
        let category: ChartCategory
        let weight: Int
    }

    private static let tokenRules: [String: TokenRule] = {
        var table: [String: TokenRule] = [:]
        for category in classificationOrder {
            for token in strongTokens[category] ?? [] where table[token] == nil {
                table[token] = TokenRule(category: category, weight: strongWeight)
            }
        }
        for category in classificationOrder {
            for token in weakTokens[category] ?? [] where table[token] == nil {
                table[token] = TokenRule(category: category, weight: weakWeight)
            }
        }
        return table
    }()

    private static let substringRules: [(token: String, category: ChartCategory)] = {
        var rules: [(token: String, category: ChartCategory)] = []
        for category in classificationOrder {
            for token in substringTokens[category] ?? [] {
                rules.append((token, category))
            }
        }
        return rules
    }()

    /// Four-letter words that look like an ICAO code but never are one.
    private static let blockedCodes: Set<String> = [
        "STAR", "SIDS", "AREA", "TAXI", "LIDO", "MISC", "TEMP", "PAGE", "INFO", "DATA",
        "GATE", "NOTE", "HOLD", "GRID", "ROOT", "MAIN", "TEXT", "PLAN", "DEPS", "ARRS",
        "APPS", "APPR", "PROC", "REFS", "CHRT", "NAVI", "MAPS", "SCAN", "COPY", "TEST",
        "FULL", "PART", "PACK", "FILE", "ZIP", "NEW", "OLD"
    ]

    // MARK: - Entry point

    static func parse(fileURL: URL, relativeComponents: [String], rootName: String) -> ParsedChart {
        let fileNameWithExtension = relativeComponents.last ?? fileURL.lastPathComponent
        let baseName = (fileNameWithExtension as NSString).deletingPathExtension
        let folders = Array(relativeComponents.dropLast())

        var code: String?
        var name: String?

        for folder in folders.reversed() {
            if let candidate = icaoCandidate(in: folder, allowName: true) {
                code = candidate.code
                name = candidate.name
                break
            }
        }
        if code == nil, let candidate = icaoCandidate(in: baseName, allowName: false) {
            code = candidate.code
        }
        if code == nil {
            code = looseICAO(in: baseName)
        }
        if code == nil, let candidate = icaoCandidate(in: rootName, allowName: true) {
            code = candidate.code
            name = candidate.name
        }

        let upperBase = baseName.uppercased()
        let fileTokens = tokens(in: upperBase)
        let folderTokens = folders.flatMap { tokens(in: $0.uppercased()) }

        return ParsedChart(
            airportCode: code ?? Airport.unsortedCode,
            airportName: name,
            title: title(fileName: baseName, airportCode: code),
            category: category(fileTokens: fileTokens, folderTokens: folderTokens, rawName: upperBase),
            runway: runway(in: upperBase)
        )
    }

    // MARK: - ICAO code

    /// Matches a leading four-letter code, optionally followed by a separator and a name,
    /// e.g. "EGLL", "EGLL - London Heathrow", "EIDW_Dublin".
    static func icaoCandidate(in component: String, allowName: Bool) -> (code: String, name: String?)? {
        let characters = Array(component)
        guard characters.count >= 4 else { return nil }

        let codeCharacters = characters[0..<4]
        guard codeCharacters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let code = String(codeCharacters).uppercased()
        guard !blockedCodes.contains(code), tokenRules[code] == nil else { return nil }

        guard characters.count > 4 else { return (code, nil) }

        let separator = characters[4]
        guard !separator.isLetter, !separator.isNumber else { return nil }
        guard allowName else { return (code, nil) }

        let remainder = String(characters[5...])
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—.()[]"))
        let collapsed = remainder.split(separator: " ").joined(separator: " ")
        guard collapsed.filter({ $0.isLetter }).count >= 3 else { return (code, nil) }
        guard tokenRules[collapsed.uppercased()] == nil else { return (code, nil) }
        return (code, collapsed)
    }

    /// Falls back to any four-letter word inside the file name, e.g. "CHART EDDM AGC.png".
    static func looseICAO(in baseName: String) -> String? {
        for token in tokens(in: baseName.uppercased()) where token.count == 4 {
            guard token.allSatisfy({ $0.isLetter }) else { continue }
            guard !blockedCodes.contains(token), tokenRules[token] == nil else { continue }
            return token
        }
        return nil
    }

    // MARK: - Category

    static func category(fileTokens: [String], folderTokens: [String], rawName: String) -> ChartCategory {
        var scores: [ChartCategory: Int] = [:]

        for token in fileTokens {
            if let rule = tokenRules[token] {
                scores[rule.category, default: 0] += rule.weight
            }
        }
        for token in folderTokens {
            if let rule = tokenRules[token] {
                scores[rule.category, default: 0] += max(1, rule.weight - folderPenalty)
            }
        }
        if scores.isEmpty {
            for rule in substringRules where rawName.contains(rule.token) {
                scores[rule.category, default: 0] += substringWeight
            }
        }

        var best: ChartCategory?
        var bestScore = 0
        for category in tieBreakOrder {
            let score = scores[category] ?? 0
            if score > bestScore {
                bestScore = score
                best = category
            }
        }
        return best ?? .reference
    }

    // MARK: - Runway

    private static let runwayExpressions: [NSRegularExpression] = {
        let patterns = [
            "(?:RWY|RUNWAY|RW)[ _.\\-]?([0-3][0-9])([LCR])?",
            "(?<![A-Z0-9])([0-3][0-9])([LCR])(?![A-Z0-9])",
            // A bare number with no side letter and no "RWY" in front of it, which is how
            // planner downloads are named: "LOC 25", "ILS OR LOC 01L", "SID 28". It has to be
            // the last thing in the name, because a two-digit number loose in a chart name is
            // usually not a runway — "AGC 24 JUL 2025" and "APC 2 OF 3" would both read as
            // one. Anchoring costs "LOC 25 DME" and keeps the dates out, which is the right
            // way round: a runway this misses is only a chart that fails to sort beside its
            // fellows, while one it invents is a chart filed under a runway it has nothing to
            // do with.
            "(?:ILS|LOC|LLZ|RNAV|RNP|GLS|GBAS|VOR|NDB|IGS|LDA|MLS|TACAN|IAC|VAC|MVC|SID|STAR|EOSID|APPROACH|APCH)"
                + "(?:[ _.\\-]+(?:OR|AND|GPS|\\(GPS\\)|RWY|RUNWAY|CAT|Z|Y|X|W|V|U|I{1,3}))*"
                + "[ _.\\-]+(?<![0-9])([0-3]?[0-9])([LCR])?$"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    static func runway(in rawUppercased: String) -> String? {
        let fullRange = NSRange(rawUppercased.startIndex..<rawUppercased.endIndex, in: rawUppercased)
        for expression in runwayExpressions {
            guard let match = expression.firstMatch(in: rawUppercased, options: [], range: fullRange),
                  match.numberOfRanges >= 2,
                  let numberRange = Range(match.range(at: 1), in: rawUppercased),
                  let value = Int(rawUppercased[numberRange]),
                  value >= 1, value <= 36 else { continue }

            var result = String(format: "%02d", value)
            if match.numberOfRanges >= 3, let sideRange = Range(match.range(at: 2), in: rawUppercased) {
                result += String(rawUppercased[sideRange])
            }
            return result
        }
        return nil
    }

    // MARK: - Title

    static func title(fileName: String, airportCode: String?) -> String {
        var name = fileName.replacingOccurrences(of: "_", with: " ")
        name = name.split(separator: " ").joined(separator: " ")

        if let code = airportCode, name.uppercased().hasPrefix(code) {
            let remainder = String(name.dropFirst(code.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—_.:"))
            if !remainder.isEmpty { name = remainder }
        }
        for prefix in ["LIDO ", "Lido ", "lido "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fileName : trimmed
    }

    // MARK: - Tokenising

    /// Splits on punctuation, then splits letter/digit runs apart so "ILS25L" also yields "ILS".
    static func tokens(in uppercased: String) -> [String] {
        let rawTokens = uppercased
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var result: [String] = []
        for token in rawTokens {
            result.append(token)
            let parts = splitLettersAndDigits(token)
            if parts.count > 1 { result.append(contentsOf: parts) }
        }
        return result
    }

    private static func splitLettersAndDigits(_ token: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var currentIsDigit: Bool?

        for character in token {
            let isDigit = character.isNumber
            if let previous = currentIsDigit, previous != isDigit {
                if !current.isEmpty { parts.append(current) }
                current = String(character)
            } else {
                current.append(character)
            }
            currentIsDigit = isDigit
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
