import Combine
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
    static func datisURL(_ icao: String) -> URL? {
        URL(string: "https://datis.clowd.io/api/\(icao)")
    }

    static let vatsimFeedURL = URL(string: "https://data.vatsim.net/v3/vatsim-data.json")

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

    static func parseVatsim(_ data: Data, icao: String) -> [AtisReport] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stations = root["atis"] as? [[String: Any]] else { return [] }

        let code = icao.uppercased()
        return stations.compactMap { station in
            // Callsigns are ICAO_ATIS, or ICAO_A_ATIS / ICAO_D_ATIS where arrival and
            // departure are worked separately.
            guard let callsign = (station["callsign"] as? String)?.uppercased(),
                  callsign.hasPrefix(code + "_"), callsign.hasSuffix("_ATIS") else { return nil }

            let lines = (station["text_atis"] as? [String]) ?? []
            let text = lines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let middle = String(callsign.dropFirst(code.count + 1).dropLast(5))
            let letter = (station["atis_code"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AtisReport(id: "vatsim-\(callsign)",
                              label: [name(for: middle), letter?.isEmpty == false ? letter : nil]
                                  .compactMap { $0 }.joined(separator: " "),
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

    /// Runways the user cares about, per airport, and the local magnetic variation. Typed once
    /// and remembered, because neither changes between flights.
    @Published var runwayLists: [String: String] {
        didSet { UserDefaults.standard.set(runwayLists, forKey: DefaultsKey.weatherRunways) }
    }

    @Published var variations: [String: Double] {
        didSet { UserDefaults.standard.set(variations, forKey: DefaultsKey.weatherVariation) }
    }

    private var cache: [String: AirportWeather] = [:]
    /// The VATSIM feed covers every airport at once, so it is fetched once and shared.
    private var vatsimFeed: (data: Data, at: Date)?
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

    func setRunwayList(_ text: String, for code: String?) {
        guard let code = code?.uppercased() else { return }
        runwayLists[code] = text
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
            // Four independent requests. `async let` states that plainly; the DispatchGroup
            // and lock this replaces only implied it, and needed a mutable capture to work.
            async let metar = WeatherSource.text(from: WeatherSource.metarURL(code))
            async let taf = WeatherSource.text(from: WeatherSource.tafURL(code))
            async let datis = WeatherSource.data(from: WeatherSource.datisURL(code))

            let feed = await self?.vatsimData()

            var result = AirportWeather()
            result.metar = await metar
            result.taf = await taf
            if let datis = await datis { result.realAtis = WeatherSource.parseDatis(datis) }
            if let feed = feed { result.vatsimAtis = WeatherSource.parseVatsim(feed, icao: code) }

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

    /// The feed covers every airport at once, so it is fetched once and shared.
    private func vatsimData() async -> Data? {
        if let cached = vatsimFeed, Date().timeIntervalSince(cached.at) < Self.cacheSeconds {
            return cached.data
        }
        guard let data = await WeatherSource.data(from: WeatherSource.vatsimFeedURL) else {
            return nil
        }
        vatsimFeed = (data, Date())
        return data
    }

}
