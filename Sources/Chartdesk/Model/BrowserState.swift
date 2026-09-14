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

    @Published var nightMode: Bool {
        didSet { UserDefaults.standard.set(nightMode, forKey: DefaultsKey.nightMode) }
    }

    @Published var desaturateNight: Bool {
        didSet { UserDefaults.standard.set(desaturateNight, forKey: DefaultsKey.desaturateNight) }
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

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            DefaultsKey.zoomToFitOnOpen: true,
            DefaultsKey.restoreLastChart: true,
            DefaultsKey.desaturateNight: false,
            DefaultsKey.nightMode: false
        ])

        category = ChartCategory(rawValue: defaults.string(forKey: DefaultsKey.lastCategory) ?? "") ?? .airport
        nightMode = defaults.bool(forKey: DefaultsKey.nightMode)
        desaturateNight = defaults.bool(forKey: DefaultsKey.desaturateNight)
        canvasBackground = CanvasBackground(rawValue: defaults.string(forKey: DefaultsKey.canvasBackground) ?? "") ?? .system
        zoomToFitOnOpen = defaults.bool(forKey: DefaultsKey.zoomToFitOnOpen)
        restoreLastChart = defaults.bool(forKey: DefaultsKey.restoreLastChart)
    }

    // MARK: - Derived

    /// Background behind the chart. Night mode always darkens it, whatever the preference.
    var canvasColor: NSColor {
        nightMode ? NSColor(white: 0.08, alpha: 1) : canvasBackground.color
    }

    /// Changes whenever the pixels on screen must change.
    func renderKey(for chart: Chart?) -> String {
        guard let chart = chart else { return "none" }
        return "\(chart.id)|\(nightMode ? 1 : 0)|\(desaturateNight ? 1 : 0)|\(rotation)"
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
