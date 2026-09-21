import AppKit
import SwiftUI

@main
struct ChartdeskApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var library = ChartLibrary()
    @StateObject private var browser = BrowserState()
    @StateObject private var viewer = ChartViewerController()
    @StateObject private var updater = UpdateController()
    @StateObject private var annotations = AnnotationStore()
    @StateObject private var flight = FlightPlanStore()
    @StateObject private var weather = WeatherStore()
    @StateObject private var importer = ImportController()
    @StateObject private var navdata = NavDataStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(browser)
                .environmentObject(viewer)
                .environmentObject(updater)
                .environmentObject(annotations)
                .environmentObject(flight)
                .environmentObject(weather)
                .environmentObject(importer)
                .environmentObject(navdata)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(.dark)
                .tint(.ngAccent)
        }
        .defaultSize(width: 1340, height: 880)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            ChartdeskCommands(library: library,
                              browser: browser,
                              viewer: viewer,
                              updater: updater,
                              marks: annotations,
                              flight: flight,
                              weather: weather,
                              importer: importer)
        }

        Window("Performance", id: "performance") {
            PerformanceView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(.ngAccent)
        }
        .defaultSize(width: 400, height: 700)
        .commandsRemoved()

        Window("Airport Layouts", id: "airportLayouts") {
            AirportLayoutsView()
                .preferredColorScheme(.dark)
                .tint(.ngAccent)
        }
        .defaultSize(width: 860, height: 560)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(browser)
                .environmentObject(updater)
                .environmentObject(annotations)
                .environmentObject(flight)
                .environmentObject(weather)
                .environmentObject(importer)
                .environmentObject(navdata)
                .preferredColorScheme(.dark)
                .tint(.ngAccent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The app is always dark, whatever the system is set to. This one line carries every
    /// AppKit-backed surface with it: toolbar, search fields, scrollers, menus, the
    /// segmented control and grouped form backgrounds.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        fitWindowsToScreen()
    }

    /// Pulls any window that has been restored bigger than the screen back onto it.
    ///
    /// macOS remembers a window's frame against the screen it was last on, and hands it
    /// back whether or not it still fits. This app's window is usually the full height of
    /// the usable area — 949 points on this Mac — so anything that takes a little of that
    /// away is enough: the Dock coming out of hiding, a display with a different notch, a
    /// second monitor that has gone. The window comes back the height it was, the bottom
    /// stays put, and the title bar ends up above the top of the screen where it cannot be
    /// dragged back down.
    ///
    /// Run once at launch and again whenever the screens change, which is when it happens.
    private func fitWindowsToScreen() {
        fit()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            }
    }

    private func fit() {
        // After the windows exist: at launch this runs before SwiftUI has made them.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { continue }
                var frame = window.frame
                guard !visible.contains(frame) else { continue }

                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
                guard frame != window.frame else { continue }
                window.setFrame(frame, display: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
