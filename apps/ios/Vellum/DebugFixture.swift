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

        return VellumCore.Canvas(name: "Boiler 4 walkdown (example)", ink: session.ink)
    }

    /// A made-up canvas of 10,000 strokes for measuring the renderer (#21), opened with `--ui-fixture-large`: notes,
    /// sketches and redlines scattered over a plant about 400 by 280 feet, at every scale from handwriting an inch
    /// high to runs tens of feet long, about 80 points a stroke. Generated from a fixed seed, so every run draws the
    /// same canvas; nothing in it comes from a real drawing.
    static var largeCanvas: VellumCore.Canvas {
        var random = SeededRandom(state: 2_026_1101)
        var session = InkSession()
        let colours: [MarkupColour] = [.sketch, .sketch, .sketch, .red, .green, .blue]
        for _ in 0..<10_000 {
            // Where on the plant, and how big: mostly handwriting and small sketches, some long redlines.
            let roll = random.next()
            let size = roll < 0.6 ? random.range(2, 18) : roll < 0.92 ? random.range(18, 120) : random.range(120, 600)
            let pointCount = 20 + Int(random.next() * 120)
            var x = random.range(-2_400, 2_400), y = random.range(-1_680, 1_680)
            var heading = random.range(0, 2 * Double.pi)
            let step = size / Double(pointCount) * 2
            var points: [CanvasPoint] = []
            points.reserveCapacity(pointCount)
            for _ in 0..<pointCount {
                points.append(CanvasPoint(x: .inches(x), y: .inches(y)))
                heading += random.range(-0.6, 0.6)
                x += cos(heading) * step
                y += sin(heading) * step
            }
            let highlighter = random.next() < 0.04
            // Widths as a pen draws them: the screen weight at a zoom where the stroke is a comfortable size.
            let width = highlighter ? size * 0.25 : size * random.range(0.01, 0.04)
            session.draw(points, tool: highlighter ? .highlighter : .pen,
                         colour: colours[Int(random.next() * Double(colours.count))], width: .inches(width))
        }
        return VellumCore.Canvas(name: "Large walkdown (made up)", ink: session.ink)
    }

    /// A small fixed random generator, so the large fixture is the same on every launch.
    private struct SeededRandom {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ low: Double, _ high: Double) -> Double { low + next() * (high - low) }
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
#endif
