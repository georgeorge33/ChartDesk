import Combine
import CoreGraphics
import Foundation

/// One step of a route as built by pressing buttons.
enum RouteToken: Hashable, Identifiable {
    case taxiway(String)
    case runway(String)

    var id: String { label }

    var label: String {
        switch self {
        case .taxiway(let name), .runway(let name): return name
        }
    }

    var isRunway: Bool {
        if case .runway = self { return true }
        return false
    }
}

/// Everything about planning a taxi route on the chart in front of you: which airport's
/// network is loaded, how this plate maps to the ground, and what you have pressed so far.
final class TaxiRouteStore: ObservableObject {

    // MARK: Mode

    @Published var isPlanning = false {
        didSet { if !isPlanning { clearRoute() } }
    }

    @Published private(set) var isCalibrating = false

    // MARK: Loaded data

    @Published private(set) var graph: TaxiGraph?
    @Published private(set) var airport: String?
    @Published private(set) var georeferences: [String: ChartGeoreference]

    /// Why there is nothing to plan with, when there is nothing to plan with.
    @Published private(set) var unavailable: String?

    // MARK: Route being built

    @Published private(set) var tokens: [RouteToken] = []
    @Published var stand: String?
    @Published private(set) var outcome: RouteOutcome?

    // MARK: Calibration in progress

    @Published var calibrationRunway: String?
    @Published private(set) var pendingAnchors: [GeoAnchor] = []
    @Published private(set) var calibrationNote: String?

    init() {
        georeferences = GeoreferenceStore.load()
    }

    // MARK: - Loading an airport

    /// Called whenever the chart on screen changes. Loading is cheap and cached by ICAO, so
    /// flipping between plates at one airport does no work.
    func prepare(icao: String?) {
        let code = icao?.uppercased()
        guard code != airport else { return }

        airport = code
        graph = nil
        unavailable = nil
        clearRoute()
        cancelCalibration()

        guard let code = code, !code.isEmpty, code != Airport.unsortedCode else {
            unavailable = "This chart has no airport code, so there is nothing to route on."
            return
        }

        guard let network = TaxiNetwork.load(icao: code) else {
            unavailable = "No taxi data for \(code) yet. Import it with:\n"
                + "python3 Tools/taxi_import.py \(code)"
            return
        }

        let built = TaxiGraph(network)
        guard !built.designators.isEmpty else {
            unavailable = "The data for \(code) has no named taxiways, so a route cannot be described."
            return
        }
        graph = built
    }

    var isReady: Bool { graph != nil }

    // MARK: - Georeference

    func georeference(for chartID: String?) -> ChartGeoreference? {
        guard let chartID = chartID else { return nil }
        return georeferences[chartID]
    }

    func isCalibrated(_ chartID: String?) -> Bool {
        georeference(for: chartID) != nil
    }

    func removeCalibration(_ chartID: String?) {
        guard let chartID = chartID else { return }
        georeferences.removeValue(forKey: chartID)
        GeoreferenceStore.save(georeferences)
    }

    // MARK: - Building a route

    var taxiways: [String] {
        tokens.compactMap { if case .taxiway(let name) = $0 { return name } else { return nil } }
    }

    var destination: String? {
        tokens.last.flatMap { $0.isRunway ? $0.label : nil }
    }

    /// Which taxiways join the one most recently pressed. The panel keeps the rest visible
    /// but dimmed — imperfect data must never make a legitimate turn unreachable.
    var connectingNext: Set<String>? {
        guard let graph = graph else { return nil }
        for token in tokens.reversed() {
            if case .taxiway(let name) = token { return graph.adjacency[name] }
        }
        return nil
    }

    func append(_ token: RouteToken) {
        // A runway ends the route, so anything after it would be ignored.
        if let last = tokens.last, last.isRunway { tokens.removeLast() }
        tokens.append(token)
        recompute()
    }

    func removeLast() {
        guard !tokens.isEmpty else { return }
        tokens.removeLast()
        recompute()
    }

    func clearRoute() {
        tokens = []
        stand = nil
        outcome = nil
    }

    func setStand(_ name: String?) {
        stand = name
        recompute()
    }

    private func recompute() {
        guard let graph = graph, !tokens.isEmpty else { outcome = nil; return }
        outcome = graph.route(taxiways: taxiways, destination: destination, stand: stand)
    }

    var route: TaxiRoute? {
        if case .route(let route) = outcome { return route }
        return nil
    }

    var failure: String? {
        if case .failure(let why) = outcome { return why }
        return nil
    }

    // MARK: - Projecting onto the plate

    /// The route as normalised points on the unrotated plate, ready to draw. Empty when this
    /// chart has not been calibrated — there is no way to know where anything goes.
    func polylines(for chartID: String?) -> [[CGPoint]] {
        guard let route = route, let geo = georeference(for: chartID) else { return [] }
        var lines = route.legs.map { $0.coordinates.map(geo.chartPoint) }
        if let leadIn = route.approximateLeadIn {
            lines.append(leadIn.map(geo.chartPoint))
        }
        return lines.filter { $0.count > 1 }
    }

    /// Every piece of pavement, faintly, so a calibration can be judged against the printing
    /// underneath it rather than trusted on a number.
    func networkPolylines(for chartID: String?) -> [[CGPoint]] {
        guard let graph = graph, let geo = georeference(for: chartID) else { return [] }
        return graph.allPolylines.map { $0.map(geo.chartPoint) }
    }

    // MARK: - Calibration

    func beginCalibration(runway: String?) {
        guard let graph = graph else { return }
        calibrationRunway = runway ?? graph.runwayNames.first
        pendingAnchors = []
        calibrationNote = nil
        isCalibrating = true
    }

    func cancelCalibration() {
        isCalibrating = false
        pendingAnchors = []
        calibrationNote = nil
    }

    var calibrationPrompt: String {
        guard let runway = calibrationRunway else { return "Pick a runway to calibrate against." }
        let ends = TaxiRouteStore.ends(of: runway)
        switch pendingAnchors.count {
        case 0: return "Click the \(ends.0) threshold on the chart."
        case 1: return "Now click the \(ends.1) threshold."
        default: return "Both ends marked."
        }
    }

    /// "4L/22R" -> ("4L", "22R"). The two ends are what the user is asked to click.
    static func ends(of runway: String) -> (String, String) {
        let parts = runway.split(separator: "/").map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (runway, "other end")
    }

    /// Records a click. The ground position comes from the runway's own geometry, so the
    /// user never types a coordinate.
    func addCalibrationPoint(_ point: CGPoint, chartID: String, aspect: Double) {
        guard isCalibrating,
              let graph = graph,
              let runway = calibrationRunway,
              let shape = graph.network.runways.first(where: { $0.ref == runway }),
              let head = shape.n.first.flatMap(graph.network.coordinate),
              let tail = shape.n.last.flatMap(graph.network.coordinate) else { return }

        let ends = TaxiRouteStore.ends(of: runway)
        let index = pendingAnchors.count
        guard index < 2 else { return }

        let anchor = GeoAnchor(coordinate: index == 0 ? head : tail,
                               chart: point,
                               label: "\(runway) \(index == 0 ? ends.0 : ends.1) threshold")
        pendingAnchors.append(anchor)

        guard pendingAnchors.count == 2 else { return }
        finishCalibration(chartID: chartID, aspect: aspect)
    }

    private func finishCalibration(chartID: String, aspect: Double) {
        guard let graph = graph, let icao = airport else { return }

        guard let fitted = ChartGeoreference.fit(icao: icao, anchors: pendingAnchors, aspect: aspect) else {
            calibrationNote = "Those two points are too close together to work out a scale. Try again."
            pendingAnchors = []
            return
        }

        let extent = TaxiRouteStore.extentMetres(of: graph)
        if let complaint = fitted.plausibility(coveringMetres: extent) {
            calibrationNote = complaint
            pendingAnchors = []
            return
        }

        georeferences[chartID] = fitted
        GeoreferenceStore.save(georeferences)
        isCalibrating = false
        pendingAnchors = []
        calibrationNote = nil
    }

    private static func extentMetres(of graph: TaxiGraph) -> Double {
        let points = graph.network.nodes.compactMap { row -> Coordinate? in
            row.count == 2 ? Coordinate(latitude: row[0], longitude: row[1]) : nil
        }
        guard let west = points.min(by: { $0.longitude < $1.longitude }),
              let east = points.max(by: { $0.longitude < $1.longitude }) else { return 3000 }
        return max(TaxiGraph.metres(between: west, and: east), 500)
    }

    // MARK: - Handing the route to the annotation layer

    /// Turns the planned route into ordinary marks, so it persists, exports, prints, undoes
    /// and erases exactly like something drawn by hand. Nothing downstream needs to know a
    /// route is special.
    func marks(for chartID: String?, colour: AnnotationColor, width: AnnotationWidth) -> [Annotation] {
        guard let route = route, let geo = georeference(for: chartID) else { return [] }

        var marks: [Annotation] = []
        for leg in route.legs where leg.coordinates.count > 1 {
            marks.append(Annotation(tool: .highlighter,
                                    color: colour,
                                    width: width,
                                    points: leg.coordinates.map(geo.chartPoint),
                                    text: nil))
        }
        // The lead-in is a guess at unmapped pavement, so it is drawn thinner and in the
        // plain pen rather than as part of the highlighted route.
        if let leadIn = route.approximateLeadIn, leadIn.count > 1 {
            marks.append(Annotation(tool: .pen,
                                    color: colour,
                                    width: .fine,
                                    points: leadIn.map(geo.chartPoint),
                                    text: nil))
        }
        return marks
    }

    var summary: String? {
        guard let route = route else { return nil }
        var parts = ["\(Int(route.metres.rounded())) m"]
        if !route.inferred.isEmpty {
            parts.append("also uses \(route.inferred.joined(separator: ", "))")
        }
        if route.approximateLeadIn != nil {
            parts.append("stand lead-in approximate")
        }
        return parts.joined(separator: " · ")
    }
}
