import Combine
import Foundation

// MARK: - Restrictions

/// An altitude restriction, in the three forms a procedure states one.
///
/// The bars are the Airbus F-PLN form, and the same one a plate uses: a rule under the figure
/// for a floor, over it for a ceiling, and both for a single altitude. They carry the meaning,
/// so a figure without them is not a restriction at all.
enum AltitudeConstraint: Equatable {
    /// Cross at this altitude. Drawn with a bar above and below.
    case at(Int)
    /// Cross at or above. A floor, drawn with a bar beneath.
    case atOrAbove(Int)
    /// Cross at or below. A ceiling, drawn with a bar above.
    case atOrBelow(Int)
    /// A block: at or below the ceiling and at or above the floor. Two figures, a bar over the
    /// upper and under the lower — a fifth of the restrictions on a SID or STAR are these.
    case between(ceiling: Int, floor: Int)

    /// The figure a single-line rendering shows. For a block that is the ceiling, which is the
    /// one you are held under.
    var feet: Int {
        switch self {
        case .at(let feet), .atOrAbove(let feet), .atOrBelow(let feet): return feet
        case .between(let ceiling, _): return ceiling
        }
    }

    var hasBarAbove: Bool {
        switch self {
        case .at, .atOrBelow, .between: return true
        case .atOrAbove: return false
        }
    }

    var hasBarBelow: Bool {
        switch self {
        case .at, .atOrAbove: return true
        case .atOrBelow: return false
        case .between: return false
        }
    }
}

// MARK: - Cycles

/// An AIRAC cycle, which is how aeronautical data is dated: 28 days, worldwide, for ever.
///
/// Derived rather than looked up. The FAA publishes `CIFP_YYMMDD.zip` named for the cycle's
/// effective date, so knowing the cadence and one real date is enough to name any cycle without
/// asking the network what exists. 3 September 2026 is a real effective date, checked against
/// the published files either side of it — 6 August and 1 October, 28 days out each way.
struct NavCycle: Equatable, Comparable {

    /// Effective date, at midnight UTC.
    let start: Date

    private static let anchor: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 3
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private static let length: TimeInterval = 28 * 24 * 60 * 60

    /// The cycle in force at a given moment.
    static func current(at moment: Date = Date()) -> NavCycle {
        let elapsed = moment.timeIntervalSince(anchor)
        let cycles = (elapsed / length).rounded(.down)
        return NavCycle(start: anchor.addingTimeInterval(cycles * length))
    }

    var next: NavCycle { NavCycle(start: start.addingTimeInterval(Self.length)) }
    var expires: Date { next.start }

    /// `260903`, as the FAA names its files.
    var stamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: start)
    }

    /// "3 Sep 2026 – 1 Oct 2026", for saying which data is loaded.
    var span: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: start) + " – " + formatter.string(from: expires)
    }

    var url: URL? {
        URL(string: "https://aeronav.faa.gov/Upload_313-d/cifp/CIFP_\(stamp).zip")
    }

    static func < (lhs: NavCycle, rhs: NavCycle) -> Bool { lhs.start < rhs.start }
}

// MARK: - Parsing

/// One altitude restriction, as a procedure states it.
struct ProcedureConstraint: Equatable {
    let airport: String
    /// `HYLND7` — what SimBrief calls the airway on a SID or STAR fix.
    let procedure: String
    /// `RW04R`, `ALL`, or an enroute transition's name. Empty when the record has none.
    let transition: String
    let fix: String
    let constraint: AltitudeConstraint
}

/// Reads the FAA's Coded Instrument Flight Procedures into altitude restrictions.
///
/// The CIFP is ARINC 424 fixed-width records, public domain, reissued every cycle. Only the
/// SID and STAR sections are read, and only the fields a restriction needs: everything else in
/// a 53 MB file is leg geometry, and drawing procedures is a different job from stating their
/// altitudes.
///
/// Field positions are from the record layout, and the four descriptors below are the only ones
/// that appear on a SID or STAR — counted across a whole cycle, not assumed:
/// `+` 9,800, blank 4,467, `B` 4,226, `-` 2,237. The glide-slope descriptors belong to
/// approaches, which this does not read.
enum CIFPParser {

    /// Where each field sits in a record, counting from zero.
    private enum Field {
        static let airport = 6..<10
        static let subsection = 12..<13
        static let procedure = 13..<19
        static let transition = 20..<25
        static let fix = 29..<34
        static let descriptor = 82..<83
        static let altitudeOne = 84..<89
        static let altitudeTwo = 89..<94
    }

    /// `04000` is four thousand feet; `FL190` is nineteen thousand.
    static func altitude(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("FL") {
            return Int(trimmed.dropFirst(2)).map { $0 * 100 }
        }
        return Int(trimmed)
    }

    /// The descriptor and its altitudes, as one of the four forms a plate draws.
    ///
    /// `B` is a block, and which of its two altitudes is the ceiling is not something to guess
    /// at: across a cycle the first is the larger in all 4,226 of them, so the first is the
    /// ceiling and the second the floor.
    static func constraint(descriptor: Character, first: Int?, second: Int?) -> AltitudeConstraint? {
        switch descriptor {
        case "+":
            return first.map { .atOrAbove($0) }
        case "-":
            return first.map { .atOrBelow($0) }
        case "B":
            guard let ceiling = first, let floor = second else {
                return first.map { .at($0) }
            }
            return .between(ceiling: max(ceiling, floor), floor: min(ceiling, floor))
        case " ":
            return first.map { .at($0) }
        default:
            // Glide-slope and step-down descriptors, which a SID or STAR does not carry.
            return nil
        }
    }

    /// Every SID and STAR restriction in a CIFP file.
    static func constraints(in text: String) -> [ProcedureConstraint] {
        var found: [ProcedureConstraint] = []
        found.reserveCapacity(24_000)

        // Split on any newline, not on "\n". The CIFP is a CRLF file, and in Swift "\r\n" is a
        // single Character — so splitting on "\n" matches nothing at all and the whole 53 MB
        // arrives as one line. It parsed zero restrictions and looked like a field-offset bug.
        for line in text.split(whereSeparator: \.isNewline) {
            // Airport records for the United States; anything shorter is not a full record.
            guard line.count >= 94, line.hasPrefix("SUSAP") else { continue }
            let characters = Array(line)

            let subsection = characters[Field.subsection]
            guard subsection.first == "D" || subsection.first == "E" else { continue }

            guard let descriptor = characters[Field.descriptor].first else { continue }
            let first = altitude(String(characters[Field.altitudeOne]))
            let second = altitude(String(characters[Field.altitudeTwo]))
            guard let constraint = constraint(descriptor: descriptor,
                                              first: first,
                                              second: second) else { continue }

            let fix = String(characters[Field.fix]).trimmingCharacters(in: .whitespaces)
            // A leg with no named fix — a climb to an altitude on a heading — has a real
            // restriction but nothing on the flight plan to hang it on.
            guard !fix.isEmpty else { continue }

            found.append(ProcedureConstraint(
                airport: String(characters[Field.airport]).trimmingCharacters(in: .whitespaces),
                procedure: String(characters[Field.procedure]).trimmingCharacters(in: .whitespaces),
                transition: String(characters[Field.transition]).trimmingCharacters(in: .whitespaces),
                fix: fix,
                constraint: constraint))
        }
        return found
    }

    // MARK: Distilled form

    /// What gets kept on disk: one restriction per line, tab separated.
    ///
    /// The cycle's own file is 53 MB of which this is a twentieth, and none of the rest says
    /// anything about an altitude.
    static func distil(_ constraints: [ProcedureConstraint]) -> String {
        var out = "# SID and STAR altitude restrictions, from the FAA CIFP (public domain).\n"
        out += "# airport\tprocedure\ttransition\tfix\tform\tfeet\tfeet2\n"
        for entry in constraints {
            let (form, first, second): (String, Int, Int)
            switch entry.constraint {
            case .at(let feet): (form, first, second) = ("AT", feet, 0)
            case .atOrAbove(let feet): (form, first, second) = ("ABOVE", feet, 0)
            case .atOrBelow(let feet): (form, first, second) = ("BELOW", feet, 0)
            case .between(let ceiling, let floor): (form, first, second) = ("BLOCK", ceiling, floor)
            }
            out += [entry.airport, entry.procedure, entry.transition, entry.fix,
                    form, String(first), String(second)].joined(separator: "\t") + "\n"
        }
        return out
    }

    static func read(distilled text: String) -> [ProcedureConstraint] {
        var found: [ProcedureConstraint] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 7,
                  let first = Int(fields[5]), let second = Int(fields[6])
            else { continue }

            let constraint: AltitudeConstraint
            switch fields[4] {
            case "AT": constraint = .at(first)
            case "ABOVE": constraint = .atOrAbove(first)
            case "BELOW": constraint = .atOrBelow(first)
            case "BLOCK": constraint = .between(ceiling: first, floor: second)
            default: continue
            }

            found.append(ProcedureConstraint(airport: String(fields[0]),
                                             procedure: String(fields[1]),
                                             transition: String(fields[2]),
                                             fix: String(fields[3]),
                                             constraint: constraint))
        }
        return found
    }

    // MARK: Lookup

    /// The restriction on a fix, given the procedure it is flown on.
    ///
    /// A fix can appear in several transitions of the same procedure with different
    /// restrictions. When the planned runway is known its transition wins; otherwise a fix is
    /// only answered for when every transition agrees, because a page that shows one of two
    /// contradictory restrictions is worse than one that shows neither.
    static func constraint(for fix: String,
                           procedure: String,
                           airport: String,
                           runway: String?,
                           in table: [String: [ProcedureConstraint]]) -> AltitudeConstraint? {
        let key = "\(airport.uppercased())/\(procedure.uppercased())/\(fix.uppercased())"
        guard let matches = table[key], !matches.isEmpty else { return nil }

        if let runway = runway?.uppercased(), !runway.isEmpty {
            // "RW04R" for runway 04R, and "RW04B" where a procedure serves both sides.
            let wanted = "RW" + runway
            if let exact = matches.first(where: { $0.transition == wanted }) {
                return exact.constraint
            }
        }

        let distinct = Set(matches.map { describe($0.constraint) })
        return distinct.count == 1 ? matches[0].constraint : nil
    }

    static func key(airport: String, procedure: String, fix: String) -> String {
        "\(airport.uppercased())/\(procedure.uppercased())/\(fix.uppercased())"
    }

    static func table(from constraints: [ProcedureConstraint]) -> [String: [ProcedureConstraint]] {
        var table: [String: [ProcedureConstraint]] = [:]
        table.reserveCapacity(constraints.count)
        for entry in constraints {
            table[key(airport: entry.airport, procedure: entry.procedure, fix: entry.fix),
                  default: []].append(entry)
        }
        return table
    }

    private static func describe(_ constraint: AltitudeConstraint) -> String {
        switch constraint {
        case .at(let feet): return "AT\(feet)"
        case .atOrAbove(let feet): return "A\(feet)"
        case .atOrBelow(let feet): return "B\(feet)"
        case .between(let ceiling, let floor): return "K\(ceiling)-\(floor)"
        }
    }
}

// MARK: - Store

/// Keeps the navigation data current, and answers what a procedure demands at a fix.
///
/// The FAA reissues the CIFP every 28 days, so "is this current" is a question with a definite
/// answer: the cycle in force is arithmetic, and the file on disk is named for the cycle it
/// came from. A mismatch is the whole check.
///
/// The 53 MB the FAA ships is distilled to the 0.7 MB that says something about an altitude,
/// and the previous cycle's file is deleted once the new one is written — stale navigation data
/// kept "just in case" is the kind of thing you fly with by accident.
@MainActor
final class NavDataStore: ObservableObject {

    /// The cycle whose file is on disk, or nil when there is none yet.
    @Published private(set) var installed: NavCycle?
    @Published private(set) var isWorking = false
    /// What happened last, for the settings pane to show.
    @Published private(set) var status: String?

    @Published var updateOnLaunch: Bool {
        didSet { UserDefaults.standard.set(updateOnLaunch, forKey: DefaultsKey.navdataOnLaunch) }
    }

    private var table: [String: [ProcedureConstraint]] = [:]
    private var didCheckThisLaunch = false

    /// True when the data on disk is the cycle in force.
    var isCurrent: Bool { installed == NavCycle.current() }

    var restrictionCount: Int { table.values.reduce(0) { $0 + $1.count } }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.navdataOnLaunch: true])
        updateOnLaunch = defaults.bool(forKey: DefaultsKey.navdataOnLaunch)
        loadFromDisk()
    }

    // MARK: Lookup

    /// What the procedure demands at this fix, if anything does.
    func constraint(for fix: String,
                    procedure: String,
                    airport: String,
                    runway: String?) -> AltitudeConstraint? {
        guard !table.isEmpty else { return nil }
        return CIFPParser.constraint(for: fix, procedure: procedure, airport: airport,
                                     runway: runway, in: table)
    }

    // MARK: Updating

    func checkOnLaunchIfWanted() {
        guard updateOnLaunch, !didCheckThisLaunch else { return }
        didCheckThisLaunch = true
        guard !isCurrent else { return }
        update()
    }

    /// Fetches the cycle in force, distils it, and removes whatever came before.
    func update() {
        guard !isWorking else { return }
        let cycle = NavCycle.current()
        guard let url = cycle.url, let folder = Self.folder else {
            status = "Nowhere to put the navigation data."
            return
        }

        isWorking = true
        status = "Fetching cycle \(cycle.stamp)…"

        Task.detached(priority: .utility) {
            let outcome = Self.fetch(cycle: cycle, from: url, into: folder)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isWorking = false
                switch outcome {
                case .success(let count):
                    self.loadFromDisk()
                    self.status = "Cycle \(cycle.stamp): \(count) restrictions, "
                        + "\(cycle.span)."
                case .failure(let message):
                    self.status = message
                }
            }
        }
    }

    // MARK: Disk

    private static var folder: URL? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory,
                                      in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Chartdesk/navdata", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private nonisolated static let prefix = "procedures-"

    private func loadFromDisk() {
        guard let folder = Self.folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                      includingPropertiesForKeys: nil)
        else { return }

        // The newest cycle on disk wins, in case an interrupted update left two.
        let stamps = files
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix(Self.prefix) && $0.hasSuffix(".txt") }
            .map { String($0.dropFirst(Self.prefix.count).dropLast(4)) }
            .sorted()

        guard let stamp = stamps.last,
              let text = try? String(contentsOf: folder.appendingPathComponent("\(Self.prefix)\(stamp).txt"),
                                     encoding: .utf8)
        else {
            installed = nil
            table = [:]
            return
        }

        table = CIFPParser.table(from: CIFPParser.read(distilled: text))
        installed = NavCycle.current(at: Self.date(from: stamp) ?? Date())
    }

    private static func date(from stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        // Noon, so a cycle's own stamp cannot land a hair before its start and read as the one
        // before it.
        return formatter.date(from: stamp)?.addingTimeInterval(12 * 60 * 60)
    }

    private enum Outcome {
        case success(Int)
        case failure(String)
    }

    /// Downloads, unpacks, distils, writes, and clears out the cycle before.
    ///
    /// Outside the main actor by declaration, not by hope: this reads nine megabytes off the
    /// network and two hundred thousand records off the disk.
    private nonisolated static func fetch(cycle: NavCycle, from url: URL, into folder: URL) -> Outcome {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appendingPathComponent("chartdesk-navdata-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: scratch) }

        do {
            try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .failure("Could not make room for the download.")
        }

        let archive = scratch.appendingPathComponent("cifp.zip")
        do {
            let data = try Data(contentsOf: url)
            // A cycle is about nine megabytes; a couple of kilobytes means an error page.
            guard data.count > 1_000_000 else {
                return .failure("Cycle \(cycle.stamp) is not published yet.")
            }
            try data.write(to: archive)
        } catch {
            return .failure("Could not download cycle \(cycle.stamp).")
        }

        let unpacked = scratch.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            return .failure("Could not unpack cycle \(cycle.stamp).")
        }

        // The records file is the big one; its name has changed spelling between cycles.
        guard let records = (try? manager.contentsOfDirectory(at: unpacked,
                                                              includingPropertiesForKeys: [.fileSizeKey]))?
            .max(by: { left, right in
                let size = { (url: URL) in
                    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
                return size(left) < size(right)
            })
        else {
            return .failure("Cycle \(cycle.stamp) had no records in it.")
        }

        // Latin-1 rather than UTF-8: the records are fixed-width bytes and a stray high byte
        // in a procedure name would otherwise fail the whole read.
        guard let text = try? String(contentsOf: records, encoding: .isoLatin1) else {
            return .failure("Could not read cycle \(cycle.stamp).")
        }

        let constraints = CIFPParser.constraints(in: text)
        guard !constraints.isEmpty else {
            return .failure("Cycle \(cycle.stamp) parsed to nothing; the format may have moved.")
        }

        let destination = folder.appendingPathComponent("\(prefix)\(cycle.stamp).txt")
        do {
            try CIFPParser.distil(constraints).write(to: destination, atomically: true,
                                                     encoding: .utf8)
        } catch {
            return .failure("Could not save cycle \(cycle.stamp).")
        }

        // Only now that the new one is written: an interrupted update should leave the old
        // cycle in place rather than nothing at all.
        if let existing = try? manager.contentsOfDirectory(at: folder,
                                                           includingPropertiesForKeys: nil) {
            for file in existing where file.lastPathComponent.hasPrefix(prefix)
                && file != destination {
                try? manager.removeItem(at: file)
            }
        }

        return .success(constraints.count)
    }
}
