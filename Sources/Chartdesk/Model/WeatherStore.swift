import Combine
import CoreGraphics
import Foundation

// MARK: - Reports

struct AtisReport: Identifiable, Equatable {
    let id: String
    /// "ATIS C", "Arrival J", "Departure" — whatever the source actually distinguishes.
    let label: String
    let text: String
}

struct AirportWeather: Equatable {
    var metar: String?
    var taf: String?
    var realAtis: [AtisReport] = []
    var vatsimAtis: [AtisReport] = []
    /// Things that are absent rather than broken — no D-ATIS outside the US, no controller
    /// online — which are normal and worth saying plainly instead of leaving a blank row.
    var notes: [String] = []
    var fetchedAt = Date()

    var isEmpty: Bool {
        metar == nil && taf == nil && realAtis.isEmpty && vatsimAtis.isEmpty
    }
}

// MARK: - Sources

/// Where each report comes from.
///
/// METAR and TAF are the Aviation Weather Center's, which covers the world. VATSIM publishes a
/// METAR endpoint too, but it serves the same observation byte for byte — it mirrors real
/// weather — and has no TAF at all, so fetching it would be duplicate traffic for identical
/// text. What VATSIM uniquely has is controller ATIS, which genuinely differs: different
/// runways in use, and it only exists while someone is working the position.
enum WeatherSource {

    static let userAgent = "Chartdesk (+https://github.com/georgeorge33/ChartDesk)"

    static func metarURL(_ icao: String) -> URL? {
        URL(string: "https://aviationweather.gov/api/data/metar?ids=\(icao)&format=raw")
    }

    static func tafURL(_ icao: String) -> URL? {
        URL(string: "https://aviationweather.gov/api/data/taf?ids=\(icao)&format=raw")
    }

    /// FAA D-ATIS. US fields only; everywhere else answers 404, which is not an error.
    ///
    /// `datis.clowd.io` still works but only as a 302 to this, so asking here directly saves a
    /// round trip on every fetch.
    static func datisURL(_ icao: String) -> URL? {
        URL(string: "https://atis.info/api/\(icao)")
    }

    static let vatsimFeedURL = URL(string: "https://data.vatsim.net/v3/vatsim-data.json")

    /// Fetches and parses everything for one airport.
    ///
    /// Deliberately here rather than in the store: `WeatherSource` is isolated to no actor, so
    /// this runs on the global executor even when a `@MainActor` store awaits it, which keeps
    /// a megabyte of JSON parsing off the main thread.
    static func reports(for code: String, vatsimStations: [String: [AtisReport]]) async -> AirportWeather {
        // Three independent requests.  states that plainly; the DispatchGroup and
        // lock this replaces only implied it, and needed a mutable capture to work.
        async let metar = text(from: metarURL(code))
        async let taf = text(from: tafURL(code))
        async let datis = data(from: datisURL(code))

        var result = AirportWeather()
        result.metar = await metar
        result.taf = await taf
        if let datis = await datis { result.realAtis = parseDatis(datis) }
        result.vatsimAtis = vatsimStations[code.uppercased()] ?? []
        return result
    }

    /// Parses the feed away from whatever actor asked for it.
    static func stations(in data: Data) async -> [String: [AtisReport]] {
        parseVatsim(data)
    }

    // MARK: Parsing

    static func parseDatis(_ data: Data) -> [AtisReport] {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let text = (entry["datis"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let kind = (entry["type"] as? String) ?? "combined"
            let code = entry["code"] as? String
            return AtisReport(id: "real-\(kind)",
                              label: [name(for: kind), code].compactMap { $0 }.joined(separator: " "),
                              text: text)
        }
    }

    private static func name(for kind: String) -> String {
        switch kind.uppercased() {
        case "A", "ARR", "ARRIVAL": return "Arrival"
        case "D", "DEP", "DEPARTURE": return "Departure"
        case "", "COMBINED": return "ATIS"
        default: return kind.uppercased()
        }
    }

    /// Every VATSIM ATIS on the network, grouped by airport.
    ///
    /// The feed covers the world in one 1.4 MB document, and parsing it takes about six
    /// milliseconds. Looking up one airport used to re-parse the whole thing, so browsing five
    /// airports inside the cache window paid that cost five times over; now the parse happens
    /// once per fetch and each airport is a dictionary lookup.
    static func parseVatsim(_ data: Data) -> [String: [AtisReport]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stations = root["atis"] as? [[String: Any]] else { return [:] }

        var byAirport: [String: [AtisReport]] = [:]
        for station in stations {
            // Callsigns are ICAO_ATIS, or ICAO_A_ATIS / ICAO_D_ATIS where arrival and
            // departure are worked separately.
            guard let callsign = (station["callsign"] as? String)?.uppercased(),
                  callsign.hasSuffix("_ATIS") else { continue }
            let parts = callsign.dropLast(5).split(separator: "_", omittingEmptySubsequences: true)
            guard let code = parts.first, code.count == 4 else { continue }

            let lines = (station["text_atis"] as? [String]) ?? []
            let text = lines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let middle = parts.count > 1 ? String(parts[1]) : ""
            let letter = (station["atis_code"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let report = AtisReport(id: "vatsim-\(callsign)",
                                    label: [name(for: middle),
                                            letter?.isEmpty == false ? letter : nil]
                                        .compactMap { $0 }.joined(separator: " "),
                                    text: text)
            byAirport[String(code), default: []].append(report)
        }
        return byAirport
    }

    // MARK: Fetching

    static func data(from url: URL?) async -> Data? {
        guard let url = url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try? await URLSession.shared.data(for: request).0
    }

    static func text(from url: URL?) async -> String? {
        guard let data = await data(from: url) else { return nil }
        return rawText(data)
    }

    /// Raw endpoints answer with an error sentence rather than a status code often enough to
    /// be worth checking for.
    static func rawText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("<") || lowered.contains("no results") || lowered.contains("error") {
            return nil
        }
        return text
    }
}

// MARK: - Store

/// Fetches and caches weather for whichever airport is on screen.
///
/// Nothing is requested while the panel is collapsed, so closing it genuinely stops the
/// traffic rather than just hiding it.
@MainActor
final class WeatherStore: ObservableObject {

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.weatherEnabled)
            if isEnabled { fetchIfStale(icao) }
        }
    }

    @Published var isExpanded: Bool {
        didSet {
            UserDefaults.standard.set(isExpanded, forKey: DefaultsKey.weatherExpanded)
            if isExpanded, isEnabled { fetchIfStale(icao) }
        }
    }

    /// The airport the chart list is showing.
    @Published private(set) var icao: String?
    /// The airport the Weather window is looking at, which need not be the same one.
    @Published private(set) var lookupICAO: String?
    @Published private(set) var isFetching = false
    @Published private(set) var problem: String?

    /// Runways typed per airport while this was a text field. Only ever read now — the menu
    /// takes its choices from the charts you hold — but kept so an airport set up by hand
    /// before the change keeps its list.
    @Published private(set) var runwayLists: [String: String]

    @Published var variations: [String: Double] {
        didSet { UserDefaults.standard.set(variations, forKey: DefaultsKey.weatherVariation) }
    }

    /// How tall the panel is allowed to get, dragged by its top edge. A cap rather than a fixed
    /// height: with a short report there is nothing to reveal, so the panel still sizes to its
    /// content and the chart list keeps the space.
    @Published var panelHeight: CGFloat

    private var cache: [String: AirportWeather] = [:]
    /// The VATSIM feed covers every airport at once, so it is fetched *and parsed* once and
    /// shared. Keeping the raw bytes meant re-parsing a megabyte for every airport looked at.
    private var vatsimFeed: (stations: [String: [AtisReport]], at: Date)?
    private var generation = 0

    /// METAR is issued hourly and VATSIM asks for no more than one poll every fifteen
    /// seconds; a minute is comfortably inside both and keeps a click on Refresh meaningful.
    private static let cacheSeconds: TimeInterval = 60

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.weatherEnabled: true,
                                     DefaultsKey.weatherExpanded: true])
        isEnabled = defaults.bool(forKey: DefaultsKey.weatherEnabled)
        isExpanded = defaults.bool(forKey: DefaultsKey.weatherExpanded)
        runwayLists = defaults.dictionary(forKey: DefaultsKey.weatherRunways) as? [String: String] ?? [:]
        variations = defaults.dictionary(forKey: DefaultsKey.weatherVariation) as? [String: Double] ?? [:]
        let saved = defaults.double(forKey: DefaultsKey.weatherHeight)
        panelHeight = saved > 0 ? CGFloat(saved) : WeatherStore.defaultPanelHeight
    }

    static let defaultPanelHeight: CGFloat = 380
    static let panelHeightRange: ClosedRange<CGFloat> = 140...900

    /// Written once the drag ends rather than on every frame of it.
    func savePanelHeight() {
        UserDefaults.standard.set(Double(panelHeight), forKey: DefaultsKey.weatherHeight)
    }

    func weather(for code: String?) -> AirportWeather? {
        guard let code = code else { return nil }
        return cache[code.uppercased()]
    }

    var weather: AirportWeather? { weather(for: icao) }

    func age(for code: String?) -> String? {
        guard let fetched = weather(for: code)?.fetchedAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(fetched) / 60)
        return minutes < 1 ? "just now" : "\(minutes)m ago"
    }

    var age: String? { age(for: icao) }

    // MARK: Runways and variation

    func runwayList(for code: String?) -> String {
        guard let code = code?.uppercased() else { return "" }
        return runwayLists[code] ?? ""
    }

    func variation(for code: String?) -> Double {
        guard let code = code?.uppercased() else { return 0 }
        return variations[code] ?? 0
    }

    func setVariation(_ degrees: Double, for code: String?) {
        guard let code = code?.uppercased() else { return }
        variations[code] = degrees
    }

    // MARK: Fetching

    /// Called when the chart list's airport changes. Respects the panel being collapsed.
    func show(icao newICAO: String?) {
        let code = newICAO?.uppercased()
        guard code != icao else { return }
        icao = code
        problem = nil
        guard isEnabled, isExpanded else { return }
        fetchIfStale(code)
    }

    /// Called by the Weather window, which is its own reason to fetch — the panel being
    /// collapsed says nothing about whether the window wants data.
    func lookUp(_ code: String?) {
        let wanted = code?.uppercased()
        lookupICAO = wanted
        problem = nil
        fetchIfStale(wanted)
    }

    func refresh(_ code: String? = nil) {
        guard let target = (code ?? icao)?.uppercased() else { return }
        cache[target] = nil
        vatsimFeed = nil
        fetch(target)
    }

    private func fetchIfStale(_ code: String?) {
        guard let code = code else { return }
        if let existing = cache[code],
           Date().timeIntervalSince(existing.fetchedAt) < Self.cacheSeconds { return }
        fetch(code)
    }

    private func fetch(_ code: String) {
        guard code.count == 4, code != Airport.unsortedCode,
              code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }

        generation += 1
        let token = generation
        isFetching = true
        problem = nil

        Task { [weak self] in
            // The feed is cached on the store, so fetching it has to happen here.
            let stations = await self?.vatsimStations() ?? [:]

            // Everything else happens in `WeatherSource`, which is not isolated to an actor,
            // so a non-isolated async function runs on the global executor rather than the
            // caller's. That matters: this store is `@MainActor`, and the VATSIM feed is 1.4 MB
            // of JSON that took 6 milliseconds to parse on the main thread.
            var result = await WeatherSource.reports(for: code, vatsimStations: stations)

            guard let self = self, token == self.generation else { return }
            self.isFetching = false

            if result.realAtis.isEmpty {
                result.notes.append("No D-ATIS published for \(code) — it covers US fields only.")
            }
            if result.vatsimAtis.isEmpty {
                result.notes.append("No VATSIM ATIS online at \(code).")
            }
            result.fetchedAt = Date()

            if result.isEmpty {
                self.problem = "Couldn't reach the weather services."
            }
            self.cache[code] = result
        }
    }

    /// The feed covers every airport at once, so it is fetched and parsed once and shared.
    private func vatsimStations() async -> [String: [AtisReport]] {
        if let cached = vatsimFeed, Date().timeIntervalSince(cached.at) < Self.cacheSeconds {
            return cached.stations
        }
        guard let data = await WeatherSource.data(from: WeatherSource.vatsimFeedURL) else {
            return [:]
        }
        // Off the main actor, where the six milliseconds of parsing belongs.
        let stations = await WeatherSource.stations(in: data)
        vatsimFeed = (stations, Date())
        return stations
    }

}
