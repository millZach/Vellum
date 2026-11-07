import Foundation

/// A made-up drawing index of any size (#68), for the search's timings and memory budget: projects of drawings with
/// numbers, titles, revisions and scales in the shapes the laptop indexer writes, and every marker case mixed in.
/// Every name is made up; it is the same on every run.
public enum MadeUpDrawingIndex {
    private static let disciplines = ["E", "M", "P", "I", "S", "A", "C", "FP"]
    private static let subjects = ["Boiler room", "Pump house", "Mechanical room", "Roof", "First floor", "Second floor",
                                   "Basement", "Tank farm", "Control room", "Switchgear room", "Cooling tower",
                                   "Loading dock", "Compressor house", "Water treatment", "Electrical room"]
    private static let kinds = ["power plan", "lighting plan", "HVAC plan", "piping plan", "one-line diagram",
                                "loop diagram", "details", "sections", "schedule", "layout", "grounding plan",
                                "conduit routing", "equipment plan", "elevations", "riser diagram"]
    private static let scales = ["1/4\" = 1'-0\"", "1/8\" = 1'-0\"", "1:20", "1:50", "NTS", "AS NOTED", "3/8\" = 1'-0\""]

    /// `count` entries across `projects` made-up projects, in shards' order.
    public static func shards(count: Int, projects: Int = 100) -> [DrawingIndexShard] {
        var shards: [DrawingIndexShard] = []
        let perProject = max(1, (count + projects - 1) / projects)
        var made = 0
        for p in 0..<projects where made < count {
            let project = "Made-up Project \(pad(String(p + 1), 3))"
            let projectPath = "/Projects/\(project)"
            var drawings: [DrawingEntry] = []
            for i in 0..<min(perProject, count - made) {
                let n = made + i
                let discipline = disciplines[n % disciplines.count]
                let number = "\(discipline)-\(100 + (n / disciplines.count) % 900)"
                let title = "\(subjects[(n / 3) % subjects.count]) \(kinds[(n / 7) % kinds.count])"
                let folder = "\(projectPath)/\(discipline)/CAD"
                let path = "\(folder)/\(number).dwg"
                let hash = pad(String(n, radix: 16), 64)
                let thumbnail = pad(String(n, radix: 16), 32) + ".png"
                var dwg: DrawingEntry.DWG? = DrawingEntry.DWG(path: path, size: 65215, modified: "2026-09-21T14:13:20Z")
                var pdf: DrawingEntry.PDF? = DrawingEntry.PDF(
                    path: "\(projectPath)/\(discipline)/PDF/\(number).pdf", size: 1184, modified: "2026-09-21T14:15:20Z",
                    contentHash: hash, pages: 1, paperInches: [36, 24])
                switch n % 20 {
                case 3: pdf = nil
                case 7: dwg = nil
                case 11: pdf?.read = false; pdf?.contentHash = nil; pdf?.pages = nil; pdf?.paperInches = nil
                default: break
                }
                drawings.append(DrawingEntry(
                    id: pad(String(n, radix: 16), 16) + "#layout1", path: dwg?.path ?? pdf!.path, name: "\(number).dwg",
                    layout: dwg == nil ? nil : "Layout1", folder: folder, project: project, projectPath: projectPath,
                    number: number, title: title, revision: String(n % 4), scale: scales[n % scales.count],
                    date: "2026-10-\(pad(String(1 + n % 28), 2))", fieldsFrom: "dwg", dwg: dwg, pdf: pdf,
                    otherPdfs: [], pairedBy: dwg != nil && pdf != nil ? "metadata" : nil, thumbnail: thumbnail))
            }
            made += drawings.count
            shards.append(DrawingIndexShard(project: project, projectPath: projectPath, drawings: drawings))
        }
        return shards
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// A shard's bytes as the laptop writes them: compact JSON, keys sorted.
    public static func bytes(of shard: DrawingIndexShard) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return [UInt8]((try? encoder.encode(shard)) ?? Data())
    }
}
