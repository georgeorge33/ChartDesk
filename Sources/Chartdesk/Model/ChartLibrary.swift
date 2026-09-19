import AppKit
import Combine
import Foundation

// MARK: - Defaults keys

enum DefaultsKey {
    static let libraryBookmark = "libraryBookmark"
    static let pinnedCharts = "pinnedCharts"
    static let recentAirports = "recentAirports"
    static let lastAirport = "lastAirport"
    static let lastChart = "lastChart"
    static let lastCategory = "lastCategory"
    static let canvasBackground = "canvasBackground"
    static let showsAirspace = "showsAirspace"
    static let airspaceClasses = "airspaceClasses"
    static let showsStateBorders = "showsStateBorders"
    static let showsCityNames = "showsCityNames"
    static let zoomToFitOnOpen = "zoomToFitOnOpen"
    static let restoreLastChart = "restoreLastChart"
    static let checkForUpdates = "checkForUpdates"
    static let importOnLaunch = "importOnLaunch"
    static let navdataOnLaunch = "navdataOnLaunch"
    static let lastAutoUpdate = "lastAutoUpdate"
    static let showAnnotations = "showAnnotations"
    static let annotationTool = "annotationTool"
    static let annotationColor = "annotationColor"
    static let annotationWidth = "annotationWidth"
    static let simbriefAccount = "simbriefAccount"
    static let simbriefOnLaunch = "simbriefOnLaunch"
    static let airportLookup = "airportLookup"
    static let weatherEnabled = "weatherEnabled"
    static let weatherExpanded = "weatherExpanded"
    static let weatherRunways = "weatherRunways"
    static let weatherVariation = "weatherVariation"
}

// MARK: - Folder bookmark

/// Remembers the chart folder between launches. Security-scoped bookmarks are used when the
/// system allows them, with a plain bookmark as a fallback for an unsandboxed build.
enum BookmarkStore {
    static func save(_ url: URL) {
        var data = try? url.bookmarkData(options: [.withSecurityScope],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        if data == nil {
            data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        guard let data = data else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.libraryBookmark)
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.libraryBookmark) else { return nil }

        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale) {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }

        var plainIsStale = false
        if let url = try? URL(resolvingBookmarkData: data,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &plainIsStale) {
            return url
        }
        return nil
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.libraryBookmark)
    }
}

// MARK: - Category overrides

/// Manual "this chart belongs in that tab" corrections, stored next to the app's preferences.
enum OverrideStore {
    private static var fileURL: URL? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Chartdesk", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("category-overrides.json")
    }

    static func load() -> [String: ChartCategory] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: ChartCategory].self, from: data)) ?? [:]
    }

    static func save(_ overrides: [String: ChartCategory]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(overrides) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Library

final class ChartLibrary: ObservableObject {

    @Published private(set) var rootURL: URL?
    @Published private(set) var airports: [Airport] = []
    @Published private(set) var isScanning = false
    @Published private(set) var fileCount = 0
    @Published private(set) var newestChartDate: Date?
    /// Bumped after every completed scan, so views can react cheaply.
    @Published private(set) var scanID = 0
    @Published private(set) var pinnedIDs: Set<String> = []
    @Published private(set) var recentAirportCodes: [String] = []
    @Published private(set) var categoryOverrides: [String: ChartCategory] = [:]

    /// How stale a chart set has to be before it is worth saying so. A LIDO cycle is 28 days,
    /// so 60 means two cycles have passed and it is no longer a near miss.
    static let staleAfterDays = 60

    var chartAgeInDays: Int? {
        guard let newest = newestChartDate else { return nil }
        return Calendar.current.dateComponents([.day], from: newest, to: Date()).day
    }

    var chartsAreStale: Bool {
        (chartAgeInDays ?? 0) > ChartLibrary.staleAfterDays
    }

    private var chartsByID: [String: Chart] = [:]
    private var scanGeneration = 0
    private let defaults = UserDefaults.standard

    init() {
        pinnedIDs = Set(defaults.stringArray(forKey: DefaultsKey.pinnedCharts) ?? [])
        recentAirportCodes = defaults.stringArray(forKey: DefaultsKey.recentAirports) ?? []
        categoryOverrides = OverrideStore.load()

        if let url = BookmarkStore.restore() {
            rootURL = url
            rescan()
        }
    }

    // MARK: Lookups

    var hasLibrary: Bool { rootURL != nil }
    var chartCount: Int { chartsByID.count }
    var folderName: String { rootURL?.lastPathComponent ?? "No folder" }
    var folderPath: String { rootURL?.path ?? "" }

    func chart(id: String?) -> Chart? {
        guard let id = id else { return nil }
        return chartsByID[id]
    }

    func airport(code: String?) -> Airport? {
        guard let code = code else { return nil }
        return airports.first { $0.code == code }
    }

    var recentAirports: [Airport] {
        recentAirportCodes.compactMap { code in airports.first { $0.code == code } }
    }

    var pinnedCharts: [Chart] {
        pinnedIDs
            .compactMap { chartsByID[$0] }
            .sorted { lhs, rhs in
                if lhs.airportCode != rhs.airportCode {
                    return lhs.airportCode.localizedStandardCompare(rhs.airportCode) == .orderedAscending
                }
                if lhs.category != rhs.category {
                    return lhs.category.sortIndex < rhs.category.sortIndex
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    // MARK: Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your chart images."
        panel.directoryURL = rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url)
    }

    func setRoot(_ url: URL) {
        BookmarkStore.save(url)
        rootURL = url
        airports = []
        chartsByID = [:]
        fileCount = 0
        rescan()
    }

    func forgetLibrary() {
        BookmarkStore.clear()
        rootURL = nil
        airports = []
        chartsByID = [:]
        fileCount = 0
        scanID += 1
    }

    func rescan() {
        guard let root = rootURL else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let overrides = categoryOverrides
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LibraryScanner.scan(root: root, overrides: overrides)
            DispatchQueue.main.async {
                guard let self = self, generation == self.scanGeneration else { return }
                self.airports = result.airports
                self.chartsByID = result.chartsByID
                self.fileCount = result.fileCount
                self.newestChartDate = result.newestFileDate
                self.isScanning = false
                self.scanID += 1
            }
        }
    }

    // MARK: Pins

    /// Whether any plate at this airport serves a runway.
    ///
    /// What tells a planned runway apart from a covered one. Deliberately not category-aware:
    /// a departure needs a SID and an arrival an approach, but a plate covering both ends of a
    /// strip is normal and so is one plate serving a whole airport, so asking for the right
    /// *kind* of plate would warn about flights that are perfectly well served.
    func hasChart(serving runway: String, at code: String) -> Bool {
        guard !runway.isEmpty, let airport = airport(code: code) else { return false }
        return airport.charts.contains { $0.serves(runway: runway) }
    }

    func isPinned(_ chart: Chart) -> Bool {
        pinnedIDs.contains(chart.id)
    }

    func togglePin(_ chart: Chart) {
        if pinnedIDs.contains(chart.id) {
            pinnedIDs.remove(chart.id)
        } else {
            pinnedIDs.insert(chart.id)
        }
        defaults.set(Array(pinnedIDs), forKey: DefaultsKey.pinnedCharts)
    }

    func clearPins() {
        pinnedIDs = []
        defaults.set([String](), forKey: DefaultsKey.pinnedCharts)
    }

    // MARK: Category overrides

    func setCategory(_ category: ChartCategory, for chart: Chart) {
        guard chart.category != category else { return }
        categoryOverrides[chart.id] = category
        OverrideStore.save(categoryOverrides)

        chartsByID[chart.id] = chart.withCategory(category)
        airports = LibraryScanner.group(charts: Array(chartsByID.values))
    }

    func clearCategoryOverrides() {
        guard !categoryOverrides.isEmpty else { return }
        categoryOverrides = [:]
        OverrideStore.save(categoryOverrides)
        rescan()
    }

    // MARK: Recents

    func noteVisit(airportCode: String) {
        guard airportCode != Airport.unsortedCode else { return }
        var codes = recentAirportCodes.filter { $0 != airportCode }
        codes.insert(airportCode, at: 0)
        if codes.count > 6 { codes = Array(codes.prefix(6)) }
        recentAirportCodes = codes
        defaults.set(codes, forKey: DefaultsKey.recentAirports)
    }
}
