import Foundation

struct ScanResult {
    let airports: [Airport]
    let chartsByID: [String: Chart]
    let fileCount: Int
    /// Newest file in the library, used to warn when a chart set has gone stale. A file date
    /// is a proxy for the plate's effective date — the real one is printed on the chart and
    /// would need reading off the image — but it moves when you update a set, which is what
    /// matters here.
    let newestFileDate: Date?
}

/// Walks the chart folder and builds the airport/chart tree. Pure and synchronous, so it
/// can run on a background queue; it never writes to the library folder.
enum LibraryScanner {

    /// Everything ImageIO can decode that a chart is likely to arrive as. `webp` was listed in
    /// the README but missing here, so those files were being skipped silently.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "webp"
    ]

    static func scan(root: URL, overrides: [String: ChartCategory]) -> ScanResult {
        let fileManager = FileManager.default
        let standardRoot = root.standardizedFileURL
        let rootComponents = standardRoot.pathComponents
        let rootName = standardRoot.lastPathComponent

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: standardRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return ScanResult(airports: [], chartsByID: [:], fileCount: 0, newestFileDate: nil)
        }

        var charts: [Chart] = []
        var fileCount = 0
        var newest: Date?

        for case let url as URL in enumerator {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values?.isRegularFile == false { continue }
            fileCount += 1
            if let modified = values?.contentModificationDate,
               modified > (newest ?? .distantPast) {
                newest = modified
            }

            let components = relativeComponents(of: url, rootComponents: rootComponents)
            let identifier = components.joined(separator: "/")
            var parsed = ChartNameParser.parse(fileURL: url, relativeComponents: components, rootName: rootName)
            if let override = overrides[identifier] {
                parsed.category = override
            }

            let folders = components.dropLast()
            charts.append(
                Chart(
                    id: identifier,
                    url: url,
                    fileName: url.lastPathComponent,
                    airportCode: parsed.airportCode,
                    airportName: parsed.airportName,
                    title: parsed.title,
                    folderPath: folders.isEmpty ? nil : folders.joined(separator: " / "),
                    category: parsed.category,
                    runway: parsed.runway
                )
            )
        }

        return ScanResult(
            airports: group(charts: charts),
            chartsByID: Dictionary(charts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            fileCount: fileCount,
            newestFileDate: newest
        )
    }

    // MARK: - Helpers

    private static func relativeComponents(of url: URL, rootComponents: [String]) -> [String] {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return [url.lastPathComponent]
        }
        return Array(components.dropFirst(rootComponents.count))
    }

    static func group(charts: [Chart]) -> [Airport] {
        var grouped: [String: [Chart]] = [:]
        for chart in charts {
            grouped[chart.airportCode, default: []].append(chart)
        }

        var airports: [Airport] = []
        for (code, list) in grouped {
            let name = list.compactMap { $0.airportName }.first
            airports.append(Airport(code: code, name: name, charts: sortCharts(list)))
        }

        airports.sort { lhs, rhs in
            if lhs.isUnsorted != rhs.isUnsorted { return rhs.isUnsorted }
            return lhs.code.localizedStandardCompare(rhs.code) == .orderedAscending
        }
        return airports
    }

    /// Category, then runway, then title in natural order.
    ///
    /// The keys are worked out once per chart and carried through the sort. Read inside the
    /// comparator instead, each one was recomputed on every comparison: the category order was
    /// a linear search and the runway value re-parsed the designator out of a string, both of
    /// them n log n times.
    private static func sortCharts(_ charts: [Chart]) -> [Chart] {
        var keyed: [(category: Int, runway: Int, chart: Chart)] = []
        keyed.reserveCapacity(charts.count)
        for chart in charts {
            keyed.append((category: chart.category.sortIndex,
                          runway: chart.runwaySortValue,
                          chart: chart))
        }
        keyed.sort { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            if lhs.runway != rhs.runway { return lhs.runway < rhs.runway }
            return lhs.chart.title.localizedStandardCompare(rhs.chart.title) == .orderedAscending
        }
        return keyed.map { $0.chart }
    }
}
