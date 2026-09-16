import Foundation

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
}
