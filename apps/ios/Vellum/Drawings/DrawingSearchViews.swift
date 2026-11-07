import SwiftUI
import UIKit
import VellumCore

/// The Drawings tab's search (#68), as variant B of prototype/drawing-search has it: the search field, a line saying
/// what is searched, and the rows; unfolded, the list on the left and the picked drawing on the right; folded, the list
/// alone. Opening a drawing (the viewer, Place on a canvas, Open in a new canvas) is #69: until then a tap on the
/// unfolded screen picks the row and shows what the index says about it, and a tap folded does nothing.
struct DrawingSearchView: View {
    @Bindable var model: DrawingIndexModel
    let dropbox: DropboxConnection

    var body: some View {
        GeometryReader { proxy in
            let unfolded = proxy.size.width >= 700
            Group {
                if model.copyState == .ready {
                    if unfolded {
                        HStack(alignment: .top, spacing: 0) {
                            column(unfolded: true)
                                .frame(width: 372)
                                .padding(.leading, 16)
                            DrawingDetailPane(model: model)
                                .padding(EdgeInsets(top: 4, leading: 12, bottom: 14, trailing: 8))
                        }
                    } else {
                        column(unfolded: false).padding(.horizontal, 14)
                    }
                } else {
                    DrawingIndexEmptyState(model: model, dropbox: dropbox)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func column(unfolded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DrawingSearchField(text: $model.query)
                .padding(.trailing, unfolded ? 4 : 0)
            DrawingIndexLine(model: model)
                .padding(EdgeInsets(top: 6, leading: 2, bottom: 10, trailing: unfolded ? 4 : 2))
            if let notice = model.notice {
                DrawingNotice(text: notice) { model.notice = nil }
                    .padding(.bottom, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.results.isEmpty, !model.resultQuery.isEmpty {
                        Text("No drawing matches “\(model.resultQuery)”.\nTry a number like E-2, a word from the title, or the project.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element) { offset, index in
                                DrawingRow(model: model, entry: model.entry(index), unfolded: unfolded,
                                           separator: offset > 0)
                            }
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12))
                        if model.matchCount > model.results.count {
                            Text("Showing the first \(model.results.count) of \(model.matchCount). Type more to narrow it down.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.top, 8)
                        }
                    }
                    DrawingLegend().padding(.top, 12)
                    NavigationLink {
                        DropboxFoldersView(dropbox: dropbox).navigationTitle("Dropbox")
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").foregroundStyle(Color(red: 0.18, green: 0.5, blue: 0.88))
                            Text("Browse Dropbox folders").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 15))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.top, 12)
                }
                .padding(.trailing, unfolded ? 4 : 0)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await model.refresh() }
        }
    }
}

/// The search field: the prototype's rounded field with a magnifier and a clear button.
struct DrawingSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary)
            TextField("Number, title or project", text: $text)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 38)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// What is being searched: offline or not, how many drawings match, and when the laptop last wrote the index.
struct DrawingIndexLine: View {
    let model: DrawingIndexModel

    var body: some View {
        let count = model.resultQuery.isEmpty
            ? "\(model.total) drawings in the index"
            : "\(model.matchCount) of \(model.total) drawings match “\(model.resultQuery)”"
        let updated = model.updated.map { " · updated by the laptop \(Self.relative.localizedString(for: $0, relativeTo: Date()))" } ?? ""
        // One run of text, so it wraps as a sentence on the folded screen rather than being cut short.
        let offline = model.online
            ? Text("")
            : Text("\(Image(systemName: "wifi.slash")) Offline · searching the copy on this Duo · ")
                .fontWeight(.semibold).foregroundStyle(DrawingIndexColors.plot)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(offline)\(Text(count + updated).foregroundStyle(.secondary))")
                .fixedSize(horizontal: false, vertical: true)
            if model.refreshing { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 12))
        .lineLimit(3)
    }

    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// A newer format the laptop wrote, said once.
private struct DrawingNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(DrawingIndexColors.plot)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("OK", action: dismiss).font(.system(size: 12, weight: .semibold))
        }
        .padding(10)
        .background(DrawingIndexColors.plotBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One drawing: its thumbnail, number and title, rev, scale and date, project, and markers.
struct DrawingRow: View {
    let model: DrawingIndexModel
    let entry: DrawingEntry
    let unfolded: Bool
    let separator: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let text = DrawingRowText(entry)
        let query = model.resultQuery
        let selected = unfolded && model.selection == entry.id
        let markers = DrawingMarker.of(entry, online: model.online, pdfsOnThisDuo: model.pdfsOnThisDuo)
        let content = HStack(alignment: .center, spacing: 12) {
            DrawingThumbnailView(model: model, name: entry.thumbnail, width: unfolded ? 56 : 62, height: unfolded ? 38 : 42)
            VStack(alignment: .leading, spacing: 1) {
                headline(text, query)
                    .font(.system(size: unfolded ? 14 : 15))
                    .lineLimit(1)
                if let details = text.details {
                    Text(details).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(Self.highlighted(text.place, query, number: false))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
                if !markers.isEmpty {
                    DrawingFlow(spacing: 4) {
                        ForEach(markers, id: \.self) { DrawingMarkerChip(marker: $0) }
                    }
                    .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14))
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        .overlay(alignment: .top) {
            if separator {
                Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / displayScale)
                    .padding(.leading, unfolded ? 80 : 86)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)

        if unfolded {
            Button { model.selection = entry.id } label: { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            content
        }
    }

    private func headline(_ text: DrawingRowText, _ query: String) -> Text {
        if text.quiet {
            return Text(Self.highlighted(text.title, query, number: false)).foregroundStyle(.secondary)
        }
        guard let number = text.number else { return Text(Self.highlighted(text.title, query, number: false)) }
        var line = Self.highlighted(number, query, number: true)
        line.inlinePresentationIntent = .stronglyEmphasized
        line += AttributedString(" ") + Self.highlighted(text.title, query, number: false)
        return Text(line)
    }

    static func highlighted(_ text: String, _ query: String, number: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        for range in DrawingSearchText.highlights(in: text, query: query, number: number) {
            if let found = Range(range, in: attributed) {
                attributed[found].backgroundColor = DrawingIndexColors.highlight
            }
        }
        return attributed
    }
}

/// A marker, as the prototype's coloured chips.
struct DrawingMarkerChip: View {
    let marker: DrawingMarker

    var body: some View {
        let (icon, colour, background): (String, Color, Color) = switch marker {
        case .noPDFYet: ("laptopcomputer", DrawingIndexColors.plot, DrawingIndexColors.plotBackground)
        case .pdfOnly: ("doc", DrawingIndexColors.only, DrawingIndexColors.onlyBackground)
        case .notReadYet: ("icloud", .secondary, DrawingIndexColors.quietBackground)
        case .notOnThisDuo: ("icloud.slash", .secondary, DrawingIndexColors.quietBackground)
        }
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(marker.text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(colour)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

/// The prototype's line under the list saying what the two drawing markers mean.
private struct DrawingLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                DrawingMarkerChip(marker: .noPDFYet)
                Text("a DWG nobody has plotted: the laptop plots it the first time you open it.")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                DrawingMarkerChip(marker: .pdfOnly)
                Text("a vendor or outside PDF with no DWG: mark it up, but it can't be redlined back to a DWG.")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }
}

/// A row's thumbnail, read (and downloaded, when the copy names it and the Duo is online) off the main thread.
struct DrawingThumbnailView: View {
    let model: DrawingIndexModel
    let name: String?
    let width: CGFloat
    let height: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: colorScheme == .dark ? UIColor(white: 0.15, alpha: 1) : .white)
            if let image {
                // The PDF's first page, ink on white; in dark mode it turns over as placed sheets do.
                Image(uiImage: image).resizable().scaledToFit()
                    .modifier(DarkInvert(dark: colorScheme == .dark))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(uiColor: .separator)))
        .accessibilityHidden(true)
        .task(id: "\(name ?? "")-\(model.online)") {
            guard let name, let keeper = model.keeper else { return }
            if let cached = DrawingThumbnails.shared.cached(name) {
                image = cached
                return
            }
            image = await DrawingThumbnails.shared.load(name, keeper: keeper, online: model.online)
        }
    }
}

private struct DarkInvert: ViewModifier {
    let dark: Bool
    func body(content: Content) -> some View {
        if dark { content.colorInvert() } else { content }
    }
}

/// Decoded thumbnails, kept while memory allows.
@MainActor
final class DrawingThumbnails {
    static let shared = DrawingThumbnails()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 600 }

    func cached(_ name: String) -> UIImage? { cache.object(forKey: name as NSString) }

    /// The thumbnail from the Duo, or downloaded first when it isn't here: after a moment's pause, so a row flung past
    /// downloads nothing (its task is cancelled).
    func load(_ name: String, keeper: DrawingIndexKeeper, online: Bool) async -> UIImage? {
        var url = await keeper.thumbnail(name, online: false)
        if url == nil, online {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return nil }
            url = await keeper.thumbnail(name, online: true)
        }
        guard let url, !Task.isCancelled else { return nil }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }.value
        if let image { cache.setObject(image, forKey: name as NSString) }
        return image
    }
}

/// The unfolded screen's right side: the picked drawing as the index has it, or a line asking to pick one.
struct DrawingDetailPane: View {
    let model: DrawingIndexModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground))
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color(uiColor: .separator))
            if let entry = model.selectedEntry {
                details(entry)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30))
                    Text("Pick a drawing to see it here").fontWeight(.semibold)
                    Text("Its number, title, scale and where its files are.").font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(30)
            }
        }
    }

    private func details(_ entry: DrawingEntry) -> some View {
        let text = DrawingRowText(entry)
        let markers = DrawingMarker.of(entry, online: model.online, pdfsOnThisDuo: model.pdfsOnThisDuo)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    DrawingThumbnailView(model: model, name: entry.thumbnail, width: 192, height: 128)
                    VStack(alignment: .leading, spacing: 4) {
                        if let number = text.number {
                            Text(number).font(.system(size: 22, weight: .bold))
                        }
                        Text(text.title).font(.system(size: 17)).foregroundStyle(text.quiet ? .secondary : .primary)
                        if let details = text.details { Text(details).font(.system(size: 13)).foregroundStyle(.secondary) }
                        if !markers.isEmpty {
                            DrawingFlow(spacing: 4) { ForEach(markers, id: \.self) { DrawingMarkerChip(marker: $0) } }
                                .padding(.top, 4)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let project = entry.project { field("Project", project) }
                    if let layout = entry.layout { field("Layout", layout) }
                    if let dwg = entry.dwg { field("DWG", dwg.path + (dwg.read ? "" : " (not read yet)")) }
                    if let pdf = entry.pdf {
                        field("PDF", pdf.path + (pdf.read ? "" : " (not read yet)"))
                        if let paper = pdf.paperInches, paper.count == 2 {
                            field("Paper", "\(Self.inches(paper[0])) × \(Self.inches(paper[1])) in"
                                  + (pdf.pages.map { $0 == 1 ? ", 1 page" : ", \($0) pages" } ?? ""))
                        }
                    }
                    if let others = entry.otherPdfs, !others.isEmpty {
                        field(others.count == 1 ? "Older plot" : "Older plots", others.joined(separator: "\n"))
                    }
                    if entry.dwg == nil && entry.pdf == nil { field("File", entry.path) }
                }
                .font(.system(size: 13))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func inches(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The states before there is a copy to search: getting it, none in Dropbox yet, offline with none, a newer format,
/// or Dropbox not answering.
struct DrawingIndexEmptyState: View {
    let model: DrawingIndexModel
    let dropbox: DropboxConnection

    var body: some View {
        if model.copyState == .loading || model.lastRefresh == nil || (model.refreshing && model.lastRefresh != .offline) {
            ProgressView("Getting the drawing index…")
        } else {
            switch model.lastRefresh ?? .failed {
            case .noIndex:
                ContentUnavailableView {
                    Label("No drawing index yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("The laptop indexer hasn't put one in Dropbox yet. Drawings show up here once it has run on the laptop.")
                } actions: {
                    Button("Check Again") { Task { await model.refresh() } }
                    browse
                }
            case .newerFormat(let format):
                ContentUnavailableView {
                    Label("Vellum needs an update", systemImage: "arrow.down.app")
                } description: {
                    Text("The laptop writes the drawing index in format \(format), newer than this Vellum reads. Install the latest Vellum to search it.")
                } actions: {
                    browse
                }
            case .offline:
                // Offline, with no copy on the Duo yet.
                ContentUnavailableView {
                    Label("No copy on this Duo yet", systemImage: "wifi.slash")
                } description: {
                    Text("You're offline. Vellum keeps a copy of the drawing index to search offline, and downloads it the first time the Duo is online.")
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
            default:
                ContentUnavailableView {
                    Label("Couldn't get the drawing index", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Dropbox didn't answer, or sent something that isn't the index.")
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                    browse
                }
            }
        }
    }

    private var browse: some View {
        NavigationLink("Browse Dropbox folders") {
            DropboxFoldersView(dropbox: dropbox).navigationTitle("Dropbox")
        }
    }
}

/// The prototype's colours for the markers and the search highlight, light and dark.
enum DrawingIndexColors {
    static let plot = dynamic(light: 0x9a5b00, dark: 0xe0a458)
    static let plotBackground = dynamic(light: 0xf7ebd7, dark: 0xe0a458, darkAlpha: 0.15)
    static let only = dynamic(light: 0x6b3fa8, dark: 0xc4a2f0)
    static let onlyBackground = dynamic(light: 0xefe7f8, dark: 0xc4a2f0, darkAlpha: 0.15)
    static let quietBackground = dynamic(light: 0xeee8dc, dark: 0x3a3b40)
    static let highlight = dynamic(light: 0xfde68a, dark: 0xfde68a, darkAlpha: 0.32)

    private static func dynamic(light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? colour(dark, alpha: darkAlpha) : colour(light, alpha: 1)
        })
    }

    private static func colour(_ hex: UInt32, alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// Lays its children out in rows, wrapping when a row is full: the markers under a row.
struct DrawingFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
