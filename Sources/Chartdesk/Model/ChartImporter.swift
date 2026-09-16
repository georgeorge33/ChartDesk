import Foundation

/// A chart sitting in the download folder, waiting to be filed.
struct WaitingChart: Identifiable, Equatable {
    let source: URL
    /// The airport it belongs to, from the folder it arrived in or the front of its name.
    let airport: String
    /// What it will be called in the library.
    let name: String

    var id: String { source.path }
    var destination: String { airport + "/" + name }
}

/// Files charts downloaded from the MSFS planner into the library.
///
/// Two shapes are recognised, being the two a download arrives as:
///
///     Downloads/KMKE/AGC.png      the airport folder the browser makes for it
///     Downloads/KMKE AGC.png      flat, from a name with the airport in front
///
/// Both land as `KMKE/AGC.png` in the library, which is how it is already laid out: a folder
/// per airport with the chart's code as the name.
///
/// The airport code has to be four **capital** letters, which is the whole of what makes a
/// file a chart here. That matters more than it looks: "four letters then a space" also
/// describes `Scan 1.png`, and a folder called `Docs` is four letters too. Anything else in
/// the download folder is left exactly where it is.
///
/// Nothing in the library is ever replaced. A chart already there is reported back and its
/// download left alone, because this is the first thing in Chartdesk that writes to the chart
/// folder at all, and adding files is a very different promise from changing them.
enum ChartImporter {

    /// The folder downloads arrive in. Overridable so the tests never go near a real one.
    static var downloadsFolder: URL {
        if let override = ProcessInfo.processInfo.environment["CHARTDESK_IMPORT_FROM"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    struct Outcome: Equatable {
        /// Destination paths, as `KMKE/AGC.png`.
        var imported: [String] = []
        /// Already in the library, or named the same as something else in the same batch.
        var kept: [String] = []
        var failed: [String] = []
        var airports: [String] = []

        var isEmpty: Bool { imported.isEmpty && kept.isEmpty && failed.isEmpty }
    }

    enum Trouble: Equatable {
        /// macOS has not been asked yet, or was asked and said no.
        case noPermission
        case unreadable
    }

    // MARK: - Looking

    /// Charts waiting in `folder`, folder-shaped ones first so a duplicate pair resolves the
    /// same way every time.
    ///
    /// `trouble` is set only when the folder is there but cannot be read, which on a fixed
    /// `~/Downloads` means macOS is withholding it until the user agrees.
    static func waiting(in folder: URL,
                        trouble: inout Trouble?) -> [WaitingChart] {
        trouble = nil
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { return [] }

        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(at: folder,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])
        } catch {
            let code = (error as NSError).code
            trouble = code == NSFileReadNoPermissionError ? .noPermission : .unreadable
            return []
        }

        var found: [WaitingChart] = []

        // An airport folder the download put a chart into.
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard isAirport(entry.lastPathComponent),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let inside = (try? manager.contentsOfDirectory(at: entry,
                                                           includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])) ?? []
            for file in inside.sorted(by: { $0.path < $1.path }) where isImage(file) {
                found.append(WaitingChart(source: file,
                                          airport: entry.lastPathComponent,
                                          name: file.lastPathComponent))
            }
        }

        // A flat file with the airport in front of the name.
        for entry in entries.sorted(by: { $0.path < $1.path }) where isImage(entry) {
            guard let split = splitAirport(from: entry.lastPathComponent) else { continue }
            found.append(WaitingChart(source: entry, airport: split.airport, name: split.name))
        }

        return found
    }

    /// Four capitals, and nothing else.
    static func isAirport(_ text: String) -> Bool {
        text.count == 4 && text.unicodeScalars.allSatisfy { $0 >= "A" && $0 <= "Z" }
    }

    private static func isImage(_ url: URL) -> Bool {
        LibraryScanner.imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// `KMKE AGC.png` → airport `KMKE`, name `AGC.png`. nil when it does not start with one.
    static func splitAirport(from filename: String) -> (airport: String, name: String)? {
        guard filename.count > 5 else { return nil }
        let airport = String(filename.prefix(4))
        guard isAirport(airport) else { return nil }
        let rest = filename.dropFirst(4)
        guard let separator = rest.first, separator == " " || separator == "_" || separator == "-"
        else { return nil }
        let name = rest.drop { $0 == " " || $0 == "_" || $0 == "-" }
        guard !name.isEmpty else { return nil }
        return (airport, String(name))
    }

    // MARK: - Moving

    @discardableResult
    static func move(_ charts: [WaitingChart], into library: URL) -> Outcome {
        let manager = FileManager.default
        var outcome = Outcome()
        var claimed = Set<String>()
        var sourceFolders = Set<URL>()

        for chart in charts {
            sourceFolders.insert(chart.source.deletingLastPathComponent())

            let folder = library.appendingPathComponent(chart.airport, isDirectory: true)
            let destination = folder.appendingPathComponent(chart.name)

            // Two downloads can name the same chart — a flat one and a foldered one beside it.
            // The first wins and the second is left where it is, rather than one silently
            // overwriting the other.
            if claimed.contains(chart.destination) || manager.fileExists(atPath: destination.path) {
                outcome.kept.append(chart.destination)
                continue
            }

            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try manager.moveItem(at: chart.source, to: destination)
                claimed.insert(chart.destination)
                outcome.imported.append(chart.destination)
                if !outcome.airports.contains(chart.airport) {
                    outcome.airports.append(chart.airport)
                }
            } catch {
                outcome.failed.append(chart.destination)
            }
        }

        // Tidy up the folders the downloads came in, and only those: an airport folder that is
        // now empty. Anything still holding a file is left alone.
        for folder in sourceFolders where isAirport(folder.lastPathComponent) {
            let left = (try? manager.contentsOfDirectory(at: folder,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
            if left.isEmpty { try? manager.removeItem(at: folder) }
        }

        return outcome
    }
}
