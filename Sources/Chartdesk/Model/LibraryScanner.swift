import Foundation

struct ScanResult {
    let airports: [Airport]
    let chartsByID: [String: Chart]
    let fileCount: Int
}

/// Walks the chart folder and builds the airport/chart tree. Pure and synchronous, so it
/// can run on a background queue; it never writes to the library folder.
enum LibraryScanner {

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic"
    ]

    static func scan(root: URL, overrides: [String: ChartCategory]) -> ScanResult {
        let fileManager = FileManager.default
        let standardRoot = root.standardizedFileURL
        let rootComponents = standardRoot.pathComponents
        let rootName = standardRoot.lastPathComponent

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: standardRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return ScanResult(airports: [], chartsByID: [:], fileCount: 0)
        }

        var charts: [Chart] = []
        var fileCount = 0

        for case let url as URL in enumerator {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == false {
                continue
            }
            fileCount += 1

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
            fileCount: fileCount
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

    private static func sortCharts(_ charts: [Chart]) -> [Chart] {
        charts.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return lhs.category.sortIndex < rhs.category.sortIndex
            }
            if lhs.runwaySortValue != rhs.runwaySortValue {
                return lhs.runwaySortValue < rhs.runwaySortValue
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
