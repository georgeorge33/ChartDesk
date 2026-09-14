import SwiftUI

/// The floating strip shown over the plate while annotate mode is on. A solid panel rather
/// than translucent material, for the same reason the other overlays are: material picks up
/// the desktop wallpaper and casts colour across the navy.
struct AnnotationPalette: View {

    @EnvironmentObject private var annotations: AnnotationStore

    let chartID: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnnotationTool.drawing) { tool in
                toolButton(tool)
            }

            separator

            toolButton(.eraser)

            separator

            ForEach(AnnotationColor.allCases) { swatch in
                colorButton(swatch)
            }

            separator

            Picker("", selection: $annotations.width) {
                ForEach(AnnotationWidth.allCases) { width in
                    Text(width.displayName).tag(width)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 92)
            .help("Stroke weight")

            separator

            iconButton("arrow.uturn.backward", help: "Undo (⌘Z)", enabled: annotations.canUndo(chartID)) {
                annotations.undo(chartID)
            }
            iconButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: annotations.canRedo(chartID)) {
                annotations.redo(chartID)
            }
            iconButton("trash", help: "Remove every mark on this chart", enabled: annotations.hasMarks(for: chartID)) {
                annotations.clear(chartID)
            }

            separator

            Button("Done") { annotations.isAnnotating = false }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Leave annotate mode (⎋)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ngPanelRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.ngSeparator, lineWidth: 1)
                )
        )
        .shadow(radius: 12, y: 4)
    }

    // MARK: - Pieces

    private var separator: some View {
        Rectangle()
            .fill(Color.ngSeparator)
            .frame(width: 1, height: 20)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let selected = annotations.tool == tool
        return Button {
            annotations.tool = tool
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(selected ? Color.white : Color.ngAccentText)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.ngAccent : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tool.displayName)
    }

    private func colorButton(_ swatch: AnnotationColor) -> some View {
        let selected = annotations.color == swatch
        return Button {
            annotations.color = swatch
        } label: {
            Circle()
                .fill(Color(nsColor: swatch.nsColor))
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(selected ? 0.95 : 0.25),
                                          lineWidth: selected ? 2 : 1)
                )
                .padding(2)
        }
        .buttonStyle(.plain)
        .help(swatch.displayName)
    }

    private func iconButton(_ symbol: String,
                            help: String,
                            enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(enabled ? Color.ngAccentText : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
