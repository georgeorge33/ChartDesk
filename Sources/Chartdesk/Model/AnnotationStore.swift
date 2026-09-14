import Combine
import Foundation

// MARK: - Disk

/// Marks live next to the category corrections, keyed by the same library-relative chart id.
/// The chart files themselves are never touched — Chartdesk still only ever reads them.
enum AnnotationFileStore {

    private static var fileURL: URL? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Chartdesk", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("annotations.json")
    }

    static func load() -> [String: [Annotation]] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [Annotation]].self, from: data)) ?? [:]
    }

    static func save(_ marks: [String: [Annotation]]) {
        guard let url = fileURL else { return }
        // An empty list for a chart is the same as no entry; don't grow the file with them.
        let pruned = marks.filter { !$0.value.isEmpty }
        guard let data = try? JSONEncoder().encode(pruned) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Store

/// Everything about marking up charts: what is drawn on each one, and what the palette is
/// currently set to. Kept apart from `BrowserState` so the viewer, the palette, the menu
/// commands and the export path can all reach it.
final class AnnotationStore: ObservableObject {

    /// Marks per chart id, oldest first — drawing order is the array order.
    @Published private(set) var marks: [String: [Annotation]]

    /// Annotate mode. While this is off the overlay ignores every click, so panning,
    /// zooming and double-click-to-fit behave exactly as they did before.
    @Published var isAnnotating = false {
        didSet {
            guard oldValue != isAnnotating else { return }
            if isAnnotating { showMarks = true }
        }
    }

    @Published var showMarks: Bool {
        didSet { UserDefaults.standard.set(showMarks, forKey: DefaultsKey.showAnnotations) }
    }

    @Published var tool: AnnotationTool {
        didSet { UserDefaults.standard.set(tool.rawValue, forKey: DefaultsKey.annotationTool) }
    }

    @Published var color: AnnotationColor {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: DefaultsKey.annotationColor) }
    }

    @Published var width: AnnotationWidth {
        didSet { UserDefaults.standard.set(width.rawValue, forKey: DefaultsKey.annotationWidth) }
    }

    /// Snapshots taken before each change. Per chart, so undoing on one plate cannot reach
    /// back and alter another.
    private var undoStacks: [String: [[Annotation]]] = [:]
    private var redoStacks: [String: [[Annotation]]] = [:]
    private static let undoDepth = 50

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [DefaultsKey.showAnnotations: true])

        marks = AnnotationFileStore.load()
        showMarks = defaults.bool(forKey: DefaultsKey.showAnnotations)
        tool = AnnotationTool(rawValue: defaults.string(forKey: DefaultsKey.annotationTool) ?? "") ?? .pen
        color = AnnotationColor(rawValue: defaults.string(forKey: DefaultsKey.annotationColor) ?? "") ?? .red
        width = AnnotationWidth(rawValue: defaults.string(forKey: DefaultsKey.annotationWidth) ?? "") ?? .medium

        // The eraser is a transient choice; coming back to a fresh launch holding it would
        // mean the first click deletes something.
        if tool == .eraser { tool = .pen }
    }

    // MARK: Reading

    func marks(for chartID: String?) -> [Annotation] {
        guard let chartID = chartID else { return [] }
        return marks[chartID] ?? []
    }

    /// What the canvas should actually paint: nothing at all when marks are hidden.
    func visibleMarks(for chartID: String?) -> [Annotation] {
        showMarks ? marks(for: chartID) : []
    }

    func count(for chartID: String?) -> Int {
        marks(for: chartID).count
    }

    func hasMarks(for chartID: String?) -> Bool {
        !marks(for: chartID).isEmpty
    }

    var totalCount: Int {
        marks.values.reduce(0) { $0 + $1.count }
    }

    var chartCount: Int {
        marks.values.reduce(0) { $1.isEmpty ? $0 : $0 + 1 }
    }

    func canUndo(_ chartID: String?) -> Bool {
        guard let chartID = chartID else { return false }
        return !(undoStacks[chartID] ?? []).isEmpty
    }

    func canRedo(_ chartID: String?) -> Bool {
        guard let chartID = chartID else { return false }
        return !(redoStacks[chartID] ?? []).isEmpty
    }

    // MARK: Writing

    func add(_ annotation: Annotation, to chartID: String) {
        guard !annotation.isEmpty else { return }
        checkpoint(chartID)
        marks[chartID, default: []].append(annotation)
        persist()
    }

    func remove(_ id: UUID, from chartID: String) {
        guard let existing = marks[chartID], existing.contains(where: { $0.id == id }) else { return }
        checkpoint(chartID)
        marks[chartID] = existing.filter { $0.id != id }
        persist()
    }

    func clear(_ chartID: String?) {
        guard let chartID = chartID, !(marks[chartID] ?? []).isEmpty else { return }
        checkpoint(chartID)
        marks[chartID] = []
        persist()
    }

    func clearAll() {
        guard !marks.isEmpty else { return }
        for (chartID, existing) in marks where !existing.isEmpty {
            checkpoint(chartID)
        }
        marks = [:]
        persist()
    }

    func undo(_ chartID: String?) {
        guard let chartID = chartID,
              var stack = undoStacks[chartID], let previous = stack.popLast() else { return }
        undoStacks[chartID] = stack
        push(&redoStacks, chartID: chartID, state: marks[chartID] ?? [])
        marks[chartID] = previous
        persist()
    }

    func redo(_ chartID: String?) {
        guard let chartID = chartID,
              var stack = redoStacks[chartID], let next = stack.popLast() else { return }
        redoStacks[chartID] = stack
        push(&undoStacks, chartID: chartID, state: marks[chartID] ?? [])
        marks[chartID] = next
        persist()
    }

    // MARK: Internals

    /// Records the state a change is about to replace, and drops any redo history — the
    /// usual behaviour once you branch off an undone edit.
    private func checkpoint(_ chartID: String) {
        push(&undoStacks, chartID: chartID, state: marks[chartID] ?? [])
        redoStacks[chartID] = []
    }

    private func push(_ stacks: inout [String: [[Annotation]]], chartID: String, state: [Annotation]) {
        var stack = stacks[chartID] ?? []
        stack.append(state)
        if stack.count > Self.undoDepth {
            stack.removeFirst(stack.count - Self.undoDepth)
        }
        stacks[chartID] = stack
    }

    private func persist() {
        AnnotationFileStore.save(marks)
    }
}
