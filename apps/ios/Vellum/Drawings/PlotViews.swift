import SwiftUI
import UIKit
import VellumCore

/// The drawing viewer's card for a DWG with no PDF yet while the laptop plots it (#70), as variant B of
/// prototype/drawing-search has it: Plotting on the laptop with its three steps, Queued on this Duo, Waiting for the
/// laptop, Plotted, not downloaded, and the laptop's reason when it won't plot it, with Ask again.
struct PlotCard: View {
    let entry: DrawingEntry
    /// Where its plot has got to; nil for the moment before the ask reaches the plot watch.
    let stage: PlotStage?
    let askAgain: () -> Void

    private var number: String { entry.number ?? entry.name }
    private var dwgName: String { entry.dwg?.path.split(separator: "/").last.map(String.init) ?? entry.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch stage ?? .asking {
            case .asking, .plotting, .downloading, .done:
                plotting(step: (stage ?? .asking).step ?? 2)
            case .queuedOnThisDuo:
                title("Queued on this Duo", icon: "clock")
                line("You're offline. The request to plot \(number) goes to the laptop as soon as the Duo is back online.")
                line("You can close this; it stays queued.")
            case .waitingForLaptop(let lastSeen):
                title("Waiting for the laptop", icon: "laptopcomputer")
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let seen = lastSeen.map { "was last seen \(PlotStage.lastSeenText($0, now: context.date))" }
                        ?? "hasn't checked in yet"
                    line("The request is in Dropbox, but the laptop \(seen). \(number) plots as soon as it's on.")
                }
                line("You can close this; it carries on by itself.")
            case .plottedOffline:
                title("Plotted, not downloaded", icon: "icloud.slash")
                line("The laptop plotted \(number), but you're offline. The PDF downloads when you're back online.")
            case .notKept(let reason):
                title("Couldn't save the request", icon: "exclamationmark.triangle")
                line(reason)
                Button("Try again", action: askAgain)
                    .buttonStyle(.bordered)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 4)
            case .failed(let reason):
                title("The laptop couldn't plot \(number)", icon: "exclamationmark.triangle")
                line(reason)
                Button("Ask again", action: askAgain)
                    .buttonStyle(.bordered)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 4)
                    .accessibilityHint("Sends the laptop a new request to plot it")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plot-card")
    }

    private func title(_ text: String, icon: String, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
            Text(text)
        }
        .font(.system(size: 15, weight: .semibold))
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func plotting(step: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Plotting on the laptop", icon: "", spinning: true)
            line("\(number) has no PDF yet, so AutoCAD on the laptop is plotting it, the way it prints. Usually under a minute.")
            VStack(alignment: .leading, spacing: 3) {
                stepRow(0, "Asked the laptop, through Dropbox", now: step)
                stepRow(1, "AutoCAD plots \(dwgName) to PDF", now: step)
                stepRow(2, "Download the PDF", now: step)
            }
            .padding(.top, 4)
            // The prototype's bar, a third for each step, the step under way half done.
            ProgressView(value: (Double(step) + 0.5) / 3)
                .tint(DrawingIndexColors.plot)
                .padding(.top, 4)
        }
    }

    private func stepRow(_ index: Int, _ text: String, now: Int) -> some View {
        HStack(spacing: 7) {
            Group {
                if index < now {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                } else if index == now {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("·")
                }
            }
            .frame(width: 14, height: 14)
            Text(text)
        }
        .font(.system(size: 12.5, weight: index == now ? .semibold : .regular))
        .foregroundStyle(index < now ? DrawingIndexColors.ok : index == now ? Color.primary : Color.secondary)
    }
}

/// A row's plot tag in place of "No PDF yet" (#70): "No PDF yet · plots on open" until it is asked, then where its
/// plot has got to; "PDF plotted" in green once it is in.
struct PlotChip: View {
    let stage: PlotStage?

    var body: some View {
        let done = stage == .done
        let icon: String = switch stage {
        case nil, .waitingForLaptop?: "laptopcomputer"
        case .queuedOnThisDuo?: "clock"
        case .plottedOffline?: "icloud.slash"
        case .failed?, .notKept?: "exclamationmark.triangle"
        case .done?: "checkmark"
        case .asking?, .plotting?, .downloading?: "arrow.triangle.2.circlepath"
        }
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(stage?.shortText ?? PlotStage.notAskedText)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(done ? DrawingIndexColors.ok : DrawingIndexColors.plot)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(done ? DrawingIndexColors.okBackground : DrawingIndexColors.plotBackground,
                    in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

/// An entry's markers, as a row, the detail pane and the viewer show them, with its plot's tag in place of "No PDF yet"
/// (#70), and "PDF plotted" on a drawing whose plot came in this session.
struct DrawingChips: View {
    let model: DrawingIndexModel
    let entry: DrawingEntry
    /// Leave out "Not on this Duo": the viewer has the PDF open.
    var hideNotOnThisDuo = false

    static func markers(_ model: DrawingIndexModel, _ entry: DrawingEntry, hideNotOnThisDuo: Bool) -> [DrawingMarker] {
        DrawingMarker.of(entry, online: model.online, pdfsOnThisDuo: model.pdfsOnThisDuo,
                         pdfPathsOnThisDuo: model.pdfPathsOnThisDuo)
            .filter { !(hideNotOnThisDuo && $0 == .notOnThisDuo) }
    }

    static func isEmpty(_ model: DrawingIndexModel, _ entry: DrawingEntry, hideNotOnThisDuo: Bool = false) -> Bool {
        markers(model, entry, hideNotOnThisDuo: hideNotOnThisDuo).isEmpty
            && !(entry.pdf != nil && model.plottedThisSession.contains(entry.id))
    }

    var body: some View {
        DrawingFlow(spacing: 4) {
            ForEach(Self.markers(model, entry, hideNotOnThisDuo: hideNotOnThisDuo), id: \.self) { marker in
                if marker == .noPDFYet {
                    PlotChip(stage: model.plots[entry.id]?.stage)
                } else {
                    DrawingMarkerChip(marker: marker)
                }
            }
            if entry.pdf != nil, model.plottedThisSession.contains(entry.id) {
                PlotChip(stage: .done)
            }
        }
    }
}

/// The banner that calls Zach back to a plot that came in while he was elsewhere (#70), over whichever tab is showing:
/// "E-201 is plotted and ready to view", View and a close button, as the prototype has it.
struct PlotBanner: View {
    let entry: DrawingEntry
    let view: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(DrawingIndexColors.ok)
            Text("\(Text(entry.number ?? entry.name).bold()) is plotted and ready to view")
                .font(.system(size: 13))
                .lineLimit(1)
            Button(action: view) { Text("View").bold() }
                .buttonStyle(ChromePrimaryButtonStyle())
                .font(.system(size: 13))
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 6))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: .separator)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plot-banner")
    }
}
