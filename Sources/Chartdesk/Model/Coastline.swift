import Foundation

/// Where the map's coastline comes from.
///
/// The first of what the Layers button offers, and the only one so far. Natural Earth is what
/// the app has always drawn and is public domain; the two OpenStreetMap choices are finer and
/// carry an obligation with them, which is why the choice is a choice.
enum CoastlineSource: String, CaseIterable, Identifiable {

    /// Natural Earth, 1:110m through 1:10m. Public domain.
    case naturalEarth
    /// OpenStreetMap's coastline, simplified. Bundled.
    case openStreetMap
    /// OpenStreetMap's coastline in full, read a cell at a time from a table on disk.
    case openStreetMapFull

    var id: String { rawValue }

    var name: String {
        switch self {
        case .naturalEarth: return "Natural Earth"
        case .openStreetMap: return "OpenStreetMap"
        case .openStreetMapFull: return "OpenStreetMap, full detail"
        }
    }

    /// What picking it actually gets you, in the terms that matter: how close you can go
    /// before the coast turns polygonal. Measured in the same box around Boston each time.
    var detail: String {
        switch self {
        case .naturalEarth:
            return "Smooth to about 600km across. 77 points around Boston."
        case .openStreetMap:
            return "Smooth to about 100km across. 456 points around Boston."
        case .openStreetMapFull:
            return "Smooth at any zoom. 41,457 points around Boston."
        }
    }

    /// Shown on the map whenever this is drawn. ODbL asks for it, and it is not optional.
    var attribution: String? {
        switch self {
        case .naturalEarth: return nil
        case .openStreetMap, .openStreetMapFull: return "© OpenStreetMap contributors"
        }
    }

    /// The table the deepest bundled level of detail reads its land from.
    var deepestLandTable: String {
        switch self {
        case .naturalEarth: return "land-10"
        case .openStreetMap, .openStreetMapFull: return "land-osm"
        }
    }

    /// True for the one that needs a table this app does not ship.
    var needsCoastlineOnDisk: Bool { self == .openStreetMapFull }
}

/// One degree of the full coastline, west and south edges.
struct CoastlineCell: Hashable {
    let longitude: Int
    let latitude: Int
}

/// The full OpenStreetMap coastline, read a cell at a time.
///
/// 79 million points, which is neither shippable in an app nor readable in one go, so it is
/// held as one table with an index saying where each one-degree cell's rings are. The map asks
/// for the cells it is looking at; nothing else is ever read.
///
/// Not bundled, and not fetched either: built once by `Tools/make_coastline.py` from
/// OpenStreetMap's own download into Application Support. Until it is there the Layers panel
/// offers the choice greyed out and says where it comes from — which is better than a menu
/// item that silently does nothing.
@MainActor
final class CoastlineStore: ObservableObject {

    static let shared = CoastlineStore()

    /// Cells already read, by cell.
    @Published private(set) var cells: [CoastlineCell: [MapShape]] = [:]
    /// True when the table and its index are on disk.
    @Published private(set) var isReady = false

    /// Where in the table each cell's rings are: byte offset and length, in pairs.
    private var spans: [CoastlineCell: [(offset: Int, length: Int)]] = [:]
    private var table: Data?
    private var reading: Set<CoastlineCell> = []
    private var isLoading = false
    /// Cells are dropped once there are more than this, oldest first: panning a long way at
    /// full detail would otherwise hold the whole coast in memory by the end of it.
    private let keep = 400
    private var order: [CoastlineCell] = []

    private let queue = DispatchQueue(label: "chartdesk.coastline", qos: .userInitiated)

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Chartdesk/coastline", isDirectory: true)
    }

    /// Whether the table is on disk at all — a file check, cheap enough to ask at launch.
    ///
    /// Told apart from `isReady`, which means the index has actually been read. The Layers
    /// panel needs the first to know whether to offer the choice, and nothing should read
    /// fifteen megabytes of index to draw a menu.
    var isInstalled: Bool {
        let directory = Self.directory
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("coastline.txt").path)
            && FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("coastline-index.txt").path)
    }

    /// Reads the index and maps the table, off the main thread.
    ///
    /// The index is a million offsets — fifteen megabytes — so this is not something to do
    /// while a menu is opening, let alone at launch for a choice that may never be made.
    func load() {
        guard !isReady, !isLoading, isInstalled else { return }
        isLoading = true

        let directory = Self.directory
        queue.async {
            guard let index = try? Data(contentsOf:
                        directory.appendingPathComponent("coastline-index.txt"),
                                        options: [.mappedIfSafe]),
                  let mapped = try? Data(contentsOf:
                        directory.appendingPathComponent("coastline.txt"),
                                         options: [.mappedIfSafe])
            else {
                Task { @MainActor in self.isLoading = false }
                return
            }

            let spans = Self.parse(index: index)
            Task { @MainActor in
                self.spans = spans
                self.table = mapped
                self.isReady = !spans.isEmpty
                self.isLoading = false
            }
        }
    }

    /// True when this cell is accounted for: read, or known from the index to hold no coast.
    ///
    /// An ocean cell counts. The full coastline saying "nothing here" is an answer, and the
    /// bundled coast should not be drawn underneath it on the strength of a missing entry.
    func holds(_ cell: CoastlineCell) -> Bool {
        isReady && (cells[cell] != nil || spans[cell] == nil)
    }

    /// The rings of whichever of these cells have been read.
    func shapes(in wanted: [CoastlineCell]) -> [MapShape] {
        var found: [MapShape] = []
        for cell in wanted {
            if let shapes = cells[cell] { found.append(contentsOf: shapes) }
        }
        return found
    }

    /// Reads any of these cells that are not already in hand.
    func request(_ wanted: [CoastlineCell]) {
        guard isReady, let table = table else {
            load()
            return
        }

        let missing = wanted.filter { cells[$0] == nil && !reading.contains($0) && spans[$0] != nil }
        guard !missing.isEmpty else { return }
        reading.formUnion(missing)

        let ranges = missing.map { cell in (cell, spans[cell] ?? []) }
        queue.async {
            var read: [CoastlineCell: [MapShape]] = [:]
            for (cell, spans) in ranges {
                var shapes: [MapShape] = []
                for span in spans {
                    guard span.offset >= 0, span.offset + span.length <= table.count else { continue }
                    let slice = table.subdata(in: span.offset..<(span.offset + span.length))
                    shapes.append(contentsOf: WorldData.parseShapes(slice))
                }
                read[cell] = shapes
            }
            Task { @MainActor in
                for (cell, shapes) in read {
                    self.cells[cell] = shapes
                    self.order.append(cell)
                    self.reading.remove(cell)
                }
                self.forget()
            }
        }
    }

    /// Drops the cells read longest ago, once there are too many.
    private func forget() {
        while order.count > keep {
            let oldest = order.removeFirst()
            // It may have been asked for again since, in which case it is at the back too.
            if !order.contains(oldest) { cells[oldest] = nil }
        }
    }

    /// `lon lat offset length offset length …` per cell, scanned as bytes.
    ///
    /// A million integers across fifteen megabytes. Decoding that to a string and splitting it
    /// allocates a substring per field and takes the better part of a second; this takes tens
    /// of milliseconds and is the same code shape the map tables are read with.
    nonisolated private static func parse(index: Data) -> [CoastlineCell: [(offset: Int, length: Int)]] {
        var out: [CoastlineCell: [(offset: Int, length: Int)]] = [:]
        out.reserveCapacity(30_000)

        index.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                defer { start = end + 1 }
                guard end > start, bytes[start] != 0x23 else { continue }

                var at = start
                guard let longitude = whole(bytes, &at, end),
                      let latitude = whole(bytes, &at, end)
                else { continue }

                var spans: [(offset: Int, length: Int)] = []
                while let offset = whole(bytes, &at, end), let length = whole(bytes, &at, end) {
                    spans.append((offset, length))
                }
                out[CoastlineCell(longitude: longitude, latitude: latitude)] = spans
            }
        }
        return out
    }

    /// One integer, possibly negative, straight out of the bytes.
    @inline(__always)
    nonisolated private static func whole(_ bytes: UnsafeBufferPointer<UInt8>,
                                          _ index: inout Int, _ end: Int) -> Int? {
        while index < end, bytes[index] == 0x20 { index += 1 }
        guard index < end else { return nil }

        var negative = false
        if bytes[index] == 0x2D {
            negative = true
            index += 1
        }
        var value = 0
        var sawDigit = false
        while index < end, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            value = value * 10 + Int(bytes[index] - 0x30)
            index += 1
            sawDigit = true
        }
        guard sawDigit else { return nil }
        return negative ? -value : value
    }
}
