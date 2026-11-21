import Foundation
import SwiftUI

extension Bundle {

    /// What this copy of Chartdesk calls itself, as stamped by the release workflow.
    ///
    /// Read from one place because four surfaces show it — the sidebar's corner, the startup
    /// screen, the welcome screen and the updater's comparison — and they must agree.
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// A pre-release suffix is what makes a build a candidate rather than the release itself.
    var isCandidateBuild: Bool { appVersion.contains("-") }

    /// True for the test copy built to try a change out before it ships. It has a bundle
    /// identifier of its own, so it never shares your settings, and it says what it is where
    /// a version would go: a test copy that looks like the real thing is how a test ends up
    /// mistaken for the app you fly with.
    var isTestCopy: Bool { bundleIdentifier == "local.chartdesk.testbed" }
}

/// What the test copy shows in the corner where a version would go. Purple, so that at a
/// glance it is neither a release nor a candidate, and one view so that the sidebar and the
/// welcome screen say the same thing.
struct TestCopyBadge: View {
    var body: some View {
        Text("Test version")
            .font(.ngSmallBold)
            .foregroundStyle(Color.purple)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.16), in: Capsule(style: .continuous))
            .help("A test copy of Chartdesk \(Bundle.main.appVersion), with settings of its "
                  + "own — not the Chartdesk in your Applications folder")
    }
}
