#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Made-up ink for measuring the renderer and the eraser (#21, docs/perf). Generated from a fixed seed, so every run,
/// on the Duo simulator or in a Linux test, has exactly the same strokes. Nothing in it comes from a real drawing.
public enum MadeUpInk {
    /// 10,000 strokes of notes, sketches and redlines scattered over a plant about 400 by 280 feet, at every scale
    /// from handwriting a couple of inches across to runs tens of feet long, about 80 points a stroke.
    public static func largeWalkdown(strokes count: Int = 10_000) -> Ink {
        var random = SeededRandom(state: 2_026_1101)
        var session = InkSession()
        let colours: [MarkupColour] = [.sketch, .sketch, .sketch, .red, .green, .blue]
        for _ in 0..<count {
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
        return session.ink
    }

    /// A small fixed random generator (a 64-bit LCG).
    public struct SeededRandom: Sendable {
        public var state: UInt64
        public init(state: UInt64) { self.state = state }
        public mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        public mutating func range(_ low: Double, _ high: Double) -> Double { low + next() * (high - low) }
    }
}
