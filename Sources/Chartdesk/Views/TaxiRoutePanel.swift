import SwiftUI

/// The route builder that floats over the plate: press taxiways rather than type them.
///
/// Pressing rather than typing is not only quicker — it removes a class of problem outright.
/// Boston has both a gate A1 and a taxiway A1, which any text grammar would have to
/// disambiguate; separate controls simply cannot be ambiguous. You also cannot press a
/// taxiway that is not in the data, so "no such taxiway" stops being a possible outcome.
struct TaxiRoutePanel: View {

    @EnvironmentObject private var planner: TaxiRouteStore
    @EnvironmentObject private var annotations: AnnotationStore

    let chartID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let unavailable = planner.unavailable {
                message(unavailable, symbol: "tray")
            } else if planner.isCalibrating {
                calibrating
            } else if !planner.isCalibrated(chartID) {
                needsCalibration
            } else {
                builder
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 660)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ngPanelRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.ngSeparator, lineWidth: 1)
                )
        )
        .shadow(radius: 14, y: 5)
    }

    // MARK: - States

    private func message(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.ngAccentText)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            closeButton
        }
    }

    private var needsCalibration: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(Color.ngAccentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("This chart hasn't been lined up with the ground yet.")
                    .font(.callout)
                Text("Click two taxiway crossings and it works the rest out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Calibrate…") { planner.beginCalibration() }
                .buttonStyle(.borderedProminent)
            closeButton
        }
    }

    private var calibrating: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Crossing", selection: Binding(
                    get: { planner.calibrationTarget ?? planner.graph?.intersections.first },
                    set: { planner.calibrationTarget = $0 })) {
                    ForEach(planner.graph?.intersections ?? []) { crossing in
                        Text(crossing.label).tag(Optional(crossing))
                    }
                }
                .labelsHidden()
                .frame(width: 128)

                Text(planner.calibrationPrompt)
                    .font(.callout)

                Spacer(minLength: 0)

                Button {
                    planner.removeLastCalibrationPoint()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(planner.pendingAnchors.isEmpty ? Color.secondary : Color.ngAccentText)
                .disabled(planner.pendingAnchors.isEmpty)
                .help("Undo the last point")

                Button("Cancel") { planner.cancelCalibration() }

                Button("Done") { planner.commitCalibration(chartID: chartID ?? "") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!planner.canCommitCalibration || chartID == nil)
            }

            HStack(spacing: 8) {
                ForEach(Array(planner.pendingAnchors.enumerated()), id: \.offset) { _, anchor in
                    Text(anchor.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.ngAccent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(.white)
                }
                if planner.pendingAnchors.count < 2 {
                    Text("Two points minimum. Zoom in first — the closer you click, the better every route lands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let note = planner.calibrationNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(noteColour(note))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Warnings read as warnings; a plain measurement does not.
    private func noteColour(_ note: String) -> Color {
        note.hasPrefix("Off by") || note.hasPrefix("Lined up") ? .secondary : .orange
    }

    // MARK: - Builder

    private var builder: some View {
        VStack(alignment: .leading, spacing: 9) {
            chips

            Divider().overlay(Color.ngSeparator)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 9) {
                    section(title: taxiwayTitle) {
                        grid(planner.graph?.designators ?? []) { name in
                            token(name,
                                  isChosen: planner.tokens.contains(.taxiway(name)),
                                  isDimmed: dimmed(name)) {
                                planner.append(.taxiway(name))
                            }
                        }
                    }

                    if let runways = planner.graph?.runwayNames, !runways.isEmpty {
                        section(title: "Runways") {
                            grid(runways, minimum: 72) { name in
                                token(name,
                                      isChosen: planner.tokens.contains(.runway(name)),
                                      isDimmed: false) {
                                    planner.append(.runway(name))
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 190)

            Divider().overlay(Color.ngSeparator)

            footer
        }
    }

    private var taxiwayTitle: String {
        guard let connecting = planner.connectingNext, let last = lastTaxiway else {
            return "Taxiways"
        }
        return "Taxiways — \(connecting.count) connect to \(last)"
    }

    private var lastTaxiway: String? {
        planner.taxiways.last
    }

    private func dimmed(_ name: String) -> Bool {
        guard let connecting = planner.connectingNext else { return false }
        return !connecting.contains(name)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            Text("Route")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            if planner.tokens.isEmpty {
                Text("press a taxiway below")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(planner.tokens.enumerated()), id: \.offset) { index, item in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(item.label)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(item.isRunway ? Color.ngAccentText.opacity(0.22) : Color.ngAccent,
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if let summary = planner.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let failure = planner.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
            }

            Button {
                planner.removeLast()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(planner.tokens.isEmpty ? Color.secondary : Color.ngAccentText)
            .disabled(planner.tokens.isEmpty)
            .help("Remove the last step")

            Button("Clear") { planner.clearRoute() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(planner.tokens.isEmpty)

            closeButton
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let graph = planner.graph, !graph.standNames.isEmpty {
                Text("From gate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { planner.stand ?? "" },
                    set: { planner.setStand($0.isEmpty ? nil : $0) })) {
                    Text("—").tag("")
                    ForEach(graph.standNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 92)

                if planner.stand != nil, planner.route?.approximateLeadIn != nil {
                    Text("lead-in approximate")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
            }

            Spacer(minLength: 0)

            Button("Recalibrate") {
                planner.removeCalibration(chartID)
                planner.beginCalibration()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Draw on chart") { commit() }
                .buttonStyle(.borderedProminent)
                .disabled(planner.route == nil)
        }
    }

    private var closeButton: some View {
        Button {
            planner.isPlanning = false
        } label: {
            Image(systemName: "xmark")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close the route planner")
    }

    // MARK: - Pieces

    private func section<Content: View>(title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func grid(_ names: [String],
                      minimum: CGFloat = 40,
                      @ViewBuilder cell: @escaping (String) -> some View) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 5)],
                  alignment: .leading, spacing: 5) {
            ForEach(names, id: \.self) { cell($0) }
        }
    }

    private func token(_ name: String,
                       isChosen: Bool,
                       isDimmed: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(background(isChosen: isChosen, isDimmed: isDimmed))
                .foregroundStyle(isChosen ? Color.white
                                 : isDimmed ? Color.secondary : Color.ngAccentText)
        }
        .buttonStyle(.plain)
        // Dimmed means "probably not this one", never "you may not". Imperfect map data must
        // not be able to make a legitimate turn unreachable.
        .help(isDimmed ? "\(name) — doesn't appear to connect here" : name)
    }

    private func background(isChosen: Bool, isDimmed: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isChosen ? Color.ngAccent : Color.ngPanel.opacity(isDimmed ? 0.35 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isChosen ? Color.ngAccentText.opacity(0.7) : Color.ngSeparator,
                                  lineWidth: 1)
            )
    }

    private func commit() {
        guard let chartID = chartID else { return }
        let marks = planner.marks(for: chartID,
                                  colour: annotations.color,
                                  width: annotations.width)
        guard !marks.isEmpty else { return }
        for mark in marks {
            annotations.add(mark, to: chartID)
        }
        annotations.showMarks = true
        planner.clearRoute()
    }
}
