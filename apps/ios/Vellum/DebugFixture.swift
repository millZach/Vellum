#if DEBUG
import Foundation
import VellumCore

/// A made-up canvas for the simulator captures and previews: a sketched pipe run with a pump and a valve, marked up in
/// all four markup colours. Debug builds open it with `--ui-fixture`; `--ui-zoom closeup` opens it close up on the
/// valve instead of on everything. Nothing here comes from a real drawing.
enum DebugFixture {
    /// The valve the close-up shows, about 2 feet across.
    static let valveRegion = CanvasRect(origin: CanvasPoint(x: .feet(28), y: .feet(9)),
                                        size: CanvasSize(width: .feet(2.5), height: .feet(2)))

    static var canvas: VellumCore.Canvas {
        VellumCore.Canvas(name: name, ink: session.ink)
    }

    static let name = "Boiler 4 walkdown (example)"

    /// The fixture's ink as drawn, its changes not yet taken for saving.
    static var session: InkSession {
        var session = InkSession()
        let plantWidth = Length.inches(3)    // ink drawn zoomed out on the whole run
        let closeWidth = Length.inches(0.3)  // ink drawn close up on the valve

        // Sketch: a pipe run from a pump, through a valve, to a tank.
        session.draw(polyline((4, 10), (28.4, 10)), tool: .pen, colour: .sketch, width: plantWidth)
        session.draw(polyline((30.1, 10), (54, 10), (54, 4)), tool: .pen, colour: .sketch, width: plantWidth)
        session.draw(circle(centre: (2, 10), radius: 2), tool: .pen, colour: .sketch, width: plantWidth)
        session.draw(polyline((50, 4), (58, 4), (58, -6), (50, -6), (50, 4)), tool: .pen, colour: .sketch, width: plantWidth)
        // The valve, a bow tie, drawn close up.
        session.draw(polyline((28.4, 9.5), (30.1, 10.5), (30.1, 9.5), (28.4, 10.5), (28.4, 9.5)),
                     tool: .pen, colour: .sketch, width: closeWidth)
        session.draw(polyline((29.25, 10), (29.25, 9.2)), tool: .pen, colour: .sketch, width: closeWidth)
        session.draw(polyline((28.95, 9.2), (29.55, 9.2)), tool: .pen, colour: .sketch, width: closeWidth)

        // Red, to add: a bypass around the valve, clouded.
        session.draw(polyline((26, 10), (26, 14), (32.5, 14), (32.5, 10)), tool: .pen, colour: .red, width: plantWidth)
        session.draw(cloud(centre: (29.25, 12), width: 10, height: 7), tool: .pen, colour: .red, width: plantWidth)
        // Red close up: a small vent valve on the valve body.
        session.draw(polyline((29.9, 10.5), (29.9, 10.9), (30.2, 10.9)), tool: .pen, colour: .red, width: closeWidth)

        // Green, to delete: the old branch, crossed out.
        session.draw(polyline((40, 10), (40, 17)), tool: .pen, colour: .sketch, width: plantWidth)
        session.draw(polyline((38, 13), (42, 17)), tool: .pen, colour: .green, width: plantWidth)
        session.draw(polyline((42, 13), (38, 17)), tool: .pen, colour: .green, width: plantWidth)

        // Blue, a note: a leader to the tank and a wavy line standing for handwriting.
        session.draw(polyline((58, -6), (63, -10), (66, -10)), tool: .pen, colour: .blue, width: plantWidth)
        session.draw(wave(from: (66.5, -10.4), length: 12, height: 0.6, waves: 9), tool: .pen, colour: .blue, width: plantWidth)
        // Blue close up: a note on the valve.
        session.draw(wave(from: (28.3, 8.9), length: 1.1, height: 0.06, waves: 7), tool: .pen, colour: .blue, width: closeWidth)

        // Highlighter over the pump.
        session.draw(polyline((-1, 10), (5, 10)), tool: .highlighter, colour: .blue, width: .inches(14))

        return session
    }

    /// The stroke left open in the kill-and-reopen capture: a red line Zach is still drawing when the app is killed.
    static var openStroke: StrokeInProgress {
        var stroke = StrokeInProgress(tool: .pen, colour: .red, width: .inches(3), start: point((44, 6)))
        for p in polyline((46, 4), (48, 6), (50, 8)) { stroke.add(p) }
        return stroke
    }

    // Points in feet.
    private static func point(_ p: (Double, Double)) -> CanvasPoint { CanvasPoint(x: .feet(p.0), y: .feet(p.1)) }

    private static func polyline(_ points: (Double, Double)...) -> [CanvasPoint] { points.map(point) }

    private static func circle(centre: (Double, Double), radius: Double) -> [CanvasPoint] {
        (0...32).map { i in
            let a = Double(i) / 32 * 2 * Double.pi
            return point((centre.0 + radius * cos(a), centre.1 + radius * sin(a)))
        }
    }

    private static func cloud(centre: (Double, Double), width: Double, height: Double) -> [CanvasPoint] {
        (0...60).map { i in
            let a = Double(i) / 60 * 2 * Double.pi
            let bump = 1 + 0.06 * abs(sin(a * 7))
            return point((centre.0 + cos(a) * width / 2 * bump, centre.1 + sin(a) * height / 2 * bump))
        }
    }

    private static func wave(from start: (Double, Double), length: Double, height: Double, waves: Int) -> [CanvasPoint] {
        let steps = waves * 8
        return (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return point((start.0 + t * length, start.1 + height * sin(t * Double(waves) * 2 * Double.pi)))
        }
    }
}

/// Debug-only launch arguments for the simulator captures. None of them exist in a TestFlight build.
///
/// - `--ui-reset`: delete every canvas on the simulator first.
/// - `--ui-fixture` (with `--ui-zoom closeup`): save the fixture canvas and open it on everything (or its valve).
/// - `--ui-new-canvas`: make an empty canvas and open it.
/// - `--ui-seed-list`: save a few made-up canvases and show the Canvases list.
/// - `--ui-draw-fixture`: make a canvas and draw the fixture into it stroke by stroke through the canvas screen, the way
///   the Pencil commits strokes, then leave one stroke open, for the capture that kills the app and reopens it.
@MainActor
enum DebugLaunch {
    static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    /// Runs the debug launch arguments. Returns true when they opened what the app shows, so normal launch is skipped.
    /// Their file work runs off the main thread, like the app's.
    static func run(_ model: CanvasesModel) async -> Bool {
        if has("--ui-reset") {
            await Task.detached {
                if let root = try? CanvasLibrary.onThisDevice().root { try? FileManager.default.removeItem(at: root) }
                try? FileManager.default.removeItem(at: CanvasPreviews.folder)
            }.value
            model.lastOpened = nil
        }
        await model.prepare()
        guard let library = model.library else { return false }
        if has("--ui-fixture") {
            let fixture = DebugFixture.session
            guard let id = await Task.detached(operation: { save(fixture, named: DebugFixture.name, in: library) }).value
            else { return false }
            await model.refresh()
            let closeUp = argument("--ui-zoom") == "closeup"
            await model.open(id, startingView: closeUp ? .region(DebugFixture.valveRegion) : .everything)
            model.finishLaunch()
            return true
        }
        if has("--ui-new-canvas") {
            await model.newCanvas()
            model.finishLaunch()
            return true
        }
        if has("--ui-seed-list") {
            let full = DebugFixture.session
            await Task.detached { seedList(full, in: library) }.value
            await model.refresh()
            model.finishLaunch()
            return true
        }
        if has("--ui-draw-fixture") {
            guard let made = await Task.detached(operation: { try? library.create(name: "Kill test (example)") }).value
            else { return false }
            await model.refresh()
            let extents = DebugFixture.canvas.extents ?? CanvasRect(origin: .origin, size: CanvasSize(width: .feet(10), height: .feet(10)))
            await model.open(made.id, startingView: .region(extents))
            model.finishLaunch()
            guard let editor = model.openEditor else { return true }
            try? await Task.sleep(for: .seconds(1))
            for stroke in DebugFixture.session.ink.strokes {
                var live = StrokeInProgress(tool: stroke.tool, colour: stroke.colour, width: stroke.width, start: stroke.points[0])
                for p in stroke.points.dropFirst() { live.add(p) }
                editor.commit(live)
                try? await Task.sleep(for: .milliseconds(120))
            }
            editor.showDebugOpenStroke(DebugFixture.openStroke)
            return true
        }
        return false
    }

    /// Saves a session's ink as a new canvas, with its thumbnail. Returns its id. Off the main thread.
    nonisolated private static func save(_ session: InkSession, named name: String, in library: CanvasLibrary) -> UUID? {
        var session = session
        guard let made = try? library.create(name: name), let store = try? library.openInk(made.id) else { return nil }
        try? store.append(session.takeEvents())
        try? store.flush()
        CanvasPreviews.write(for: made.id, ink: store.session.ink, version: store.savedVersion)
        store.closeFiles()
        return made.id
    }

    /// A few made-up canvases for the list capture: the fixture, and pieces of it under other names. Off the main
    /// thread.
    nonisolated private static func seedList(_ full: InkSession, in library: CanvasLibrary) {
        let names = ["Site visit notes (example)", "Panel 12 redline (example)", "Feedwater bypass sketch (example)"]
        for (i, name) in names.enumerated() {
            var part = InkSession()
            for stroke in full.ink.strokes.enumerated().filter({ $0.offset % (i + 2) == 0 }).map(\.element) {
                part.draw(stroke.points, tool: stroke.tool, colour: stroke.colour, width: stroke.width)
            }
            _ = save(part, named: name, in: library)
        }
        _ = save(full, named: DebugFixture.name, in: library)
    }
}
#endif
