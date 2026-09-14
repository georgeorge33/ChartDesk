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

    func request(chart: Chart?, key: String, night: Bool, desaturate: Bool, rotation: Int) {
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
        // night-mode toggles from flashing.
        image = nil
        errorText = nil
        isLoading = true

        let url = chart.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ChartImageStore.shared.image(url: url,
                                                      night: night,
                                                      desaturate: desaturate,
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
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            if let chart = chart {
                ChartCanvas(image: model.image,
                            resetKey: browser.resetKey(for: chart),
                            background: browser.canvasColor,
                            fitOnOpen: browser.zoomToFitOnOpen,
                            controller: viewer)

                if let errorText = model.errorText {
                    errorOverlay(errorText)
                } else if model.isLoading {
                    loadingOverlay
                }
            } else {
                NoChartSelectedView()
            }
        }
        .navigationTitle(chart?.title ?? "Chartdesk")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .onAppear { refresh() }
        .onChange(of: renderKey) { _ in refresh() }
    }

    private func refresh() {
        model.request(chart: chart,
                      key: renderKey,
                      night: browser.nightMode,
                      desaturate: browser.desaturateNight,
                      rotation: browser.rotation)
    }

    // MARK: Overlays

    private var loadingOverlay: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let chart = chart { library.togglePin(chart) }
            } label: {
                Label(isPinned ? "Unpin Chart" : "Pin Chart",
                      systemImage: isPinned ? "star.fill" : "star")
            }
            .disabled(chart == nil)
            .help(isPinned ? "Remove from pinned charts" : "Pin this chart")

            Button {
                browser.nightMode.toggle()
            } label: {
                Label("Night Mode", systemImage: browser.nightMode ? "moon.fill" : "moon")
            }
            .disabled(chart == nil)
            .help("Invert the chart for night flying")

            Button {
                browser.rotateRight()
            } label: {
                Label("Rotate Right", systemImage: "arrow.clockwise")
            }
            .disabled(chart == nil)
            .help("Rotate 90° clockwise")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                viewer.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .disabled(chart == nil)

            Text(viewer.zoomPercentText)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 48)
                .help("Current zoom level")

            Button {
                viewer.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .disabled(chart == nil)

            Button {
                viewer.zoomToFit()
            } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(chart == nil)
            .help("Fit the whole chart in the window")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let chart = chart {
                    Button("Reveal in Finder") { ChartActions.reveal(chart) }
                    Button("Open in Preview") { ChartActions.openExternally(chart) }
                    Divider()
                    Button("Copy Image") { ChartActions.copyToPasteboard(chart, state: browser) }
                    Button("Export as PNG…") { ChartActions.exportPNG(chart, state: browser) }
                    Button("Print…") { ChartActions.printChart(chart, state: browser) }
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
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
