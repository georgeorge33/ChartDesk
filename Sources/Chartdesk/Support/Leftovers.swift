import Foundation

/// What earlier versions kept in the app's support folder for features since taken out, which
/// nothing reads any more: the drawn base map's coastline — nearly four gigabytes of it — and
/// its tiles, the taxi route planner's routes, and the chart georeferencing file.
///
/// Taken away the first time the app opens without them in use, and looked for again on every
/// launch after that, which costs four checks for files that are no longer there. Only these
/// four, by name: nothing else in the folder is touched.
enum Leftovers {

    /// As earlier versions named them.
    static let names = ["coastline", "tiles", "taxi", "georeference.json"]

    /// The app's own support folder. A test copy has one of its own, and a debug build can be
    /// pointed at a scratch folder with `CHARTDESK_LEFTOVERS`, so that trying this out never
    /// touches the real one.
    static var folder: URL {
        #if DEBUG
        if let elsewhere = ProcessInfo.processInfo.environment["CHARTDESK_LEFTOVERS"] {
            return URL(fileURLWithPath: elsewhere, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent(Bundle.main.isTestCopy ? "Chartdesk Testbed" : "Chartdesk",
                                              isDirectory: true)
    }

    /// Removes whichever of them are still there. Off the main thread, as it is called: the
    /// coastline alone is a four-gigabyte file.
    static func remove() {
        let manager = FileManager.default
        let root = folder
        for name in names {
            let item = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: item.path) else { continue }
            try? manager.removeItem(at: item)
        }
    }
}
