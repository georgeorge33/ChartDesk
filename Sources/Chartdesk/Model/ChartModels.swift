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

    /// Fixed order used everywhere charts are listed.
    static let displayOrder: [ChartCategory] = [.airport, .departure, .arrival, .approach, .reference]

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

    var sortIndex: Int {
        ChartCategory.displayOrder.firstIndex(of: self) ?? 0
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

    var subtitle: String {
        if let folderPath, !folderPath.isEmpty { return folderPath }
        return fileName
    }

    var searchText: String {
        [airportCode, airportName ?? "", title, fileName, runway ?? "", category.shortName]
            .joined(separator: " ")
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

    func withCategory(_ newCategory: ChartCategory) -> Chart {
        Chart(id: id,
              url: url,
              fileName: fileName,
              airportCode: airportCode,
              airportName: airportName,
              title: title,
              folderPath: folderPath,
              category: newCategory,
              runway: runway)
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

    var id: String { code }
    var isUnsorted: Bool { code == Airport.unsortedCode }
    var displayTitle: String { isUnsorted ? "Unsorted" : code }
    var displaySubtitle: String? { isUnsorted ? "No ICAO code in filename" : name }

    func chartList(in category: ChartCategory) -> [Chart] {
        charts.filter { $0.category == category }
    }

    func count(in category: ChartCategory) -> Int {
        charts.reduce(0) { $1.category == category ? $0 + 1 : $0 }
    }

    /// First category that actually contains charts, used when an airport is selected.
    var firstPopulatedCategory: ChartCategory {
        ChartCategory.displayOrder.first { count(in: $0) > 0 } ?? .airport
    }

    var searchText: String {
        [code, name ?? ""].joined(separator: " ")
    }

    static func == (lhs: Airport, rhs: Airport) -> Bool {
        lhs.code == rhs.code && lhs.name == rhs.name && lhs.charts == rhs.charts
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(code)
    }
}

// MARK: - Sidebar selection

enum SidebarItem: Hashable {
    case pinned
    case airport(String)

    var airportCode: String? {
        if case .airport(let code) = self { return code }
        return nil
    }
}
