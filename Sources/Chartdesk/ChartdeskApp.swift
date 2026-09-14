import AppKit
import SwiftUI

@main
struct ChartdeskApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var library = ChartLibrary()
    @StateObject private var browser = BrowserState()
    @StateObject private var viewer = ChartViewerController()
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(browser)
                .environmentObject(viewer)
                .environmentObject(updater)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(.dark)
                .tint(.ngAccent)
        }
        .defaultSize(width: 1340, height: 880)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            ChartdeskCommands(library: library, browser: browser, viewer: viewer, updater: updater)
        }

        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(browser)
                .environmentObject(updater)
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
