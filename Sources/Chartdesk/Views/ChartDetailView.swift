import AppKit
import Combine
import SwiftUI

// MARK: - Render model

/// Loads the image for whatever the viewer is showing, off the main thread.
final class ChartRenderModel: ObservableObject {

    @Published var image: NSImage?
    @Published var isLoading = false
    @Published var errorText: String?

    private var currentKey = ""
    private var generation = 0

    func request(chart: Chart?, key: String, rotation: Int) {
        guard key != currentKey else { return }
        currentKey = key
        generation += 1
        let token = generation

        guard let chart = chart else {
            image = nil
            errorText = nil
            isLoading = false
            return
        }

        // The previous image stays on screen until the new one is ready, which keeps
        // rotations from flashing.
        image = nil
        errorText = nil
        isLoading = true

        let url = chart.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ChartImageStore.shared.image(url: url,
                                                      rotation: rotation)
            DispatchQueue.main.async {
                guard let self = self, token == self.generation else { return }
                self.isLoading = false
                switch result {
                case .success(let loaded):
                    self.image = loaded
                    self.errorText = nil
                case .failure(let error):
                    self.image = nil
                    self.errorText = error.message
                }
            }
        }
    }
}

// MARK: - Detail view

struct ChartDetailView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var viewer: ChartViewerController
    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var flight: FlightPlanStore
    @StateObject private var model = ChartRenderModel()

    private var chart: Chart? {
        library.chart(id: browser.selectedChartID)
    }

    private var renderKey: String {
        browser.renderKey(for: chart)
    }

    private var subtitle: String {
        guard let chart = chart else { return "" }
        var parts: [String] = []
        if !chart.airportCode.isEmpty && chart.airportCode != Airport.unsortedCode {
            parts.append(chart.airportCode)
        }
        parts.append(chart.category.displayName)
        if let runway = chart.runway { parts.append("RWY \(runway)") }
        if browser.rotation != 0 { parts.append("\(browser.rotation)°") }

        let marks = annotations.count(for: chart.id)
        if marks > 0 { parts.append(marks == 1 ? "1 mark" : "\(marks) marks") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // The map is a selection rather than a window, so this pane is where it draws.
        if browser.sidebarSelection == .map {
            RouteMapView()
        } else {
            chartBody
        }
    }

    private var chartBody: some View {
        ZStack {
            if let chart = chart {
                ChartCanvas(image: model.image,
                            resetKey: browser.resetKey(for: chart),
                            background: browser.canvasColor,
                            fitOnOpen: browser.zoomToFitOnOpen,
                            controller: viewer,
                            annotations: annotations.visibleMarks(for: chart.id),
                            chartKey: chart.id,
                            rotation: browser.rotation,
                            isAnnotating: annotations.isAnnotating,
                            tool: annotations.tool,
                            color: annotations.color,
                            width: annotations.width,
                            onDraw: { mark in annotations.add(mark, to: chart.id) },
                            onErase: { identifier in annotations.remove(identifier, from: chart.id) })

                if let errorText = model.errorText {
                    errorOverlay(errorText)
                } else if model.isLoading {
                    loadingOverlay
                }
            } else {
                NoChartSelectedView(background: browser.canvasColor)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if annotations.isAnnotating, chart != nil {
                    AnnotationPalette(chartID: chart?.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 20)
        }
        .animation(.easeOut(duration: 0.16), value: annotations.isAnnotating)
        .navigationTitle(chart?.title ?? "Chartdesk")
        .navigationSubtitle(subtitle)
        .toolbar(id: "chart", content: toolbarContent)
        .toolbarBackground(Color.ngWindow, for: .windowToolbar)
        .onAppear { refresh() }
        .onChange(of: renderKey) { refresh() }
    }

    private func refresh() {
        model.request(chart: chart,
                      key: renderKey,
                      rotation: browser.rotation)
    }

    // MARK: Overlays

    private var loadingOverlay: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .padding(10)
            .background(Color.ngPanelRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(radius: 6, y: 2)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let chart = chart {
                Button("Reveal in Finder") { ChartActions.reveal(chart) }
            }
        }
        .padding(24)
        .background(Color.ngPanelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Toolbar

    /// Every button is its own identified item, so the whole bar can be rearranged or pared
    /// back from View ▸ Customize Toolbar…. `showsByDefault: false` items start out in the
    /// customisation sheet rather than on the bar.
    ///
    /// Split across three builders because `ToolbarContentBuilder` takes at most ten children.
    @ToolbarContentBuilder
    private func toolbarContent() -> some CustomizableToolbarContent {
        markupItems()
        viewItems()
        fileItems()
    }

    /// Pinning and everything to do with marking a plate up.
    @ToolbarContentBuilder
    private func markupItems() -> some CustomizableToolbarContent {

        ToolbarItem(id: "pin", placement: .primaryAction) {
            Button {
                if let chart = chart { library.togglePin(chart) }
            } label: {
                Label(isPinned ? "Unpin Chart" : "Pin Chart",
                      systemImage: isPinned ? "star.fill" : "star")
            }
            .disabled(chart == nil)
            .help(isPinned ? "Remove from pinned charts" : "Pin this chart")
        }

        ToolbarItem(id: "annotate", placement: .primaryAction) {
            Button {
                annotations.isAnnotating.toggle()
            } label: {
                Label("Annotate",
                      systemImage: annotations.isAnnotating ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            }
            .disabled(chart == nil)
            .help(annotations.isAnnotating ? "Stop drawing on this chart" : "Draw on this chart")
        }

        ToolbarItem(id: "marks.visible", placement: .primaryAction, showsByDefault: false) {
            Button {
                annotations.showMarks.toggle()
            } label: {
                Label("Show Marks", systemImage: annotations.showMarks ? "eye" : "eye.slash")
            }
            .help(annotations.showMarks ? "Hide every mark" : "Show marks again")
        }

        ToolbarItem(id: "marks.undo", placement: .primaryAction, showsByDefault: false) {
            Button {
                annotations.undo(chart?.id)
            } label: {
                Label("Undo Mark", systemImage: "arrow.uturn.backward")
            }
            .disabled(!annotations.canUndo(chart?.id))
            .help("Undo the last mark")
        }

        ToolbarItem(id: "marks.clear", placement: .primaryAction, showsByDefault: false) {
            Button {
                annotations.clear(chart?.id)
            } label: {
                Label("Clear Marks", systemImage: "trash")
            }
            .disabled(!annotations.hasMarks(for: chart?.id))
            .help("Remove every mark on this chart")
        }
    }

    /// Orientation and zoom.
    @ToolbarContentBuilder
    private func viewItems() -> some CustomizableToolbarContent {

        ToolbarItem(id: "rotate.right", placement: .primaryAction) {
            Button {
                browser.rotateRight()
            } label: {
                Label("Rotate Right", systemImage: "arrow.clockwise")
            }
            .disabled(chart == nil)
            .help("Rotate 90° clockwise")
        }

        ToolbarItem(id: "rotate.left", placement: .primaryAction, showsByDefault: false) {
            Button {
                browser.rotateLeft()
            } label: {
                Label("Rotate Left", systemImage: "arrow.counterclockwise")
            }
            .disabled(chart == nil)
            .help("Rotate 90° anticlockwise")
        }

        ToolbarItem(id: "rotate.reset", placement: .primaryAction, showsByDefault: false) {
            Button {
                browser.resetRotation()
            } label: {
                Label("Reset Rotation", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(chart == nil || browser.rotation == 0)
            .help("Put the chart back upright")
        }

        ToolbarItem(id: "zoom.out", placement: .primaryAction) {
            Button {
                viewer.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .disabled(chart == nil)
        }

        ToolbarItem(id: "zoom.level", placement: .primaryAction) {
            Text(viewer.zoomPercentText)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 48)
                .help("Current zoom level")
        }

        ToolbarItem(id: "zoom.in", placement: .primaryAction) {
            Button {
                viewer.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .disabled(chart == nil)
        }

        ToolbarItem(id: "zoom.fit", placement: .primaryAction) {
            Button {
                viewer.zoomToFit()
            } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(chart == nil)
            .help("Fit the whole chart in the window")
        }

        ToolbarItem(id: "zoom.actual", placement: .primaryAction, showsByDefault: false) {
            Button {
                viewer.actualSize()
            } label: {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .disabled(chart == nil)
            .help("One chart pixel per screen point")
        }
    }

    /// Getting the chart back out of Chartdesk.
    @ToolbarContentBuilder
    private func fileItems() -> some CustomizableToolbarContent {

        ToolbarItem(id: "reveal", placement: .primaryAction, showsByDefault: false) {
            Button {
                if let chart = chart { ChartActions.reveal(chart) }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(chart == nil)
            .help("Show the file in Finder")
        }

        ToolbarItem(id: "copy", placement: .primaryAction, showsByDefault: false) {
            Button {
                if let chart = chart { ChartActions.copyToPasteboard(chart, state: browser, marks: annotations) }
            } label: {
                Label("Copy Image", systemImage: "doc.on.doc")
            }
            .disabled(chart == nil)
            .help("Copy the chart as it is shown")
        }

        ToolbarItem(id: "export", placement: .primaryAction, showsByDefault: false) {
            Button {
                if let chart = chart { ChartActions.exportPNG(chart, state: browser, marks: annotations) }
            } label: {
                Label("Export as PNG…", systemImage: "square.and.arrow.down")
            }
            .disabled(chart == nil)
            .help("Save a copy of the chart as it is shown")
        }

        ToolbarItem(id: "print", placement: .primaryAction, showsByDefault: false) {
            Button {
                if let chart = chart { ChartActions.printChart(chart, state: browser, marks: annotations) }
            } label: {
                Label("Print…", systemImage: "printer")
            }
            .disabled(chart == nil)
            .help("Print the chart as it is shown")
        }

        ToolbarItem(id: "actions", placement: .primaryAction) {
            Menu {
                if let chart = chart {
                    Button("Reveal in Finder") { ChartActions.reveal(chart) }
                    Button("Open in Preview") { ChartActions.openExternally(chart) }
                    Divider()
                    Button("Copy Image") { ChartActions.copyToPasteboard(chart, state: browser, marks: annotations) }
                    Button("Export as PNG…") { ChartActions.exportPNG(chart, state: browser, marks: annotations) }
                    Button("Print…") { ChartActions.printChart(chart, state: browser, marks: annotations) }
                    Divider()
                    Menu("Move to Category") {
                        ForEach(ChartCategory.displayOrder) { category in
                            Button(category.displayName) {
                                library.setCategory(category, for: chart)
                            }
                            .disabled(category == chart.category)
                        }
                    }
                }
            } label: {
                Label("Chart Actions", systemImage: "ellipsis.circle")
            }
            .disabled(chart == nil)
            .help("More chart actions")
        }
    }

    private var isPinned: Bool {
        guard let chart = chart else { return false }
        return library.isPinned(chart)
    }
}

// MARK: - Placeholder

private struct NoChartSelectedView: View {

    let background: NSColor

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Chart Selected")
                .font(.title3)
            Text("Pick an airport, then choose a chart from the list.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: background))
    }
}
