import AppKit
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

/// The version where it is shown, pressed to check for an update: the same check as
/// Chartdesk ▸ Check for Updates…, from where you are already looking at which version this
/// is. It always says something back — that this is the newest, or what is newer and whether
/// to install it — and a spinner beside it says it is asking.
///
/// Never round the test copy's badge: an update installs into Applications, so a test copy
/// that updated itself would replace the app you fly with.
struct ChecksForUpdates<Label: View>: View {
    @EnvironmentObject private var updater: UpdateController
    @State private var hovering = false
    private let tip: String
    private let label: Label

    init(tip: String, @ViewBuilder label: () -> Label) {
        self.tip = tip
        self.label = label()
    }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                // Not disabled while it works — the check ignores a second press itself — so
                // the pointer is always handed back when it leaves.
                updater.check(manual: true)
            } label: {
                label.brightness(hovering && !updater.isWorking ? 0.25 : 0)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(updater.isWorking ? "Checking for updates…" : tip + " Click to check for updates.")

            if updater.isWorking {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }
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
