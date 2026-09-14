import AppKit
import Foundation
import UniformTypeIdentifiers

/// Side-effecting actions for a single chart. Everything here renders the chart exactly as it
/// appears on screen, so a night-mode, rotated or annotated chart prints and exports the way
/// it looks.
enum ChartActions {

    static func renderedImage(for chart: Chart,
                              state: BrowserState,
                              marks: AnnotationStore,
                              completion: @escaping (NSImage) -> Void) {
        let night = state.nightMode
        let desaturate = state.desaturateNight
        let rotation = state.rotation
        // Read on the caller's thread: the store belongs to the UI. Marks that are currently
        // hidden stay out of the copy, which keeps "what you see is what you get" honest.
        let annotations = marks.visibleMarks(for: chart.id)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ChartImageStore.shared.image(url: chart.url,
                                                      night: night,
                                                      desaturate: desaturate,
                                                      rotation: rotation)
            switch result {
            case .success(let loaded):
                let composed = AnnotationRenderer.burnIn(annotations, over: loaded, rotation: rotation)
                DispatchQueue.main.async { completion(composed) }
            case .failure:
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    static func reveal(_ chart: Chart) {
        NSWorkspace.shared.activateFileViewerSelecting([chart.url])
    }

    static func openExternally(_ chart: Chart) {
        NSWorkspace.shared.open(chart.url)
    }

    static func copyToPasteboard(_ chart: Chart, state: BrowserState, marks: AnnotationStore) {
        renderedImage(for: chart, state: state, marks: marks) { image in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
    }

    static func exportPNG(_ chart: Chart, state: BrowserState, marks: AnnotationStore) {
        renderedImage(for: chart, state: state, marks: marks) { image in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType.png]
            panel.nameFieldStringValue = "\(chart.airportCode) \(chart.title).png"
            panel.message = "Save a copy of this chart as it is shown."
            guard panel.runModal() == .OK, let url = panel.url else { return }

            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else {
                NSSound.beep()
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                presentError(error)
            }
        }
    }

    static func printChart(_ chart: Chart, state: BrowserState, marks: AnnotationStore) {
        renderedImage(for: chart, state: state, marks: marks) { image in
            guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
            info.orientation = image.size.width >= image.size.height ? .landscape : .portrait
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = true
            info.topMargin = 18
            info.bottomMargin = 18
            info.leftMargin = 18
            info.rightMargin = 18

            let printView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
            printView.image = image
            printView.imageScaling = .scaleProportionallyUpOrDown

            let operation = NSPrintOperation(view: printView, printInfo: info)
            operation.jobTitle = "\(chart.airportCode) \(chart.title)"
            operation.run()
        }
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
