import Foundation

// MARK: - Category

/// The five groups a chart library is sorted into.
/// The short names mirror the tab strip used by Navigraph Charts (APT / DEP / ARR / APP / REF).
enum ChartCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case airport
    case departure
    case arrival
    case approach
    case reference

    var id: String { rawValue }

    /// Fixed order used everywhere charts are listed, matching the Navigraph Charts app.
    /// This is presentation only — the name parser has its own `classificationOrder`, so
    /// reordering these tabs cannot change which category a chart is filed under.
    static let displayOrder: [ChartCategory] = [.arrival, .approach, .airport, .departure, .reference]

    var shortName: String {
        switch self {
        case .airport: return "APT"
        case .departure: return "DEP"
        case .arrival: return "ARR"
        case .approach: return "APP"
        case .reference: return "REF"
        }
    }

    var displayName: String {
        switch self {
        case .airport: return "Airport"
        case .departure: return "Departure"
        case .arrival: return "Arrival"
        case .approach: return "Approach"
        case .reference: return "Reference"
        }
    }

    /// Lido chart types that usually land in this group. Shown as a hint in Settings.
    var exampleTypes: String {
        switch self {
        case .airport: return "AFC, AGC, APC, ADC, LVC, AOI"
        case .departure: return "SID, SIDPT, EOSID"
        case .arrival: return "STAR, STARPT"
        case .approach: return "IAC, VAC, MVC, ILS, RNP"
        case .reference: return "Text pages, minima, enroute"
        }
    }

    var symbolName: String {
        switch self {
        case .airport: return "map"
        case .departure: return "airplane.departure"
        case .arrival: return "airplane.arrival"
        case .approach: return "scope"
        case .reference: return "doc.text"
        }
    }

    /// Position in `displayOrder`, from a table built once.
    ///
    /// This is read from inside a sort comparator, and searching the array each time meant
    /// `firstIndex(of:)` ran thousands of times to order one airport's charts.
    private static let sortIndices: [ChartCategory: Int] = Dictionary(
        uniqueKeysWithValues: displayOrder.enumerated().map { ($0.element, $0.offset) })

    var sortIndex: Int {
        ChartCategory.sortIndices[self] ?? 0
    }
}

// MARK: - Chart

/// One chart image on disk.
struct Chart: Identifiable, Hashable {
    /// Path relative to the library root. Stable across launches, so it is used for
    /// pins, category overrides and restoring the last-viewed chart.
    let id: String
    let url: URL
    let fileName: String
    let airportCode: String
    let airportName: String?
    let title: String
    /// Relative folder the file sits in, or nil when it is at the top level.
    let folderPath: String?
    let category: ChartCategory
    let runway: String?
    /// When the file was last written, which is the only date the app has for a plate — the
    /// effective date is printed on the chart itself and would have to be read off the image.
    let modified: Date?
    /// Everything worth matching a filter against, normalised and lower-cased once.
    ///
    /// Built here rather than read as a computed property: the chart list filters on every
    /// keystroke, and assembling six strings per chart and asking Foundation for a
    /// case-insensitive search cost 2ms for two thousand charts. This with `matches(_:)` is
    /// a tenth of that.
    let searchKey: String

    init(id: String, url: URL, fileName: String, airportCode: String, airportName: String?,
         title: String, folderPath: String?, category: ChartCategory, runway: String?,
         modified: Date? = nil) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.airportCode = airportCode
        self.airportName = airportName
        self.title = title
        self.folderPath = folderPath
        self.category = category
        self.runway = runway
        self.modified = modified
        self.searchKey = SearchKey.fold([airportCode, airportName ?? "", title, fileName,
                                         runway ?? "", category.shortName]
                                            .joined(separator: " "))
    }

    var subtitle: String {
        if let folderPath, !folderPath.isEmpty { return folderPath }
        return fileName
    }

    /// Whether this chart answers to a filter. The query has to be folded the same way, which
    /// `SearchKey.fold` is for.
    func matches(foldedQuery query: String) -> Bool {
        SearchKey.contains(searchKey, query)
    }

    /// Sorts 09L before 09R before 10, and puts charts with no runway first.
    var runwaySortValue: Int {
        guard let runway = runway, runway.count >= 2 else { return -1 }
        guard let number = Int(runway.prefix(2)) else { return -1 }
        let suffix = String(runway.dropFirst(2))
        let side: Int
        switch suffix {
        case "L": side = 1
        case "C": side = 2
        case "R": side = 3
        default: side = 0
        }
        return number * 10 + side
    }

    /// Whether this plate serves a given runway.
    ///
    /// Exact where both name a side, and a match where either omits one: LIDO commonly issues
    /// a single plate for "04" covering both 04L and 04R, and a flight plan naming "04" should
    /// still surface the plate for 04R. Numbers are compared numerically so 04 and 4 agree.
    func serves(runway planned: String) -> Bool {
        guard let mine = Chart.runwayParts(runway), let theirs = Chart.runwayParts(planned) else {
            return false
        }
        guard mine.number == theirs.number else { return false }
        return mine.side == theirs.side || mine.side.isEmpty || theirs.side.isEmpty
    }

    private static func runwayParts(_ value: String?) -> (number: Int, side: String)? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).uppercased(),
              !value.isEmpty else { return nil }
        let digits = value.prefix { $0.isNumber }
        guard let number = Int(digits) else { return nil }
        return (number, String(value.dropFirst(digits.count)))
    }

    func withCategory(_ newCategory: ChartCategory) -> Chart {
        Chart(id: id,
              url: url,
              fileName: fileName,
              airportCode: airportCode,
              airportName: airportName,
              title: title,
              folderPath: folderPath,
              category: newCategory,
              runway: runway,
              modified: modified)
    }

    static func == (lhs: Chart, rhs: Chart) -> Bool {
        lhs.id == rhs.id && lhs.category == rhs.category && lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Airport

struct Airport: Identifiable, Hashable {
    /// Bucket for files where no ICAO code could be found. ZZZZ is the ICAO code
    /// reserved for "no location", so it can never collide with a real airport.
    static let unsortedCode = "ZZZZ"

    let code: String
    let name: String?
    let charts: [Chart]
    let searchKey: String

    init(code: String, name: String?, charts: [Chart]) {
        self.code = code
        self.name = name
        self.charts = charts
        self.searchKey = SearchKey.fold([code, name ?? ""].joined(separator: " "))
    }

    var id: String { code }
    var isUnsorted: Bool { code == Airport.unsortedCode }
    var displayTitle: String { isUnsorted ? "Unsorted" : code }
    var displaySubtitle: String? { isUnsorted ? "No ICAO code in filename" : name }

    func chartList(in category: ChartCategory) -> [Chart] {
        charts.filter { $0.category == category }
    }

    /// The newest plate filed here, which is as close as the app gets to "how current is this
    /// airport" without reading an effective date off the image.
    var newestChartDate: Date? {
        charts.compactMap(\.modified).max()
    }

    func count(in category: ChartCategory) -> Int {
        charts.reduce(0) { $1.category == category ? $0 + 1 : $0 }
    }

    /// First category that actually contains charts, used when an airport is selected.
    var firstPopulatedCategory: ChartCategory {
        ChartCategory.displayOrder.first { count(in: $0) > 0 } ?? .airport
    }

    func matches(foldedQuery query: String) -> Bool {
        SearchKey.contains(searchKey, query)
    }

    static func == (lhs: Airport, rhs: Airport) -> Bool {
        lhs.code == rhs.code && lhs.name == rhs.name && lhs.charts == rhs.charts
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(code)
    }
}

// MARK: - Searching

/// Case- and normalisation-insensitive substring matching, done by hand.
///
/// `localizedCaseInsensitiveContains` is the obvious spelling and it dominated the cost of
/// filtering: 1.4ms of the 2ms it took to filter two thousand charts. Folding both sides once
/// and then comparing UTF-8 bytes gives the same answers ten times faster.
///
/// Folding is NFC *and* lower-casing. The normalisation matters on macOS, where a file name
/// can hold a decomposed "u" plus a combining diaeresis while the query is typed precomposed;
/// without it those two would not match.
enum SearchKey {

    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Both sides must already be folded. An empty needle matches, which is the usual
    /// convention; every caller guards an empty query before it gets here anyway.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let hay = haystack.utf8, need = needle.utf8
        guard !need.isEmpty else { return true }
        guard need.count <= hay.count else { return false }

        var start = hay.startIndex
        let limit = hay.index(hay.endIndex, offsetBy: -need.count)
        while true {
            var here = start
            var there = need.startIndex
            var matched = true
            while there != need.endIndex {
                if hay[here] != need[there] { matched = false; break }
                here = hay.index(after: here)
                there = need.index(after: there)
            }
            if matched { return true }
            if start == limit { return false }
            start = hay.index(after: start)
        }
    }
}

// MARK: - Sidebar selection

enum SidebarItem: Hashable {
    case pinned
    /// The route map, which is not an airport and has no chart list of its own.
    case map
    case airport(String)

    var airportCode: String? {
        if case .airport(let code) = self { return code }
        return nil
    }
}
