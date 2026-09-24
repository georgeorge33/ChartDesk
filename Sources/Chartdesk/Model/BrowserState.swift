import AppKit
import Combine
import Foundation

enum CanvasBackground: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Chart Navy"
        case .light: return "Light Grey"
        case .dark: return "Dark"
        }
    }

    var color: NSColor {
        switch self {
        case .system: return Theme.canvas
        case .light: return NSColor(white: 0.92, alpha: 1)
        case .dark: return NSColor(white: 0.12, alpha: 1)
        }
    }
}

/// Everything about *what the user is looking at*, kept apart from the library itself so
/// menu commands, the sidebar and the viewer can all drive it.
final class BrowserState: ObservableObject {

    @Published var sidebarSelection: SidebarItem? = nil {
        didSet {
            guard oldValue != sidebarSelection else { return }
            if let code = sidebarSelection?.airportCode {
                UserDefaults.standard.set(code, forKey: DefaultsKey.lastAirport)
            }
        }
    }

    @Published var selectedChartID: String? = nil {
        didSet {
            guard oldValue != selectedChartID else { return }
            rotation = 0
            UserDefaults.standard.set(selectedChartID, forKey: DefaultsKey.lastChart)
        }
    }

    @Published var category: ChartCategory {
        didSet {
            guard oldValue != category else { return }
            UserDefaults.standard.set(category.rawValue, forKey: DefaultsKey.lastCategory)
        }
    }

    @Published var airportQuery: String = ""
    @Published var chartQuery: String = ""
    @Published var rotation: Int = 0

    /// An airport the map has been asked to show, from the search field. A new request each
    /// time, so that asking for the same airport again takes the map back to it.
    @Published private(set) var mapRequest: MapRequest?

    struct MapRequest: Equatable {
        let airport: String
        let serial: Int
    }

    func showOnMap(_ airport: MapAirport) {
        mapRequest = MapRequest(airport: airport.icao, serial: (mapRequest?.serial ?? 0) + 1)
    }

    @Published var canvasBackground: CanvasBackground {
        didSet { UserDefaults.standard.set(canvasBackground.rawValue, forKey: DefaultsKey.canvasBackground) }
    }

    @Published var zoomToFitOnOpen: Bool {
        didSet { UserDefaults.standard.set(zoomToFitOnOpen, forKey: DefaultsKey.zoomToFitOnOpen) }
    }

    @Published var restoreLastChart: Bool {
        didSet { UserDefaults.standard.set(restoreLastChart, forKey: DefaultsKey.restoreLastChart) }
    }

    /// Controlled airspace, drawn the way a chart draws it. Off by default: it is only wanted
    /// when you are looking at where you are flying, and it is a lot of ink.
    @Published var showsAirspace: Bool {
        didSet { UserDefaults.standard.set(showsAirspace, forKey: DefaultsKey.showsAirspace) }
    }

    /// What the map draws underneath everything else.
    @Published var baseMap: BaseMap {
        didSet { UserDefaults.standard.set(baseMap.rawValue, forKey: DefaultsKey.baseMap) }
    }

    /// Which classes of it are drawn. All of them until you say otherwise.
    @Published var airspaceSwitches: Set<AirspaceSwitch> {
        didSet {
            UserDefaults.standard.set(airspaceSwitches.map(\.rawValue).sorted().joined(separator: ","),
                                      forKey: DefaultsKey.airspaceClasses)
        }
    }

    /// State and province borders.
    @Published var showsStateBorders: Bool {
        didSet { UserDefaults.standard.set(showsStateBorders, forKey: DefaultsKey.showsStateBorders) }
    }

    /// The names of towns and cities.
    @Published var showsCityNames: Bool {
        didSet { UserDefaults.standard.set(showsCityNames, forKey: DefaultsKey.showsCityNames) }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            DefaultsKey.zoomToFitOnOpen: true,
            DefaultsKey.restoreLastChart: true,
        ])

        category = ChartCategory(rawValue: defaults.string(forKey: DefaultsKey.lastCategory) ?? "") ?? .airport
        canvasBackground = CanvasBackground(rawValue: defaults.string(forKey: DefaultsKey.canvasBackground) ?? "") ?? .system
        zoomToFitOnOpen = defaults.bool(forKey: DefaultsKey.zoomToFitOnOpen)
        restoreLastChart = defaults.bool(forKey: DefaultsKey.restoreLastChart)
        showsAirspace = defaults.bool(forKey: DefaultsKey.showsAirspace)
        // This slot has been four different maps, Drawn among them. Whichever of the gone
        // ones was chosen, Apple's map is what is in its place.
        let saved = defaults.string(forKey: DefaultsKey.baseMap) ?? ""
        baseMap = BaseMap(rawValue: saved) ?? .appleMap
        #if DEBUG
        // Straight to the map, for looking at what MapKit draws without clicking through.
        if RenderProbe.openAt != nil { sidebarSelection = .map }
        #endif
        // An absent preference means the default set; an empty one means none, which is a
        // thing you can ask for by turning all six off.
        if let saved = defaults.string(forKey: DefaultsKey.airspaceClasses) {
            airspaceSwitches = Set(saved.split(separator: ",")
                                       .compactMap { AirspaceSwitch(rawValue: String($0)) })
        } else {
            airspaceSwitches = AirspaceSwitch.byDefault
        }
        showsStateBorders = defaults.bool(forKey: DefaultsKey.showsStateBorders)
        showsCityNames = defaults.bool(forKey: DefaultsKey.showsCityNames)
    }

    /// The kinds of airspace to draw, which is what the switches come to.
    var airspaceClasses: Set<AirspaceClass> {
        Set(airspaceSwitches.flatMap(\.covers))
    }

    // MARK: - Derived

    /// Background behind the chart.
    var canvasColor: NSColor { canvasBackground.color }

    /// Changes whenever the pixels on screen must change.
    func renderKey(for chart: Chart?) -> String {
        guard let chart = chart else { return "none" }
        return "\(chart.id)|\(rotation)"
    }

    /// Changes only when the zoom should be reset (new chart, or a rotation).
    func resetKey(for chart: Chart?) -> String {
        guard let chart = chart else { return "none" }
        return "\(chart.id)|\(rotation)"
    }

    // MARK: - Actions

    func rotateRight() {
        rotation = (rotation + 90) % 360
    }

    func rotateLeft() {
        rotation = (rotation + 270) % 360
    }

    func resetRotation() {
        rotation = 0
    }

    var lastAirportCode: String? {
        UserDefaults.standard.string(forKey: DefaultsKey.lastAirport)
    }

    var lastChartID: String? {
        UserDefaults.standard.string(forKey: DefaultsKey.lastChart)
    }
}
