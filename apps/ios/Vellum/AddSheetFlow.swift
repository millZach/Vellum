import AuthenticationServices
import SwiftUI
import VellumCore

/// Add sheet (#11), as Zach picked it from the prototype at `prototype/place-sheets`: Dropbox's folders down to a PDF,
/// a grid of a PDF's pages each captioned with its sheet number and the scale read (question 1, A), then a confirm
/// step that names the scale read and what the sheet will cover, or asks for one (AS NOTED, no scale, a scan, several
/// scales); for AS NOTED the details at other scales show as scale areas (question 2, C). Place sheet hands the sheet
/// to the canvas, which waits for a tap where it goes (question 3, C).
///
/// Every PDF is downloaded once (`SheetPDFs`), and read and drawn off the main thread (`SheetPDFReader`).
@MainActor
@Observable
final class AddSheetModel {
    enum Step: Hashable {
        /// A Dropbox folder, by path.
        case folder(String)
        /// A PDF's pages.
        case pages(DropboxFile)
        /// A page to confirm.
        case confirm(DropboxFile, page: Int)
    }

    var path: [Step] = []
    let dropbox: DropboxConnection
    private(set) var contents: [String: DropboxFolderContents] = [:]
    private(set) var problem: String?
    /// The PDF being downloaded, by id.
    private(set) var downloading: String?
    @ObservationIgnored private var readers: [String: SheetPDFReader] = [:]
    @ObservationIgnored private var urls: [String: URL] = [:]
    private(set) var pageCounts: [String: Int] = [:]
    private let pdfs: SheetPDFs?
    /// What a sheet will cover on the canvas, in its units.
    let covers: (Sheet) -> String
    let units: CanvasUnits
    /// Called with the confirmed sheet.
    @ObservationIgnored var onPlace: ((CanvasEditor.PendingSheet) -> Void)?
    /// Closes Add sheet, from any step.
    @ObservationIgnored var close: (() -> Void)?

    init(dropbox: DropboxConnection, units: CanvasUnits, covers: @escaping (Sheet) -> String) {
        self.dropbox = dropbox
        self.units = units
        self.covers = covers
        pdfs = try? SheetPDFs.inCaches()
    }

    /// Lists a folder's folders and PDFs; kept, so going back shows it at once.
    func load(_ folder: String) async {
        problem = nil
        do {
            contents[folder] = try await dropbox.contents(of: folder)
        } catch {
            problem = (error as? DropboxError)?.message ?? "Dropbox couldn't be reached."
        }
    }

    /// Downloads a PDF once, then opens its pages, or the confirm step for a one-page PDF.
    func open(_ file: DropboxFile) async {
        guard downloading == nil else { return }
        problem = nil
        downloading = file.id
        defer { downloading = nil }
        guard let reader = await reader(for: file) else { return }
        let count = await reader.pageCount
        pageCounts[file.id] = count
        guard count > 0 else {
            problem = "Vellum couldn't read \(file.name) as a PDF."
            return
        }
        path.append(count == 1 ? .confirm(file, page: 0) : .pages(file))
    }

    /// The PDF's reader, once it is on the Duo.
    func reader(for file: DropboxFile) async -> SheetPDFReader? {
        if let reader = readers[file.id] { return reader }
        guard let pdfs, let session = dropbox.downloads else {
            problem = DropboxError.notSetUp.message
            return nil
        }
        do {
            let url = try await pdfs.pdf(for: file) { try await session.download(file) }
            let reader = SheetPDFReader(url: url)
            readers[file.id] = reader
            urls[file.id] = url
            return reader
        } catch let error as DropboxError {
            problem = error.message
        } catch {
            problem = "The PDF couldn't be kept on this Duo. \(error.localizedDescription)"
        }
        return nil
    }

    /// Hands a confirmed page to the canvas as a sheet waiting to be placed: its scale, its scale areas for the scale
    /// chosen, and whether it dims in dark mode, worked out off the main thread.
    func place(_ file: DropboxFile, page: Int, info: SheetPDFReader.PageInfo, scale: Sheet.Scale) async {
        guard let reader = readers[file.id], let url = urls[file.id] else { return }
        let invertsBadly = await reader.invertsBadly(page: page)
        let sheet = Sheet(paper: info.paper, scale: scale,
                          page: SheetPage(file: file.keptName, name: file.name, path: file.path, index: page,
                                          number: info.reading.sheetNumber),
                          areas: info.reading.areas(placedAt: scale), invertsBadly: invertsBadly)
        onPlace?(CanvasEditor.PendingSheet(sheet: sheet, pdf: url, keptName: file.keptName))
    }

    /// The scales the confirm step offers to pick: the ones written on the sheet's details first, then the common
    /// ones for the canvas units, and NTS.
    func offeredScales(for reading: SheetReading) -> [Sheet.Scale] {
        let common: [DrawingScale]
        switch units {
        case .metric:
            common = [1, 5, 10, 20, 50, 100, 200, 500].map { DrawingScale.ratio(Double($0)) }
        case .feetAndInches, .decimalFeet:
            common = [0.0625, 0.125, 0.1875, 0.25, 0.375, 0.5, 0.75, 1, 1.5, 3].map {
                DrawingScale.architectural(inchesPerFoot: $0)
            } + [10, 20, 30, 40, 50, 60, 100].map { DrawingScale.engineering(feetPerInch: Double($0)) }
        }
        var offered = reading.detailScales
        for scale in common.map(Sheet.Scale.drawn) + [.notToScale] where !offered.contains(scale) { offered.append(scale) }
        return offered
    }

    #if DEBUG
    /// Opens a folder, a PDF and a page in turn, for the captures, through the same steps a tap takes.
    func debugGo(to folder: String, file name: String?, page: Int?) async {
        path = [.folder(folder)]
        await load(folder)
        guard let name, let file = contents[folder]?.pdfs.first(where: { $0.name == name }) else { return }
        await open(file)
        if let page, (pageCounts[file.id] ?? 0) > 1 { path.append(.confirm(file, page: page)) }
    }
    #endif
}

/// One Add sheet at a time is presented, by identity.
extension AddSheetModel: Identifiable {}

/// The Add sheet sheet: a navigation stack from the top of Dropbox.
struct AddSheetFlow: View {
    @Bindable var model: AddSheetModel

    var body: some View {
        NavigationStack(path: $model.path) {
            DropboxFolderList(model: model, folder: "")
                .navigationDestination(for: AddSheetModel.Step.self) { step in
                    switch step {
                    case .folder(let folder): DropboxFolderList(model: model, folder: folder)
                    case .pages(let file): PageGrid(model: model, file: file)
                    case .confirm(let file, let page): ConfirmSheet(model: model, file: file, page: page)
                    }
                }
        }
        .tint(Chrome.accent)
    }
}

/// One Dropbox folder: its folders, then its PDFs. Tapping a PDF downloads it, once.
private struct DropboxFolderList: View {
    let model: AddSheetModel
    let folder: String
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        List {
            if let problem = model.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    if !model.dropbox.isSignedIn, model.dropbox.phase != .notSetUp {
                        Button("Connect Dropbox") {
                            Task {
                                await model.dropbox.signIn(with: webAuthenticationSession)
                                await model.load(folder)
                            }
                        }
                    }
                }
            }
            if let contents = model.contents[folder] {
                Section {
                    ForEach(contents.folders) { item in
                        NavigationLink(value: AddSheetModel.Step.folder(item.path)) {
                            Label(item.name, systemImage: "folder.fill")
                        }
                    }
                    ForEach(contents.pdfs) { file in
                        Button {
                            Task { await model.open(file) }
                        } label: {
                            PDFRow(file: file, pages: model.pageCounts[file.id],
                                   downloading: model.downloading == file.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.downloading != nil)
                        .accessibilityHint("Download it once and choose a page to place")
                    }
                } footer: {
                    if contents.folders.isEmpty && contents.pdfs.isEmpty {
                        Text("No folders or PDFs here.")
                    } else {
                        Text("Search across all drawings arrives with the drawing index.")
                    }
                }
            } else if model.problem == nil {
                ProgressView("Reaching your Dropbox…")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(folder.isEmpty ? "Add a sheet" : (folder.split(separator: "/").last.map(String.init) ?? folder))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.close?() } }
        }
        .task { if model.contents[folder] == nil { await model.load(folder) } }
        .refreshable { await model.load(folder) }
    }
}

private struct PDFRow: View {
    let file: DropboxFile
    let pages: Int?
    let downloading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: (pages ?? 1) > 1 ? "doc.on.doc.fill" : "doc.richtext.fill")
                .foregroundStyle(Chrome.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if downloading { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        if downloading { return "Downloading \(size)…" }
        guard let pages else { return "PDF · \(size)" }
        return "\(pages) page\(pages == 1 ? "" : "s") · \(size)"
    }
}

/// A PDF's pages as thumbnails, each captioned with its sheet number and the scale read (#11, question 1, A). The
/// thumbnails and readings are made lazily, as the cells appear, off the main thread.
private struct PageGrid: View {
    let model: AddSheetModel
    let file: DropboxFile

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                ForEach(0..<(model.pageCounts[file.id] ?? 0), id: \.self) { page in
                    NavigationLink(value: AddSheetModel.Step.confirm(file, page: page)) {
                        PageCell(model: model, file: file, page: page)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            Text("\(model.pageCounts[file.id] ?? 0) pages · tap one to place it")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.close?() } }
        }
    }
}

private struct PageCell: View {
    let model: AddSheetModel
    let file: DropboxFile
    let page: Int
    @State private var thumbnail: UIImage?
    @State private var info: SheetPDFReader.PageInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit().padding(4)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 120)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.border))
            HStack(spacing: 6) {
                Text(info?.reading.sheetNumber ?? "Page \(page + 1)").font(.subheadline.weight(.semibold))
                Text("p\(page + 1)").font(.caption).foregroundStyle(.secondary)
            }
            if let info { ScaleTag(reading: info.reading) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Place this page")
        .task {
            guard let reader = await model.reader(for: file) else { return }
            info = await reader.info(page: page)
            thumbnail = await reader.thumbnail(page: page, side: 340)?.image
        }
    }
}

/// The scale read, as a tag: plain for a scale, amber for NTS, orange when Vellum will ask.
private struct ScaleTag: View {
    let reading: SheetReading

    var body: some View {
        Text(reading.caption)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(colour)
            .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }

    private var colour: Color {
        if reading.titleBlock == .notToScale { return Color(red: 0.54, green: 0.35, blue: 0) }
        return reading.asksForScale ? Color(red: 0.6, green: 0.2, blue: 0.07) : Chrome.secondaryText
    }
}

/// The confirm step: what Vellum read and what the sheet will cover, with Cancel, Change scale and Place sheet; or,
/// when it can't tell (AS NOTED, no scale, a scan, several scales, junk), the scales to pick or one to type, with the
/// scale areas outlined on the page for the scale picked.
private struct ConfirmSheet: View {
    let model: AddSheetModel
    let file: DropboxFile
    let page: Int
    @State private var info: SheetPDFReader.PageInfo?
    @State private var thumbnail: UIImage?
    @State private var picked: Sheet.Scale?
    @State private var changing = false
    @State private var typed = ""
    @State private var placing = false

    var body: some View {
        ScrollView {
            if let info {
                HStack(alignment: .top, spacing: 18) {
                    preview(info)
                        .frame(width: 330)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title(info)).font(.title3.weight(.semibold))
                        explanation(info)
                        if asks(info) { picker(info) }
                        if let chosen = chosen(info) {
                            Text("On the canvas it will cover \(coverage(info, chosen)).")
                                .font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("coverage")
                        }
                        buttons(info)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
            } else {
                ProgressView("Reading the title block…").padding(40)
            }
        }
        .navigationTitle(info?.reading.sheetNumber ?? "Page \(page + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let reader = await model.reader(for: file) else { return }
            let read = await reader.info(page: page)
            info = read
            if let read { picked = read.reading.suggestedScale }
            thumbnail = await reader.thumbnail(page: page, side: 660)?.image
        }
    }

    private func title(_ info: SheetPDFReader.PageInfo) -> String {
        [info.reading.sheetNumber, file.name].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whether Zach picks or types the scale: Vellum can't tell, or he asked to change it.
    private func asks(_ info: SheetPDFReader.PageInfo) -> Bool { info.reading.asksForScale || changing }

    private func chosen(_ info: SheetPDFReader.PageInfo) -> Sheet.Scale? {
        asks(info) ? picked : info.reading.suggestedScale
    }

    private func coverage(_ info: SheetPDFReader.PageInfo, _ scale: Sheet.Scale) -> String {
        model.covers(Sheet(paper: info.paper, scale: scale))
    }

    @ViewBuilder
    private func explanation(_ info: SheetPDFReader.PageInfo) -> some View {
        let reading = info.reading
        switch reading.titleBlock {
        case .scale(let scale) where !reading.asksForScale:
            Text("The title block says **SCALE: \(scale.description)**.")
        case .notToScale where !reading.asksForScale:
            Text("The title block says **NTS**. It goes on at its printed size (\(info.paper.name)), and lengths on it read as printed inches marked NTS.")
        case .asNoted:
            Text("The title block says **AS NOTED**. Pick the scale the sheet goes on at. Each detail that says another scale becomes a scale area, where Measure and Dimension read its own scale.")
        case .scan:
            Text("This page is a scan, so Vellum can't read its title block. Type the scale or pick one:")
        case .none:
            Text("Vellum found no SCALE in this title block. Type one or pick one:")
        case .unreadable(let text):
            Text("The title block says **\(text)**, so Vellum can't tell the scale. Type it or pick one:")
        case .scale, .notToScale:
            Text("This sheet has several scales. Pick the scale the sheet goes on at; details at other scales become scale areas.")
        }
        if changing, !reading.asksForScale { Text("Pick the scale to use instead:").font(.callout) }
    }

    private func picker(_ info: SheetPDFReader.PageInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowChips(scales: model.offeredScales(for: info.reading), found: info.reading.detailScales,
                      picked: $picked)
            HStack {
                TextField("Or type one, such as 3/16\" = 1'-0\"", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .onSubmit(readTyped)
                    .frame(maxWidth: 280)
                Button("Use", action: readTyped).disabled(typed.isEmpty)
            }
            let areas = picked.map { info.reading.areas(placedAt: $0) } ?? []
            if !areas.isEmpty {
                Text("Scale areas: " + areas.map(\.label).joined(separator: ", ") + ".")
                    .font(.footnote).foregroundStyle(Palette.scaleAreaColour)
            }
        }
    }

    private func readTyped() {
        switch DrawingScale.read(typed) {
        case .scale(let scale): picked = .drawn(scale)
        case .notToScale: picked = .notToScale
        case .cantTell: typed = ""
        }
    }

    private func buttons(_ info: SheetPDFReader.PageInfo) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") { model.close?() }
                .buttonStyle(.bordered)
            if !info.reading.asksForScale, !changing, info.reading.suggestedScale != nil {
                Button("Change scale") { changing = true }
                    .buttonStyle(.bordered)
            }
            Button {
                guard let scale = chosen(info) else { return }
                placing = true
                Task { await model.place(file, page: page, info: info, scale: scale) }
            } label: {
                if placing { ProgressView() } else { Text("Place sheet").bold() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen(info) == nil || placing)
            .accessibilityHint("Then tap the canvas where the sheet goes")
        }
    }

    /// The page, with its scale areas outlined for the scale picked.
    private func preview(_ info: SheetPDFReader.PageInfo) -> some View {
        let areas = chosen(info).map { info.reading.areas(placedAt: $0) } ?? []
        return ZStack {
            Color.white
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
                    .overlay {
                        GeometryReader { proxy in
                            let k = proxy.size.width / info.paper.width.inches
                            ForEach(Array(areas.enumerated()), id: \.offset) { item in
                                let area = item.element
                                let r = CGRect(x: area.rect.minX * k, y: area.rect.minY * k,
                                               width: area.rect.width.inches * k, height: area.rect.height.inches * k)
                                Rectangle()
                                    .strokeBorder(Palette.scaleAreaColour, style: StrokeStyle(lineWidth: 1.6, dash: [5, 3]))
                                    .background(Palette.scaleAreaColour.opacity(0.08))
                                    .overlay(alignment: .topLeading) {
                                        Text(area.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                                            .padding(.horizontal, 3).background(Palette.scaleAreaColour)
                                    }
                                    .frame(width: r.width, height: r.height)
                                    .position(x: r.midX, y: r.midY)
                            }
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .aspectRatio(info.paper.width.inches / info.paper.height.inches, contentMode: .fit)
        .overlay(Rectangle().strokeBorder(Chrome.border))
        .accessibilityLabel("Preview of the page" + (areas.isEmpty ? "" : ", with \(areas.count) scale areas outlined"))
    }
}

/// The scales to pick, as chips that wrap.
private struct FlowChips: View {
    let scales: [Sheet.Scale]
    let found: [Sheet.Scale]
    @Binding var picked: Sheet.Scale?

    var body: some View {
        WrappingLayout(spacing: 6) {
            ForEach(scales, id: \.self) { scale in
                Button {
                    picked = scale
                } label: {
                    Text(found.contains(scale) ? "\(scale.description) · on sheet" : scale.description)
                        .font(.footnote.weight(picked == scale ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(picked == scale ? Chrome.accent : Chrome.text)
                        .background(picked == scale ? Chrome.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(picked == scale ? Chrome.accent : Chrome.border))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked == scale ? .isSelected : [])
            }
        }
    }
}

/// Lays its views out in rows, wrapping when a row is full.
private struct WrappingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

extension Palette {
    /// A scale area's purple, for SwiftUI.
    static var scaleAreaColour: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xC4A2F0) : UIColor(hex: 0x6B3FA8) }) }
}
