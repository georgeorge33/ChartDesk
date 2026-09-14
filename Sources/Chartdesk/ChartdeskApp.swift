import AppKit
import SwiftUI

@main
struct ChartdeskApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var library = ChartLibrary()
    @StateObject private var browser = BrowserState()
    @StateObject private var viewer = ChartViewerController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(browser)
                .environmentObject(viewer)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1340, height: 880)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            ChartdeskCommands(library: library, browser: browser, viewer: viewer)
        }

        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(browser)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
