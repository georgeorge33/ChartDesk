import Foundation

/// Where the airspace layer gets its rings from.
///
/// The FAA's own service is public domain and thorough over the United States. openAIP is a
/// community database of the same thing for the rest of the world — the TMAs, CTRs, danger
/// areas and restricted areas that a chart outside America is mostly made of, and which the
/// FAA's worldwide coverage only sketches.
///
/// A choice rather than a merge. The two disagree about the same airspace often enough —
/// different surveys, different update dates — that drawing both would put two rings a few
/// hundred metres apart round every American airport and leave you guessing which to believe.
enum AirspaceSource: String, CaseIterable, Identifiable {

    /// The FAA's Airspace feature service. Bundled with the app.
    case faa
    /// openAIP's worldwide database, fetched with your own key into Application Support.
    case openAIP

    var id: String { rawValue }

    var name: String {
        switch self {
        case .faa: return "FAA"
        case .openAIP: return "openAIP"
        }
    }

    /// What picking it gets you, in the terms that decide it: where it is any good.
    var detail: String {
        switch self {
        case .faa:
            return "Class B, C and D, with every shelf's ceiling and floor. Thorough over "
                 + "the United States, thinner elsewhere. Public domain."
        case .openAIP:
            return "Worldwide: classes A to E, plus prohibited, restricted and danger "
                 + "areas. Community-maintained, so it is as good as its last contributor."
        }
    }

    /// Shown on the map whenever this source is drawn. openAIP's licence asks for it.
    var attribution: String? {
        switch self {
        case .faa: return nil
        case .openAIP: return "© openAIP contributors"
        }
    }

    /// The licence, where there is one to name.
    var licence: String? {
        switch self {
        case .faa: return nil
        case .openAIP: return "CC BY-NC 4.0"
        }
    }

    /// True for the one whose table this app does not ship.
    var needsTableOnDisk: Bool { self == .openAIP }

    /// The file the table is read from, for the sources that keep one outside the bundle.
    var fileURL: URL? {
        switch self {
        case .faa: return nil
        case .openAIP: return OpenAIPFiles.airspace
        }
    }
}

/// Where openAIP's tables live.
///
/// Application Support rather than the app bundle, and not because of the size — it is a
/// fraction of what the full coastline is. Three reasons, in order: it takes a key to build
/// and the release runner has none; a worldwide airspace database bundled at release time is
/// stale by the next amendment cycle, and stale airspace is worse than none; and openAIP's
/// data is CC BY-NC, which is a condition worth accepting deliberately rather than inheriting
/// with a download. Fetched with your own key, it is your copy, kept as current as you keep
/// it, and the app simply draws it.
enum OpenAIPFiles {

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Chartdesk/openaip", isDirectory: true)
    }

    static var airspace: URL { directory.appendingPathComponent("airspace.txt") }
}

/// Whether openAIP's tables are on this Mac, and how old they are.
///
/// Airspace changes — a new TMA, a danger area redrawn — so a table built eighteen months ago
/// is worth saying out loud rather than drawing silently. The panel shows the date it was
/// built next to the choice.
@MainActor
final class OpenAIPStore: ObservableObject {

    static let shared = OpenAIPStore()

    @Published private(set) var isInstalled = false
    /// When the table was built, which for a fetched file is when it was written.
    @Published private(set) var built: Date?
    @Published private(set) var bytes: Int = 0

    private init() { refresh() }

    /// Looks at the disk again. Cheap — one stat — and called when the panel opens, so a
    /// table built while the app was running is noticed without a relaunch.
    func refresh() {
        let url = OpenAIPFiles.airspace
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        isInstalled = values != nil
        built = values?.contentModificationDate
        bytes = values?.fileSize ?? 0
    }

    /// "built 18 Sep · 12 MB", for under the choice.
    var summary: String? {
        guard isInstalled else { return nil }
        var parts: [String] = []
        if let built = built {
            let when = DateFormatter()
            when.dateFormat = "d MMM yyyy"
            parts.append("built \(when.string(from: built))")
        }
        if bytes > 0 {
            parts.append(bytes >= 1_048_576
                         ? "\(bytes / 1_048_576) MB" : "\(max(bytes / 1_024, 1)) KB")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
