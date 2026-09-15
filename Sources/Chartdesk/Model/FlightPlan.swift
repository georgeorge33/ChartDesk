import Combine
import Foundation

// MARK: - Model

/// The airports a flight needs, taken from a SimBrief OFP.
///
/// Nothing here is inferred. The codes come from the flight plan you built, so the only
/// questions are whether SimBrief answered and whether your library has those airports.
struct FlightPlan: Codable, Equatable {

    struct Airfield: Codable, Equatable, Identifiable {
        enum Role: String, Codable {
            case origin, destination, alternate

            var title: String {
                switch self {
                case .origin: return "Origin"
                case .destination: return "Destination"
                case .alternate: return "Alternate"
                }
            }

            /// Spelled out rather than truncated: "Alternate" cut to four letters is ALTE.
            var badge: String {
                switch self {
                case .origin: return "ORIG"
                case .destination: return "DEST"
                case .alternate: return "ALTN"
                }
            }
        }

        var icao: String
        var name: String?
        var runway: String?
        var role: Role

        var id: String { "\(role.rawValue)-\(icao)" }
    }

    var airline: String?
    var flightNumber: String?
    var aircraft: String?
    var route: String?
    var airfields: [Airfield]
    var fetchedAt: Date

    /// "BAW117", else the city pair.
    var title: String {
        let number = [airline, flightNumber].compactMap { $0 }.joined()
        if !number.isEmpty { return number }
        return pair
    }

    var pair: String {
        let from = airfields.first { $0.role == .origin }?.icao
        let to = airfields.first { $0.role == .destination }?.icao
        return [from, to].compactMap { $0 }.joined(separator: " → ")
    }

    var subtitle: String {
        var parts: [String] = []
        if !pair.isEmpty, title != pair { parts.append(pair) }
        if let aircraft = aircraft, !aircraft.isEmpty { parts.append(aircraft) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - SimBrief

enum SimBrief {

    /// Always something fit to show the user: SimBrief's own wording where it gave any, ours
    /// where it didn't.
    struct Problem: Error, Equatable {
        let message: String
    }

    /// SimBrief takes either a Navigraph alias or the numeric account id, under different
    /// parameter names. Which one you typed is obvious from the value itself.
    static func url(for account: String) -> URL? {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }

        let parameter = trimmed.allSatisfy(\.isNumber) ? "userid" : "username"
        return URL(string: "https://www.simbrief.com/api/xml.fetcher.php?\(parameter)=\(escaped)&json=1")
    }

    /// Parsed loosely rather than through `Codable`.
    ///
    /// SimBrief returns every value as a string, and `alternate` is an object when there is
    /// one and an array when there are several — a shape `Codable` handles badly. Reading it
    /// by hand also means a field going missing costs one airport rather than the whole plan.
    static func parse(_ data: Data) -> Result<FlightPlan, Problem> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(Problem(message: "SimBrief sent something that wasn't a flight plan."))
        }

        if let fetch = root["fetch"] as? [String: Any],
           let status = fetch["status"] as? String,
           status.lowercased().hasPrefix("error") {
            // Their wording is already plain English; passing it through beats inventing ours.
            return .failure(Problem(message: status))
        }

        func field(_ container: Any?, _ key: String) -> String? {
            guard let dictionary = container as? [String: Any] else { return nil }
            guard let value = dictionary[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func airfield(_ container: Any?, role: Airfield.Role) -> FlightPlan.Airfield? {
            guard let icao = field(container, "icao_code")?.uppercased() else { return nil }
            return FlightPlan.Airfield(icao: icao,
                                       name: field(container, "name"),
                                       runway: field(container, "plan_rwy"),
                                       role: role)
        }

        typealias Airfield = FlightPlan.Airfield

        var airfields: [FlightPlan.Airfield] = []
        if let origin = airfield(root["origin"], role: .origin) { airfields.append(origin) }
        if let destination = airfield(root["destination"], role: .destination) { airfields.append(destination) }

        // One alternate comes back as an object, several as an array.
        let alternates: [Any]
        if let many = root["alternate"] as? [Any] {
            alternates = many
        } else if let one = root["alternate"] as? [String: Any] {
            alternates = [one]
        } else {
            alternates = []
        }
        for entry in alternates {
            if let field = airfield(entry, role: .alternate) { airfields.append(field) }
        }

        guard !airfields.isEmpty else {
            return .failure(Problem(message: "SimBrief answered, but there were no airports in the plan."))
        }

        let general = root["general"]
        return .success(FlightPlan(airline: field(general, "icao_airline"),
                                   flightNumber: field(general, "flight_number"),
                                   aircraft: field(root["aircraft"], "icaocode"),
                                   route: field(general, "route"),
                                   airfields: airfields,
                                   fetchedAt: Date()))
    }
}

// MARK: - Store

/// Holds the flight currently loaded, and the account it came from.
///
/// This is the one place Chartdesk opens a network connection of its own, and only when asked.
/// The last plan is kept on disk so the section still stands after a relaunch with no internet.
final class FlightPlanStore: ObservableObject {

    @Published var account: String {
        didSet { UserDefaults.standard.set(account, forKey: DefaultsKey.simbriefAccount) }
    }

    @Published var fetchOnLaunch: Bool {
        didSet { UserDefaults.standard.set(fetchOnLaunch, forKey: DefaultsKey.simbriefOnLaunch) }
    }

    /// Where clicking an airport you have no charts for takes you. `{icao}` is substituted.
    ///
    /// A template rather than a fixed address because the MSFS planner is behind a sign-in, so
    /// its deep-link path cannot be checked from outside — and because somewhere else may suit
    /// you better anyway. Clearing it turns the links off.
    @Published var lookupTemplate: String {
        didSet { UserDefaults.standard.set(lookupTemplate, forKey: DefaultsKey.airportLookup) }
    }

    static let defaultLookupTemplate = "https://planner.flightsimulator.com/airport/{icao}"

    @Published private(set) var plan: FlightPlan?
    @Published private(set) var isFetching = false
    @Published private(set) var problem: String?

    private var didFetchThisLaunch = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.airportLookup: FlightPlanStore.defaultLookupTemplate])
        account = defaults.string(forKey: DefaultsKey.simbriefAccount) ?? ""
        fetchOnLaunch = defaults.bool(forKey: DefaultsKey.simbriefOnLaunch)
        lookupTemplate = defaults.string(forKey: DefaultsKey.airportLookup)
            ?? FlightPlanStore.defaultLookupTemplate
        plan = FlightPlanStore.load()
    }

    var hasAccount: Bool {
        !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshOnLaunchIfWanted() {
        guard fetchOnLaunch, hasAccount, !didFetchThisLaunch else { return }
        didFetchThisLaunch = true
        refresh()
    }

    func refresh() {
        guard !isFetching else { return }
        guard let url = SimBrief.url(for: account) else {
            problem = "Add your SimBrief username in Settings first."
            return
        }

        isFetching = true
        problem = nil

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Chartdesk", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFetching = false

                if let error = error {
                    self.problem = "Couldn't reach SimBrief. \(error.localizedDescription)"
                    return
                }
                guard let data = data else {
                    self.problem = "SimBrief sent an empty reply."
                    return
                }

                switch SimBrief.parse(data) {
                case .failure(let why):
                    self.problem = why.message
                case .success(let plan):
                    self.plan = plan
                    self.problem = nil
                    FlightPlanStore.save(plan)
                }
            }
        }.resume()
    }

    /// The page to open for an airport that isn't in the library. nil when the template is
    /// empty or doesn't produce a usable address, in which case the row simply isn't clickable.
    func lookupURL(for icao: String) -> URL? {
        let trimmed = lookupTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let code = icao.uppercased()
        let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        let filled = trimmed.replacingOccurrences(of: "{icao}", with: escaped)
        guard let url = URL(string: filled), url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
    }

    /// The runway SimBrief planned at this airport, when it is part of the loaded flight.
    func plannedRunway(at icao: String) -> String? {
        guard let plan = plan else { return nil }
        let code = icao.uppercased()
        return plan.airfields.first { field in
            field.icao == code && !(field.runway ?? "").isEmpty
        }?.runway
    }

    func clear() {
        plan = nil
        problem = nil
        FlightPlanStore.save(nil)
    }

    // MARK: Disk

    private static var fileURL: URL? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Chartdesk", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("flight.json")
    }

    private static func load() -> FlightPlan? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FlightPlan.self, from: data)
    }

    private static func save(_ plan: FlightPlan?) {
        guard let url = fileURL else { return }
        guard let plan = plan else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
