import Foundation

/// The runways an airport actually has, so the wind panel offers those rather than all
/// thirty-six.
///
/// Read from a table built by `Tools/make_runways.py` out of OurAirports' public-domain data:
/// 32,000 airports in 400 KB, designators and nothing else, because a designator is all the
/// wind maths needs — the number *is* the magnetic heading.
///
/// Your charts still count for more than this table does. A plate named `IAC ILS Z RWY 04R` is
/// proof from the set you fly, and the two are unioned rather than one winning, so a runway the
/// table has not caught up with still shows up. The table is a floor, not an authority: it
/// comes with no guarantee of accuracy, and a decommissioned runway can linger in it.
enum RunwayDatabase {

    /// Airport code to its designators, still as the one string they were stored as. Splitting
    /// 32,000 lines into arrays up front costs several megabytes to hold answers for airports
    /// you will never look at; splitting the one line you asked for costs a microsecond.
    private static let table: [String: String] = load()

    /// Optional to sit alongside `WeatherStore`'s accessors, which take the panel's code as it
    /// comes: nothing is selected when no airport is.
    static func runways(at code: String?) -> [String] {
        guard let code = code, let line = table[code.uppercased()] else { return [] }
        return line.split(separator: " ").map(String.init)
    }

    /// True when the table is missing from the bundle, which is worth telling apart from an
    /// airport that simply is not in it.
    static var isLoaded: Bool { !table.isEmpty }

    private static func load() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "runways", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return [:] }
        return parse(data)
    }

    /// One airport per line: `KJFK 04L 04R 13L 13R 22L 22R 31L 31R`.
    ///
    /// Scanned as bytes. The obvious spelling — decode the file, `split` on newlines, then
    /// split each line — allocates a string per line and per field, and this runs at launch.
    static func parse(_ data: Data) -> [String: String] {
        var table: [String: String] = [:]
        table.reserveCapacity(34_000)

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                defer { start = end + 1 }

                // Comments carry the provenance, and an empty line carries nothing.
                guard end > start, bytes[start] != 0x23 else { continue }

                var space = start
                while space < end, bytes[space] != 0x20 { space += 1 }
                guard space < end else { continue }

                let code = String(decoding: bytes[start..<space], as: UTF8.self)
                table[code] = String(decoding: bytes[(space + 1)..<end], as: UTF8.self)
            }
        }
        return table
    }
}
