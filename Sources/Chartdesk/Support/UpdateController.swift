import AppKit
import Combine
import Foundation

/// Checks GitHub for a newer release of Chartdesk and swaps this bundle for it.
///
/// The repository is private, so release assets cannot be fetched anonymously and there is no
/// token this app could reasonably carry. Every call therefore goes through the `gh` CLI, which
/// already holds the user's credentials in the keyring — the same dependency `update.sh` has.
/// When `gh` is missing or signed out the updater stays quiet instead of nagging.
final class UpdateController: ObservableObject {

    struct ReleaseInfo: Equatable {
        let tag: String
        let version: String
    }

    private static let appName = "Chartdesk"
    private static let destination = "/Applications/\(appName).app"

    @Published var available: ReleaseInfo?
    @Published var showAvailable = false
    @Published var isWorking = false
    @Published var message: String?
    @Published var showMessage = false

    @Published var checkOnLaunch: Bool {
        didSet { UserDefaults.standard.set(checkOnLaunch, forKey: DefaultsKey.checkForUpdates) }
    }

    private var didCheckThisLaunch = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.checkForUpdates: true])
        checkOnLaunch = defaults.bool(forKey: DefaultsKey.checkForUpdates)
    }

    // MARK: - Environment

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var repository: String? {
        Bundle.main.infoDictionary?["CDUpdateRepository"] as? String
    }

    /// A GUI app inherits a bare PATH, so Homebrew's `gh` has to be found by hand.
    private static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Checking

    /// Called once per launch, and only when the preference is on.
    func checkOnLaunchIfWanted() {
        guard checkOnLaunch, !didCheckThisLaunch else { return }
        didCheckThisLaunch = true
        check(manual: false)
    }

    /// An automatic check stays silent unless there is genuinely something to install; a manual
    /// one always says something, otherwise the menu item looks broken.
    func check(manual: Bool) {
        guard !isWorking else { return }

        guard let repo = repository, let gh = Self.ghPath else {
            if manual {
                report("Updating needs the GitHub CLI, because the repository is private. Install it with: brew install gh")
            }
            return
        }

        isWorking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = Self.latestRelease(gh: gh, repo: repo)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isWorking = false

                switch outcome {
                case .failure(let text):
                    if manual { self.report(text) }

                case .none:
                    if manual { self.report("No releases have been published yet.") }

                case .success(let info):
                    if Self.isNewer(info.version, than: self.currentVersion) {
                        self.available = info
                        self.showAvailable = true
                    } else if manual {
                        self.report("Chartdesk \(self.currentVersion) is the newest version.")
                    }
                }
            }
        }
    }

    func dismissAvailable() {
        showAvailable = false
        available = nil
    }

    // MARK: - Installing

    func installAvailable() {
        guard let info = available, let gh = Self.ghPath, let repo = repository else { return }

        // Checked before quitting, so a permissions problem surfaces in the app rather than
        // leaving the user with nothing installed.
        guard FileManager.default.isWritableFile(atPath: "/Applications") else {
            showAvailable = false
            report("/Applications is not writable, so the update cannot be installed there.")
            return
        }

        showAvailable = false
        isWorking = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.stage(gh: gh, repo: repo, tag: info.tag)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isWorking = false

                switch outcome {
                case .failure(let text):
                    self.report(text)

                case .staged(let script, let arguments):
                    // The helper outlives us: it waits for this process to exit, swaps the
                    // bundle, then relaunches.
                    Self.launchDetached(script: script, arguments: arguments)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func report(_ text: String) {
        message = text
        showMessage = true
    }

    // MARK: - Version arithmetic

    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = parts(candidate)
        let old = parts(current)
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        // Same numbers: rank the suffixes. A final release outranks every candidate for it,
        // and a later candidate outranks an earlier one, so rc.2 reaches rc.1.
        return rank(candidate) > rank(current)
    }

    /// How far along a version is within its own release number: a final release is top, and a
    /// candidate is ordered by the number in its suffix.
    private static func rank(_ version: String) -> Int {
        let pieces = version.split(separator: "-")
        guard pieces.count > 1 else { return .max }
        let tail = pieces.dropFirst().joined(separator: "-")
        let digits = tail.split(whereSeparator: { !$0.isNumber })
        return digits.last.flatMap { Int($0) } ?? 0
    }

    /// The numeric part only. A candidate's suffix is dropped rather than parsed, so
    /// `1.0.0-rc.1` does not read as a fourth component and come out *above* `1.0.0`.
    private static func parts(_ version: String) -> [Int] {
        let release = version.split(separator: "-").first.map(String.init) ?? version
        return release.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }

    // MARK: - Work done off the main thread

    private enum CheckOutcome {
        case success(ReleaseInfo)
        /// GitHub answered, and there is no published release to compare against.
        case none
        case failure(String)
    }

    private enum StageOutcome {
        case staged(script: String, arguments: [String])
        case failure(String)
    }

    /// The highest-numbered release, pre-releases and candidates included.
    ///
    /// `gh release view` with no tag would be shorter, but it means the newest release that is
    /// *not* a pre-release — and every release so far is one, candidates included, so it finds
    /// nothing at all. Listing instead is what makes a candidate installable.
    ///
    /// Picked by version rather than by date, so a patch cut after a candidate cannot look
    /// like the newest thing going, and by the same comparison the caller then applies.
    private static func latestRelease(gh: String, repo: String) -> CheckOutcome {
        let result = run(gh, ["release", "list", "--repo", repo,
                              "--limit", "30", "--json", "tagName,isDraft"])
        guard result.status == 0 else {
            return .failure(result.error.isEmpty ? "Could not reach GitHub." : result.error)
        }
        guard let data = result.output.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else {
            return .failure("Could not read the release information from GitHub.")
        }

        let tags = entries
            .filter { ($0["isDraft"] as? Bool) != true }
            .compactMap { $0["tagName"] as? String }
            .filter { !$0.isEmpty }
        guard let newest = tags.max(by: { isNewer(normalize($1), than: normalize($0)) }) else {
            return .none
        }
        return .success(ReleaseInfo(tag: newest, version: normalize(newest)))
    }

    private static func stage(gh: String, repo: String, tag: String) -> StageOutcome {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appendingPathComponent("chartdesk-update-\(UUID().uuidString)")

        do {
            try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .failure("Could not create a temporary folder for the download.")
        }

        let download = run(gh, ["release", "download", tag,
                                "--repo", repo,
                                "--pattern", "\(appName).app.zip",
                                "--dir", scratch.path])
        guard download.status == 0 else {
            return .failure(download.error.isEmpty ? "Could not download the update." : download.error)
        }

        let archive = scratch.appendingPathComponent("\(appName).app.zip")
        guard manager.fileExists(atPath: archive.path) else {
            return .failure("The download contained no archive.")
        }

        let unpacked = scratch.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]).status == 0 else {
            return .failure("Could not unpack the update.")
        }

        let newBundle = unpacked.appendingPathComponent("\(appName).app")
        guard manager.fileExists(atPath: newBundle.appendingPathComponent("Contents/Info.plist").path) else {
            return .failure("The update did not contain \(appName).app.")
        }

        // Downloads arrive quarantined, and an ad-hoc signature does not survive Gatekeeper's
        // check on a quarantined bundle. This mirrors what update.sh already does.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newBundle.path])

        let script = scratch.appendingPathComponent("install.sh")
        do {
            try helperScript.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Could not stage the installer.")
        }

        return .staged(script: script.path,
                       arguments: ["\(ProcessInfo.processInfo.processIdentifier)",
                                   newBundle.path,
                                   destination,
                                   scratch.path])
    }

    private static func launchDetached(script: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script] + arguments
        try? process.run()
    }

    private struct RunResult {
        let status: Int32
        let output: String
        let error: String
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return RunResult(status: -1, output: "", error: error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            status: process.terminationStatus,
            output: String(data: outData, encoding: .utf8) ?? "",
            error: (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Runs after the app has quit, because a bundle cannot reliably replace itself while it is
    /// executing. The old copy is kept aside until the new one is in place, so a failed copy
    /// rolls back rather than leaving nothing installed.
    private static let helperScript = """
    #!/bin/sh
    # Arguments: <pid to wait for> <new bundle> <destination> <scratch dir>
    PID="$1"
    NEW="$2"
    DEST="$3"
    SCRATCH="$4"

    # Never replace a bundle that is still running.
    i=0
    while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 150 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    # Refuse to touch anything that is not a Chartdesk bundle.
    case "$DEST" in
        */Chartdesk.app) ;;
        *) exit 1 ;;
    esac

    rm -rf "$DEST.old"
    if [ -e "$DEST" ]; then
        mv "$DEST" "$DEST.old" || exit 1
    fi

    if /usr/bin/ditto "$NEW" "$DEST"; then
        rm -rf "$DEST.old"
    else
        rm -rf "$DEST"
        if [ -e "$DEST.old" ]; then
            mv "$DEST.old" "$DEST"
        fi
        exit 1
    fi

    /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    /usr/bin/open "$DEST"
    rm -rf "$SCRATCH"
    """
}
