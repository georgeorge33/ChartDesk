// DEPRECATED — scheduled for removal in 1.0.
//
// Taxi routing did not work well enough in practice to keep: the drag-to-align calibration is
// fiddly and the drawn routes are not dependable enough to read a clearance from. It still
// ships and still works, so existing calibrations and drawn routes are left alone, but nothing
// new should be built on it and it is no longer maintained.

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

    /// Two ways to line a chart up. Clicking crossings is precise and can report how far
    /// out it is; dragging the whole overlay is quicker and lets you judge the whole airfield
    /// at once instead of four points.
    enum CalibrationMethod: String, CaseIterable, Identifiable {
        case align
        case crossings

        var id: String { rawValue }
        var title: String { self == .align ? "Drag to align" : "Click crossings" }
    }

    @Published var calibrationMethod: CalibrationMethod = .align
    @Published var calibrationTarget: TaxiIntersection?
    @Published private(set) var pendingAnchors: [GeoAnchor] = []
    @Published private(set) var calibrationNote: String?
    /// The fit as it stands. Kept separate from the saved one so the overlay can snap into
    /// place after the second point and be judged before anything is committed.
    @Published private(set) var draftFit: ChartGeoreference?

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
        guard let graph = graph else { return [] }
        guard let geo = draftFit ?? georeference(for: chartID) else { return [] }
        return graph.allPolylines.map { $0.map(geo.chartPoint) }
    }

    /// Where each placed point landed, so they can be marked on the plate while calibrating.
    func calibrationMarks() -> [CGPoint] {
        pendingAnchors.map(\.chart)
    }

    // MARK: - Calibration

    func beginCalibration(chartID: String? = nil, aspect: Double = 1) {
        guard let graph = graph else { return }
        pendingAnchors = []
        draftFit = nil
        calibrationNote = nil
        calibrationTarget = graph.suggestedIntersection(avoiding: [])
        isCalibrating = true
        if calibrationMethod == .align {
            seedAlignment(chartID: chartID, aspect: aspect)
        }
    }

    /// Switching method mid-calibration throws away what the other one had started, because
    /// half a set of clicked points means nothing to a dragged overlay and vice versa.
    func useMethod(_ method: CalibrationMethod, chartID: String?, aspect: Double) {
        guard method != calibrationMethod else { return }
        calibrationMethod = method
        pendingAnchors = []
        draftFit = nil
        calibrationNote = nil
        if method == .align { seedAlignment(chartID: chartID, aspect: aspect) }
    }

    /// Recalibrating starts from wherever the chart already sits, so a small correction stays
    /// a small correction. A fresh chart starts north-up and centred: wrong, but obviously so.
    private func seedAlignment(chartID: String?, aspect: Double) {
        guard let graph = graph, let icao = airport else { return }

        if let existing = georeference(for: chartID) {
            draftFit = existing
        } else {
            let points = graph.network.nodes.compactMap { row -> Coordinate? in
                row.count == 2 ? Coordinate(latitude: row[0], longitude: row[1]) : nil
            }
            guard !points.isEmpty else { return }
            let centre = Coordinate(
                latitude: points.map(\.latitude).reduce(0, +) / Double(points.count),
                longitude: points.map(\.longitude).reduce(0, +) / Double(points.count))
            draftFit = ChartGeoreference.initialGuess(icao: icao,
                                                      centre: centre,
                                                      extentMetres: graph.extentMetres,
                                                      aspect: aspect)
        }
        calibrationNote = alignmentNote()
    }

    // MARK: Dragging the overlay

    func nudge(by delta: CGPoint) {
        guard let current = draftFit else { return }
        draftFit = current.translated(by: delta)
        calibrationNote = alignmentNote()
    }

    func turn(by radians: Double, about pivot: CGPoint) {
        guard let current = draftFit else { return }
        draftFit = current.rotated(by: radians, about: pivot)
        calibrationNote = alignmentNote()
    }

    func zoom(by factor: Double, about pivot: CGPoint) {
        guard let current = draftFit else { return }
        draftFit = current.scaled(by: factor, about: pivot)
        calibrationNote = alignmentNote()
    }

    /// A dragged overlay has no residual to report — there are no points it is trying to hit.
    /// What it can say is how big and which way round it now thinks the chart is, which is
    /// enough to catch a wildly wrong scale or a chart turned the wrong way.
    private func alignmentNote() -> String? {
        guard let fit = draftFit else { return nil }
        let bearing = fit.chartBearing
        let orientation = bearing < 1 || bearing > 359
            ? "north-up"
            : String(format: "turned %.0f° clockwise from north", bearing)
        return String(format: "%.0f m across the chart, %@.", fit.metresPerUnit, orientation)
    }

    func cancelCalibration() {
        isCalibrating = false
        pendingAnchors = []
        draftFit = nil
        calibrationNote = nil
    }

    var calibrationPrompt: String {
        if calibrationMethod == .align {
            return "Drag the overlay onto the pavement. ⌥ drag turns it, ⇧ drag resizes it."
        }
        guard let target = calibrationTarget else {
            return "This airport has no taxiway crossings that can be identified without ambiguity."
        }
        return pendingAnchors.isEmpty
            ? "Click where \(target.label) cross."
            : "Click \(target.label)."
    }

    var canCommitCalibration: Bool { draftFit != nil }

    /// Records a click. The ground position comes from the crossing's own geometry, so no
    /// coordinate is ever typed.
    func addCalibrationPoint(_ point: CGPoint, chartID: String, aspect: Double) {
        guard isCalibrating, let graph = graph, let target = calibrationTarget else { return }

        pendingAnchors.append(GeoAnchor(coordinate: target.coordinate,
                                        chart: point,
                                        label: target.label))
        refit(aspect: aspect)
        calibrationTarget = graph.suggestedIntersection(avoiding: pendingAnchors.map(\.coordinate))
    }

    func removeLastCalibrationPoint() {
        guard !pendingAnchors.isEmpty else { return }
        pendingAnchors.removeLast()
        if pendingAnchors.count < 2 { draftFit = nil }
        refit(aspect: draftFit?.aspect ?? 1)
    }

    private func refit(aspect: Double) {
        guard let graph = graph, let icao = airport, pendingAnchors.count >= 2 else {
            draftFit = nil
            calibrationNote = nil
            return
        }

        guard let fitted = ChartGeoreference.fit(icao: icao, anchors: pendingAnchors, aspect: aspect) else {
            draftFit = nil
            calibrationNote = "Those points are too close together to work out a scale."
            return
        }

        if let complaint = fitted.plausibility(coveringMetres: graph.extentMetres) {
            draftFit = nil
            calibrationNote = complaint
            return
        }

        draftFit = fitted
        calibrationNote = quality(for: fitted, extent: graph.extentMetres)
    }

    /// Two points always fit perfectly, so a residual of zero says nothing. Saying that out
    /// loud matters more than showing a reassuring number.
    private func quality(for fit: ChartGeoreference, extent: Double) -> String {
        var spread = 0.0
        for a in pendingAnchors {
            for b in pendingAnchors {
                spread = max(spread, TaxiGraph.metres(between: a.coordinate, and: b.coordinate))
            }
        }

        if spread < extent * 0.25 {
            return "Those points are close together — pick one further away so the scale is pinned down."
        }
        if pendingAnchors.count == 2 {
            return "Lined up. Two points always fit exactly, so add a third to check it."
        }
        return String(format: "Off by %.1f m on average across %d points.",
                      fit.rmsMetres, pendingAnchors.count)
    }

    func commitCalibration(chartID: String) {
        guard let fit = draftFit else { return }
        georeferences[chartID] = fit
        GeoreferenceStore.save(georeferences)
        isCalibrating = false
        pendingAnchors = []
        draftFit = nil
        calibrationNote = nil
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
