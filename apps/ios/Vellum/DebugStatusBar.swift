#if DEBUG
import SwiftUI
import UIKit
import VellumCore

/// Debug-only launch arguments for the status bar's room (#45), on the fixture, with the pen's position at the longest
/// under 100' so the usual width is full. The captures launch with `--ui-reset`, so what this changes doesn't last.
///
/// - `--ui-status-hold <prompt>,<units>,<points per inch>`: holds that prompt (`line`, `dimension`, `sheet`, or `centre`, the
///   longest of the shapes' at 27 characters, #40) at that zoom, for a capture.
/// - `--ui-status-walk`: walks every scale label in every units with each prompt, then the feet-and-inches labels again
///   with the longest position, and writes `status-bar-walk.txt` to Documents: one tab-separated line for each, ending
///   in the count wording that showed (`full`, `short` or `shortest`) and the bar's width in points.
///   `Scripts/status-bar-check.py` reads it.
@MainActor
enum DebugStatusBar {
    /// The width the count came out at. `ViewThatFits` takes the size of the wording it shows, so this says which.
    static var countWidth: CGFloat = 0
    /// The width the whole bar came out at. It has a set room, so anything else means something pushed it wider.
    static var barWidth: CGFloat = 0
    static let isWalking = DebugLaunch.has("--ui-status-walk")
    private static var started = false

    private enum Prompt: String {
        case line, dimension, sheet, centre

        /// What the walk holds the count to, as `Scripts/status-bar-check.py` expects.
        static let walked: [Prompt] = [.line, .dimension, .sheet]

        @MainActor func show(in editor: CanvasEditor) {
            editor.tool = self == .dimension ? .dimension : .lineAndShape
            editor.lineShape = self == .centre ? .circle : .drawIt
            editor.toolStep = self == .sheet ? .placeSheet : .start
        }

        var text: String {
            switch self {
            case .line: CanvasTool.lineAndShape.prompt
            case .dimension: CanvasTool.dimension.prompt
            case .sheet: CanvasTool.placeSheetPrompt
            case .centre: LineShape.circle.prompt
            }
        }
    }

    static func attach(_ view: InkCanvasUIView, editor: CanvasEditor) {
        let hold = DebugLaunch.argument("--ui-status-hold")
        guard hold != nil || isWalking, !started, view.bounds.width > 0 else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            editor.penPosition = position(feet: 99)
            if let hold { self.hold(hold, view, editor) } else { await walk(view, editor) }
        }
    }

    private static func position(feet: Double) -> CanvasPoint {
        let inches = -(feet * 12 + 11 + 15.0 / 16)
        return CanvasPoint(x: .inches(inches), y: .inches(-inches))
    }

    private static func zoom(to pointsPerInch: Double, _ view: InkCanvasUIView, _ editor: CanvasEditor) {
        editor.viewport = Viewport(centre: editor.viewport.centre, pointsPerInch: pointsPerInch,
                                   screenWidth: editor.viewport.screenWidth, screenHeight: editor.viewport.screenHeight)
        view.viewportJumped()
    }

    private static func hold(_ argument: String, _ view: InkCanvasUIView, _ editor: CanvasEditor) {
        let parts = argument.split(separator: ",").map(String.init)
        guard parts.count == 3, let prompt = Prompt(rawValue: parts[0]), let units = CanvasUnits(rawValue: parts[1]),
              let pointsPerInch = Double(parts[2]) else { return }
        editor.units = units
        zoom(to: pointsPerInch, view, editor)
        prompt.show(in: editor)
    }

    /// One zoom for each scale label in these units.
    private static func zooms(_ units: CanvasUnits) -> [Double] {
        var zooms: [Double] = []
        var last: String?
        var pointsPerInch = Viewport.minimumPointsPerInch
        while pointsPerInch <= Viewport.maximumPointsPerInch {
            let label = ScaleBar.mark(fitting: StatusBarText.scaleBarLongest, pointsPerInch: pointsPerInch, units: units).label
            if label != last { zooms.append(pointsPerInch) }
            last = label
            pointsPerInch *= 1.05
        }
        return zooms
    }

    private static func walk(_ view: InkCanvasUIView, _ editor: CanvasEditor) async {
        var lines: [String] = []
        for units in CanvasUnits.allCases { lines += await pass(units, position: "usual", view, editor) }
        editor.penPosition = position(feet: 139)
        try? await Task.sleep(for: .milliseconds(200))
        lines += await pass(.feetAndInches, position: "long", view, editor)
        lines.append("done")
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("status-bar-walk.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private static func pass(_ units: CanvasUnits, position name: String, _ view: InkCanvasUIView,
                             _ editor: CanvasEditor) async -> [String] {
        var lines: [String] = []
        editor.units = units
        for pointsPerInch in zooms(units) {
            zoom(to: pointsPerInch, view, editor)
            let label = ScaleBar.mark(fitting: StatusBarText.scaleBarLongest, pointsPerInch: pointsPerInch, units: units).label
            for prompt in Prompt.walked {
                prompt.show(in: editor)
                try? await Task.sleep(for: .milliseconds(200))
                lines.append([units.rawValue, name, prompt.text, label, wording(editor),
                              String(format: "%.1f", barWidth)].joined(separator: "\t"))
            }
        }
        return lines
    }

    /// Which of the count's wordings has the width it came out at.
    private static func wording(_ editor: CanvasEditor) -> String {
        let font = UIFont.systemFont(ofSize: 12)
        let widths = StatusBarText.counts(sheets: editor.canvas.sheets.count, frames: editor.frameCount).map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        let nearest = widths.indices.min { abs(widths[$0] - countWidth) < abs(widths[$1] - countWidth) } ?? 0
        return ["full", "short", "shortest"][nearest]
    }
}

extension View {
    /// Tells the walk how wide the count came out; only while walking, so it costs nothing otherwise.
    @MainActor @ViewBuilder func debugReportsCountWidth() -> some View {
        if DebugStatusBar.isWalking {
            onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                MainActor.assumeIsolated { DebugStatusBar.countWidth = width }
            }
        } else {
            self
        }
    }

    /// Tells the walk how wide the whole bar came out; only while walking.
    @MainActor @ViewBuilder func debugReportsStatusBarWidth() -> some View {
        if DebugStatusBar.isWalking {
            onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                MainActor.assumeIsolated { DebugStatusBar.barWidth = width }
            }
        } else {
            self
        }
    }
}
#endif
