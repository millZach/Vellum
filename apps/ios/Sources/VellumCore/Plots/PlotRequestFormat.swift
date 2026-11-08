import Foundation

/// Plot request format 1, the Duo's side (#70, ADR-0018, `docs/plot-requests.md`): the request file the Duo writes to
/// `Dropbox/Vellum/Plots/requests`, the answer the laptop indexer writes beside it, and the laptop's check-in. The Duo
/// writes only requests, only in that folder, and deletes only its own requests; it never writes or deletes an answer.
public enum PlotRequestFormat {
    /// The one format this Vellum writes and reads.
    public static let format = 1
    /// `Dropbox/Vellum/Plots`, where the laptop keeps its plots and its check-in.
    public static let folder = SyncPaths.root + "/Plots"
    /// `Dropbox/Vellum/Plots/requests`: the only folder the Duo writes to for a plot.
    public static let requestsFolder = folder + "/requests"
    /// The laptop's check-in.
    public static let checkInPath = folder + "/laptop.json"
    /// The laptop is off, and an open request shows "Waiting for the laptop", once its check-in is older than this by
    /// Dropbox's `server_modified` (`docs/plot-requests.md`, "The staleness rule for the Duo"): two of its 2-minute
    /// intervals and a minute for Dropbox to sync. The one place the Duo holds the limit, since Zach may change it.
    public static let staleAfter: TimeInterval = 300
    /// The most a request may be; the laptop refuses a bigger one.
    public static let maxRequestBytes = 4096
    static let answerSuffix = ".answer.json"

    /// A request's Dropbox path: `requests/<its id>.json`.
    public static func requestPath(_ request: String) -> String { "\(requestsFolder)/\(request).json" }
    /// Its answer's Dropbox path: `requests/<its id>.answer.json`.
    public static func answerPath(_ request: String) -> String { "\(requestsFolder)/\(request)\(answerSuffix)" }

    /// Whether the Duo may write or delete `path`: a request's file directly in `requests/`, never an answer, a temp
    /// file or anything elsewhere. Every upload and delete the Duo makes for a plot is checked here first.
    public static func isRequestPath(_ path: String) -> Bool {
        let prefix = requestsFolder + "/"
        guard path.hasPrefix(prefix) else { return false }
        let name = String(path.dropFirst(prefix.count))
        guard name.hasSuffix(".json"), !name.hasSuffix(answerSuffix) else { return false }
        return isRequestID(String(name.dropLast(".json".count)))
    }

    /// The laptop's rule for a request's name, less `.json`: 8 to 64 letters, digits and hyphens, starting with a letter
    /// or digit. A UUID's string is 36 of them.
    public static func isRequestID(_ id: String) -> Bool {
        let units = Array(id.utf8)
        guard (8...64).contains(units.count) else { return false }
        func ok(_ unit: UInt8) -> Bool {
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
        }
        return ok(units[0]) && units.allSatisfy { ok($0) || $0 == 0x2D }
    }

    /// A time as the format writes it: UTC, `YYYY-MM-DDTHH:MM:SSZ`.
    public static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// A time the format wrote, or Dropbox's `server_modified`; nil when it isn't one.
    public static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// One plot request, as the Duo writes it once and never changes it (`files/upload`, mode `add`).
public struct PlotRequest: Codable, Hashable, Sendable {
    /// Its own id, a fresh random UUID per ask, which names its file, so two Duos or two taps never write one file.
    public var request: String
    /// The drawing index entry's `id`.
    public var id: String
    /// The entry's `dwg.path`.
    public var path: String
    /// The entry's `layout`, or nil for a DWG whose title blocks are not read yet.
    public var layout: String?
    /// When Zach asked, on the Duo's clock.
    public var asked: Date

    public init(request: String, id: String, path: String, layout: String?, asked: Date) {
        self.request = request
        self.id = id
        self.path = path
        self.layout = layout
        self.asked = asked
    }

    /// A request for `entry`'s DWG with a fresh id, or nil for an entry with no DWG.
    public static func asking(for entry: DrawingEntry, at asked: Date, id: UUID = UUID()) -> PlotRequest? {
        guard let dwg = entry.dwg else { return nil }
        // Seconds only, as the format writes the time, so the ledger keeps exactly what was sent.
        let whole = Date(timeIntervalSince1970: asked.timeIntervalSince1970.rounded(.down))
        return PlotRequest(request: id.uuidString, id: entry.id, path: dwg.path, layout: entry.layout, asked: whole)
    }

    /// Its file's Dropbox path.
    public var dropboxPath: String { PlotRequestFormat.requestPath(request) }

    /// Its file's bytes: format 1's keys in the documented order, one space of indent, UTF-8, as the example in
    /// `docs/plot-requests.md` is written.
    public var bytes: [UInt8] {
        let layoutText = layout.map(Self.quoted) ?? "null"
        let text = "{\n \"format\": \(PlotRequestFormat.format),\n \"id\": \(Self.quoted(id)),\n"
            + " \"path\": \(Self.quoted(path)),\n \"layout\": \(layoutText),\n"
            + " \"asked\": \(Self.quoted(PlotRequestFormat.time(asked)))\n}\n"
        return Array(text.utf8)
    }

    /// A JSON string: quotes, backslashes and control characters escaped, everything else as it is (slashes too).
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// The laptop's answer to a request, `requests/<request>.answer.json`, rewritten whole as its state moves on. Keys the
/// Duo does not know are ignored.
public struct PlotAnswer: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case queued, plotting, done, failed
    }

    public var request: String?
    public var id: String?
    public var state: State
    public var updated: String?
    /// On `done`: the PDF's Dropbox path and its Dropbox content hash.
    public var pdf: String?
    public var contentHash: String?
    /// On `done`: `saved`, or `fallback` when plotted with DWG To PDF at its paper size.
    public var pageSetup: String?
    /// On `failed`, why, to show as it is; on a `fallback` `done`, a sentence saying so.
    public var reason: String?
    public var missingReferences: Int?
    /// On `done` with references missing, a sentence to show as it is.
    public var warning: String?
    /// On `done`, from a laptop on 1.1.2 or later: true for a plot fitted to the page, not to scale (a Model-tab DWG's
    /// fallback, #92), which the Duo places as an NTS sheet. Nil from an older laptop.
    public var fitted: Bool?

    public init(request: String?, id: String?, state: State, updated: String? = nil, pdf: String? = nil,
                contentHash: String? = nil, pageSetup: String? = nil, reason: String? = nil,
                missingReferences: Int? = nil, warning: String? = nil, fitted: Bool? = nil) {
        self.request = request
        self.id = id
        self.state = state
        self.updated = updated
        self.pdf = pdf
        self.contentHash = contentHash
        self.pageSetup = pageSetup
        self.reason = reason
        self.missingReferences = missingReferences
        self.warning = warning
        self.fitted = fitted
    }

    /// Reads an answer; nil for one that is not format 1's shape (a state this Vellum doesn't know among them), which
    /// the Duo treats as no answer yet and keeps looking.
    public static func read(_ bytes: [UInt8]) -> PlotAnswer? {
        struct Format: Decodable { let format: Int? }
        let data = Data(bytes)
        guard let format = try? JSONDecoder().decode(Format.self, from: data), format.format == PlotRequestFormat.format,
              let answer = try? JSONDecoder().decode(PlotAnswer.self, from: data) else { return nil }
        return answer
    }

    /// `done` or `failed`: it will not change, and the Duo deletes its request once it has read it.
    public var isFinal: Bool { state == .done || state == .failed }

    /// A `done` plot fitted to the page, not to scale (#92).
    public var isFitted: Bool { state == .done && fitted == true }

    /// The viewer's line for a plot fitted to the page, in place of the fallback line (#92, Zach's words).
    public static let fittedNote = "Plotted to fit, not to scale"

    /// The one short line the viewer shows under a plot that came with something to know: the laptop's warning about
    /// missing references, and its sentence about plotting with the fallback page setup, or for a plot fitted to the
    /// page, "Plotted to fit, not to scale" in its place.
    public var note: String? {
        var parts: [String] = []
        if state == .done, let warning, !warning.isEmpty { parts.append(Self.sentence(warning)) }
        if isFitted {
            parts.append(Self.fittedNote)
        } else if state == .done, pageSetup == "fallback" {
            parts.append(Self.sentence(reason ?? "Plotted with DWG To PDF at its paper size, not its own page setup"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The laptop's words as a sentence: a capital first, a full stop last.
    public static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        let capital = first.uppercased() + trimmed.dropFirst()
        return capital.hasSuffix(".") || capital.hasSuffix("!") || capital.hasSuffix("?") ? capital : capital + "."
    }
}
