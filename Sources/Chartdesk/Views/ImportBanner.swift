import SwiftUI

/// The offer to file charts waiting in the download folder.
///
/// Sits over the bottom of the window rather than in a sheet: it is news, not a question you
/// have to answer before carrying on, and the countdown means it answers itself.
struct ImportBanner: View {

    @EnvironmentObject private var importer: ImportController

    var onImport: () -> Void

    private var summary: String {
        let count = importer.waiting.count
        let airports = orderedAirports
        let where_ = airports.count <= 3
            ? airports.joined(separator: ", ")
            : "\(airports.count) airports"
        return "\(count) \(count == 1 ? "chart" : "charts") for \(where_)"
    }

    private var orderedAirports: [String] {
        var seen: [String] = []
        for chart in importer.waiting where !seen.contains(chart.airport) {
            seen.append(chart.airport)
        }
        return seen
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 17))
                .foregroundStyle(Color.ngAccentText)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.callout)
                    .fontWeight(.medium)
                Text("Waiting in \(ChartImporter.downloadsFolder.lastPathComponent) · filing in "
                     + "\(importer.secondsLeft)s")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Button("Not now") { importer.dismiss() }
                .buttonStyle(.bordered)
            Button("File now") { onImport() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.ngSeparator)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .frame(maxWidth: 560)
        .padding(.bottom, 18)
        .help(importer.waiting.map(\.destination).joined(separator: "\n"))
    }
}

/// What the import did, for the few seconds after it happens.
struct ImportReport: View {

    @EnvironmentObject private var importer: ImportController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(importer.trouble == nil ? Color.ngAccentText : Color.ngWarning)
            Text(text)
                .font(.ngSmall)
            Button {
                importer.clearReport()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay { Capsule(style: .continuous).strokeBorder(Color.ngSeparator) }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.bottom, 18)
        .task {
            // Long enough to read, then out of the way on its own.
            try? await Task.sleep(for: .seconds(6))
            importer.clearReport()
        }
    }

    private var icon: String {
        importer.trouble == nil ? "tray.and.arrow.down.fill" : "exclamationmark.triangle.fill"
    }

    private var text: String {
        switch importer.trouble {
        case .noPermission:
            return "Chartdesk needs permission to read your "
                + "\(ChartImporter.downloadsFolder.lastPathComponent) folder."
        case .unreadable:
            return "Could not read your "
                + "\(ChartImporter.downloadsFolder.lastPathComponent) folder."
        case .none:
            return importer.report ?? ""
        }
    }
}
