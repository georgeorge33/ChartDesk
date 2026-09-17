import Combine
import Foundation

/// Offers to file charts waiting in the download folder, and does it unless told not to.
///
/// The offer stands for ten seconds. That is the shape you asked for and it is worth saying why
/// it is defensible: importing adds files and never replaces them, so the worst an unattended
/// countdown can do is move a chart into the library a moment before you would have clicked. It
/// still shows what it is about to do, and "Not now" stops it for the rest of the launch.
@MainActor
final class ImportController: ObservableObject {

    /// Seconds the offer stands before it goes ahead on its own.
    static let grace = 10

    @Published private(set) var waiting: [WaitingChart] = []
    @Published private(set) var secondsLeft = ImportController.grace
    @Published private(set) var report: String?
    @Published private(set) var trouble: ChartImporter.Trouble?

    @Published var importOnLaunch: Bool {
        didSet { UserDefaults.standard.set(importOnLaunch, forKey: DefaultsKey.importOnLaunch) }
    }

    private var libraryRoot: URL?
    private var onFinish: (() -> Void)?
    private var ticker: AnyCancellable?
    private var didCheckThisLaunch = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.importOnLaunch: true])
        importOnLaunch = defaults.bool(forKey: DefaultsKey.importOnLaunch)
    }

    /// Called once the app is actually on screen, so the ten seconds are ten seconds you can
    /// see rather than part of them passing behind the startup screen.
    func checkOnLaunch(libraryRoot root: URL, onFinish finish: @escaping () -> Void) {
        guard importOnLaunch, !didCheckThisLaunch else { return }
        didCheckThisLaunch = true
        look(libraryRoot: root, onFinish: finish)
    }

    /// The same check from the menu, which should answer even when there is nothing to do.
    func checkNow(libraryRoot root: URL, onFinish finish: @escaping () -> Void) {
        look(libraryRoot: root, onFinish: finish, countdown: false) { [weak self] charts, trouble in
            guard let self = self, charts.isEmpty, trouble == nil else { return }
            self.report = "No charts are waiting in "
                + "\(ChartImporter.downloadsFolder.lastPathComponent)."
        }
    }

    /// Reads the folder off the main thread, which is not an optimisation.
    ///
    /// The first read of `~/Downloads` is what makes macOS put its permission dialog up, and
    /// that call does not return until the dialog is answered. On the main thread that freezes
    /// the window behind it: splash, spinner and all, until you notice the dialog and click.
    private func look(libraryRoot root: URL,
                      onFinish finish: @escaping () -> Void,
                      countdown: Bool = true,
                      then report: (([WaitingChart], ChartImporter.Trouble?) -> Void)? = nil) {
        libraryRoot = root
        onFinish = finish
        let folder = ChartImporter.downloadsFolder

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: ChartImporter.Trouble?
            let charts = ChartImporter.waiting(in: folder, trouble: &found)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.trouble = found
                self.waiting = charts
                report?(charts, found)

                guard !charts.isEmpty else { return }
                self.secondsLeft = Self.grace
                guard countdown else { return }
                self.ticker = Timer.publish(every: 1, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in self?.tick() }
            }
        }
    }

    private func tick() {
        guard secondsLeft > 0 else { return }
        secondsLeft -= 1
        if secondsLeft == 0 { performImport() }
    }

    func performImport() {
        stopCounting()
        guard let root = libraryRoot, !waiting.isEmpty else { return }

        // Off the main thread for the same reason as the read, and because a library in
        // iCloud can make a move wait on the network.
        let charts = waiting
        waiting = []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = ChartImporter.move(charts, into: root)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.report = self.describe(outcome)
                if !outcome.imported.isEmpty { self.onFinish?() }
            }
        }
    }

    /// Left alone for this launch. Deliberately not remembered: the charts are still there next
    /// time, and a decision to skip them once is not a decision to skip them for ever.
    func dismiss() {
        stopCounting()
        waiting = []
    }

    func clearReport() {
        report = nil
        trouble = nil
    }

    private func stopCounting() {
        ticker?.cancel()
        ticker = nil
    }

    private func describe(_ outcome: ChartImporter.Outcome) -> String {
        var parts: [String] = []
        if !outcome.imported.isEmpty {
            let where_ = outcome.airports.joined(separator: ", ")
            parts.append("Imported \(outcome.imported.count) "
                         + (outcome.imported.count == 1 ? "chart" : "charts")
                         + " into \(where_)")
        }
        if !outcome.kept.isEmpty {
            parts.append("left \(outcome.kept.count) you already had")
        }
        if !outcome.failed.isEmpty {
            parts.append("could not move \(outcome.failed.count)")
        }
        return parts.isEmpty ? "Nothing to import." : parts.joined(separator: ", ") + "."
    }
}
