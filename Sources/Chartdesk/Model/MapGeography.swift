import Foundation

/// Holds whichever levels of detail have been read, and reads the ones asked for.
///
/// The three tiers are not all wanted at once and the deepest is much the largest, so they are
/// read one at a time, off the main thread, the first time a zoom calls for one. Until the
/// wanted tier arrives the map draws the best it already has: a coast that sharpens a moment
/// after you zoom in is a map, and a coast that vanishes while a file is read is a bug.
///
/// Shared rather than owned by the view, so closing the map panel and opening it again does not
/// throw the work away.
@MainActor
final class MapGeography: ObservableObject {

    static let shared = MapGeography()

    /// Tiers already read. Published, so a tier landing redraws the map.
    @Published private(set) var tiers: [MapDetail: Geography] = [:]
    @Published private(set) var runways: [MapRunway] = []
    /// The layers the Layers button switches on, each read the first time it is wanted.
    @Published private(set) var airspace: [MapAirspace] = []
    /// Told apart from `airspace` being empty, which is also what a missing table looks like.
    @Published private(set) var readAirspace = false
    @Published private(set) var states: [MapShape] = []
    @Published private(set) var cities: [MapCity] = []

    private var loading: Set<MapDetail> = []
    private var loadingRunways = false
    private var reading: Set<String> = []

    private let queue = DispatchQueue(label: "chartdesk.mapdata", qos: .userInitiated)

    /// The tier asked for if it has been read, else the closest one that has.
    ///
    /// Called from inside a draw, so it only reports what is in hand and never starts work:
    /// asking for a tier is `request`'s job, and a draw that kicked off a file read would do it
    /// again on the next frame.
    func best(for detail: MapDetail) -> Geography? {
        if let exact = tiers[detail] { return exact }
        // Coarser first: a generalised coastline in the right place beats a detailed one
        // drawn for a different zoom, and beats an empty sheet either way.
        for fallback in MapDetail.allCases.reversed() where fallback < detail {
            if let ready = tiers[fallback] { return ready }
        }
        for fallback in MapDetail.allCases.reversed() where fallback > detail {
            if let ready = tiers[fallback] { return ready }
        }
        return nil
    }

    /// True while the map is showing something other than what the zoom calls for.
    func isCatchingUp(to detail: MapDetail) -> Bool { tiers[detail] == nil }

    /// Reads a tier, unless it is already in hand or on its way.
    func request(_ detail: MapDetail) {
        guard tiers[detail] == nil, !loading.contains(detail) else { return }
        loading.insert(detail)
        queue.async {
            let geography = WorldData.geography(detail)
            Task { @MainActor in
                self.tiers[detail] = geography
                self.loading.remove(detail)
            }
        }
    }

    /// Reads a layer if it has not been read, off the main thread.
    ///
    /// One shape for all three because they are the same job: a table that is worth nothing
    /// until a switch is turned on, and should not be read at launch on the chance that it
    /// might be. Airspace alone is fifteen megabytes.
    func requestAirspace() {
        guard !readAirspace, !reading.contains("airspace") else { return }
        reading.insert("airspace")
        queue.async {
            let read = WorldData.loadAirspace()
            Task { @MainActor in
                // Counted as read even when it read nothing, so a missing table is not asked
                // for again on every frame. `forgetAirspace` is what notices one arriving.
                self.airspace = read
                self.readAirspace = true
                self.reading.remove("airspace")
            }
        }
    }

    /// Forgets the table, so the next ask reads it again — for one built while the app runs.
    func forgetAirspace() {
        airspace = []
        readAirspace = false
    }

    func requestStates() {
        guard states.isEmpty, !reading.contains("states") else { return }
        reading.insert("states")
        queue.async {
            let read = WorldData.loadStates()
            Task { @MainActor in
                self.states = read
                self.reading.remove("states")
            }
        }
    }

    func requestCities() {
        guard cities.isEmpty, !reading.contains("cities") else { return }
        reading.insert("cities")
        queue.async {
            let read = WorldData.loadCities()
            Task { @MainActor in
                self.cities = read
                self.reading.remove("cities")
            }
        }
    }

    func requestRunways() {
        guard runways.isEmpty, !loadingRunways else { return }
        loadingRunways = true
        queue.async {
            let runways = WorldData.loadRunways()
            Task { @MainActor in
                self.runways = runways
                self.loadingRunways = false
            }
        }
    }

    /// Reads the coarsest tier at launch, so the first frame the map ever draws has a world on
    /// it. A hundred kilobytes, off to one side, against three dropped frames later.
    func warmUp() {
        request(.coarse)
    }
}
