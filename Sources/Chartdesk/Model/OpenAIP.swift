import Foundation

/// openAIP, which is where the airspace comes from.
///
/// There was a choice of two for a while: the FAA's table, which is public domain and
/// bundled, or this. The FAA's is gone. It knows the United States and sketches the rest of
/// the world — 1,579 airports, no classes A or E, and none of the prohibited, restricted and
/// danger areas that a chart outside America is mostly made of — so keeping it meant carrying
/// fifteen megabytes and a radio button to offer people the worse half of the world.
enum OpenAIP {

    /// Shown on the map whenever its airspace is drawn. The licence asks for it.
    static let attribution = "© openAIP contributors"
    static let licence = "CC BY-NC 4.0"
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
