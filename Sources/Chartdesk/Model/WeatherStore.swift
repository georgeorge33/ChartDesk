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
final class WeatherStore: ObservableObject {

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.weatherEnabled)
            if isEnabled { fetchIfStale() } 
        }
    }

    @Published var isExpanded: Bool {
        didSet {
            UserDefaults.standard.set(isExpanded, forKey: DefaultsKey.weatherExpanded)
            if isExpanded { fetchIfStale() }
        }
    }

    @Published private(set) var icao: String?
    @Published private(set) var isFetching = false
    @Published private(set) var problem: String?

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
    }

    var weather: AirportWeather? {
        guard let icao = icao else { return nil }
        return cache[icao]
    }

    var age: String? {
        guard let fetched = weather?.fetchedAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(fetched) / 60)
        return minutes < 1 ? "just now" : "\(minutes)m ago"
    }

    /// Called when the selected airport changes.
    func show(icao newICAO: String?) {
        let code = newICAO?.uppercased()
        guard code != icao else { return }
        icao = code
        problem = nil
        fetchIfStale()
    }

    func refresh() {
        guard let icao = icao else { return }
        cache[icao] = nil
        vatsimFeed = nil
        fetch(icao)
    }

    private func fetchIfStale() {
        guard isEnabled, isExpanded, let icao = icao else { return }
        if let existing = cache[icao],
           Date().timeIntervalSince(existing.fetchedAt) < Self.cacheSeconds { return }
        fetch(icao)
    }

    private func fetch(_ code: String) {
        guard isEnabled, isExpanded,
              code.count == 4, code != Airport.unsortedCode else { return }

        generation += 1
        let token = generation
        isFetching = true
        problem = nil

        var result = AirportWeather()
        let group = DispatchGroup()

        func request(_ url: URL?, _ handle: @escaping (Data) -> Void) {
            guard let url = url else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(WeatherSource.userAgent, forHTTPHeaderField: "User-Agent")
            group.enter()
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data = data { handle(data) }
                group.leave()
            }.resume()
        }

        let lock = NSLock()

        request(WeatherSource.metarURL(code)) { data in
            guard let text = WeatherSource.rawText(data) else { return }
            lock.lock(); result.metar = text; lock.unlock()
        }
        request(WeatherSource.tafURL(code)) { data in
            guard let text = WeatherSource.rawText(data) else { return }
            lock.lock(); result.taf = text; lock.unlock()
        }
        request(WeatherSource.datisURL(code)) { data in
            let reports = WeatherSource.parseDatis(data)
            lock.lock(); result.realAtis = reports; lock.unlock()
        }

        if let cached = vatsimFeed, Date().timeIntervalSince(cached.at) < Self.cacheSeconds {
            result.vatsimAtis = WeatherSource.parseVatsim(cached.data, icao: code)
        } else {
            request(WeatherSource.vatsimFeedURL) { [weak self] data in
                let reports = WeatherSource.parseVatsim(data, icao: code)
                lock.lock(); result.vatsimAtis = reports; lock.unlock()
                DispatchQueue.main.async { self?.vatsimFeed = (data, Date()) }
            }
        }

        group.notify(queue: .main) { [weak self] in
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
}
