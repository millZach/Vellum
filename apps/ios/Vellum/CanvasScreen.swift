import AuthenticationServices
import SwiftUI
import UIKit
import VellumCore

/// The canvas screen, the drafting rail Zach picked (ADR-0011, variant A at the tag `prototype/canvas-screen`): the
/// tool rail on the left, the top bar, the status bar along the bottom, and the iOS tab rail at the right edge, all
/// floating over the canvas.
struct CanvasScreen: View {
    let editor: CanvasEditor
    /// Back to the Canvases list; nil where there is no list (previews).
    var showCanvases: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            CanvasLayer(editor: editor, isDark: colorScheme == .dark)
                .ignoresSafeArea()
            // The chrome lays itself out over the whole screen, clear of the system's safe area and of the iOS tab
            // rail, which floats at the right edge unfolded.
            GeometryReader { proxy in
                let safe = proxy.safeAreaInsets
                HStack(alignment: .top, spacing: 8) {
                    ToolRail(editor: editor)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            // The top bar takes the room it needs before the spacer does, so the canvas name shows
                            // in full whenever it fits beside the actions.
                            TopBar(editor: editor, showCanvases: showCanvases)
                                .layoutPriority(1)
                            Spacer(minLength: 8)
                            CanvasActions(editor: editor)
                        }
                        if editor.placingSheet != nil {
                            PlacingSheetPill(editor: editor)
                                .padding(.top, 8)
                                .frame(maxWidth: .infinity)
                        } else if editor.tool == .frame {
                            FramePaperPicker(editor: editor)
                                .padding(.top, 8)
                        }
                        Spacer(minLength: 0)
                        StatusBar(editor: editor)
                    }
                    .padding(.trailing, max(92, safe.trailing + 8) - 8)
                }
                .padding(.leading, safe.leading + 8)
                .padding(.top, safe.top + 8)
                .padding(.bottom, safe.bottom + 8)
                .padding(.trailing, 8)
            }
            .ignoresSafeArea()
        }
        .alert("Sheet not placed", isPresented: Binding(get: { editor.sheetProblem != nil },
                                                         set: { if !$0 { editor.sheetProblem = nil } })) {
            Button("OK", role: .cancel) { editor.sheetProblem = nil }
        } message: {
            Text(editor.sheetProblem ?? "")
        }
    }
}

/// While a sheet waits to be placed (#11): what to do, and Cancel, as the prototype's pill says it.
private struct PlacingSheetPill: View {
    let editor: CanvasEditor

    var body: some View {
        HStack(spacing: 12) {
            Text("Tap where **\(editor.placingSheet?.sheet.page?.title ?? "the sheet")** goes")
                .lineLimit(1)
            Button("Cancel") { editor.cancelPlacing() }
                .buttonStyle(.bordered)
                .accessibilityHint("Don't place the sheet")
        }
        .font(.system(size: 13))
        .foregroundStyle(Chrome.text)
        .padding(.leading, 14).padding(.trailing, 6)
        .frame(height: 40)
        .chromePanel(cornerRadius: 12)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

/// The canvas under the chrome. Its own view, so a pan or pinch re-evaluates only this, not the whole screen; ink
/// changes reach the canvas from the editor without SwiftUI at all.
private struct CanvasLayer: View {
    let editor: CanvasEditor
    let isDark: Bool
    @AppStorage(FingerDrawingSetting.storageKey) private var fingerDraws = FingerDrawingSetting.default

    var body: some View {
        InkCanvasView(editor: editor, isDark: isDark, viewport: editor.viewport, units: editor.canvas.units,
                      fingerDraws: fingerDraws, tool: editor.tool)
    }
}

// MARK: - Tool rail

/// The tools down the left edge in their three groups, with the four markup colours at the foot.
private struct ToolRail: View {
    @Bindable var editor: CanvasEditor
    @Environment(\.colorScheme) private var colorScheme
    @State private var weightsFor: CanvasTool?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(CanvasTool.Group.allCases, id: \.self) { group in
                if group != CanvasTool.Group.allCases.first { RailDivider() }
                ForEach(group.tools) { tool in
                    toolButton(tool)
                }
            }
            Spacer(minLength: 8)
            VStack(spacing: 9) {
                ForEach(MarkupColour.allCases, id: \.self) { colour in
                    colourChip(colour)
                }
            }
            .padding(.bottom, 6)
        }
        .padding(.vertical, 6)
        .frame(width: 54)
        .frame(maxHeight: .infinity)
        .chromePanel(cornerRadius: 14)
    }

    private func toolButton(_ tool: CanvasTool) -> some View {
        let selected = editor.tool == tool
        return Button {
            if selected, tool.inkTool != nil {
                weightsFor = tool
            } else {
                editor.tool = tool
            }
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 42, height: 38)
                .foregroundStyle(selected ? Chrome.accent : Chrome.text)
                .background(selected ? Chrome.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .opacity(tool.isAvailable ? 1 : 0.32)
        }
        .buttonStyle(.plain)
        .disabled(!tool.isAvailable)
        .accessibilityLabel(tool.title)
        .accessibilityHint(selected && tool.inkTool != nil ? "Choose the line weight" : tool.hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .popover(isPresented: Binding(get: { weightsFor == tool }, set: { if !$0 { weightsFor = nil } }),
                 arrowEdge: .trailing) {
            WeightPicker(editor: editor)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func colourChip(_ colour: MarkupColour) -> some View {
        let selected = editor.colour == colour
        let rgb = colour.rgb(dark: colorScheme == .dark)
        return Button {
            editor.colour = colour
        } label: {
            Circle()
                .fill(Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Chrome.chipRim, lineWidth: 2))
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? Chrome.text : Chrome.border, lineWidth: selected ? 2 : 1))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(colour.title) ink")
        .accessibilityHint(colourHint(colour))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func colourHint(_ colour: MarkupColour) -> String {
        switch colour.meaning {
        case .add: "Red: something to add"
        case .delete: "Green: something to delete"
        case .note: "Blue: a note"
        case .sketch: "Sketch, read for context only"
        }
    }
}

private struct RailDivider: View {
    var body: some View {
        Rectangle().fill(Chrome.border).frame(width: 32, height: 1).padding(.vertical, 4)
    }
}

/// The pen's or highlighter's three line weights, shown by tapping the tool again.
private struct WeightPicker: View {
    @Bindable var editor: CanvasEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(editor.tool.title) weight").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(LineWeight.allCases, id: \.self) { weight in
                Button {
                    editor.weight = weight
                } label: {
                    HStack(spacing: 12) {
                        Capsule()
                            .frame(width: 44, height: max(1.5, weight.screenWidth(for: editor.tool.inkTool ?? .pen) / 2))
                            .opacity(editor.tool == .highlighter ? 0.4 : 1)
                        Text(weight.title)
                        Spacer()
                        if editor.weight == weight { Image(systemName: "checkmark") }
                    }
                    .frame(width: 170, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }
}

// MARK: - Top bar

/// Back to the Canvases list, the canvas's name, its units, light or dark, undo and redo, and Settings. A long press on the
/// name offers the made-up test canvas (`TestCanvas`).
private struct TopBar: View {
    @Bindable var editor: CanvasEditor
    let showCanvases: (() -> Void)?
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.default.rawValue
    @Environment(\.testCanvas) private var testCanvas
    @State private var offersTestCanvas = false
    /// The Settings sheet the Drawings tab's gear opens too (#28). Debug builds accept `--ui-canvas-settings` to open
    /// with it up, for the captures.
    @State private var showsSettings = TopBar.launchesWithSettings

    var body: some View {
        // Gaps of 8, not 10, so "Boiler 4 walkdown (example)" fits in full beside the actions at 951 points (#35).
        HStack(spacing: 8) {
            if let showCanvases {
                Button(action: showCanvases) {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).frame(width: 26, height: 30)
                }
                .accessibilityLabel("Canvases")
                .accessibilityHint("Back to the list of canvases")
            }
            Text(editor.canvas.name)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .layoutPriority(1)
                .onLongPressGesture(minimumDuration: 0.8) {
                    if testCanvas != nil { offersTestCanvas = true }
                }
                .confirmationDialog("Test canvas", isPresented: $offersTestCanvas, titleVisibility: .visible) {
                    if let testCanvas {
                        Button(testCanvas.isOpen ? "Back to My Canvas" : "Open the 10,000-Stroke Test Canvas") {
                            testCanvas.toggle()
                        }
                    }
                } message: {
                    Text("A made-up canvas for trying pan, pinch, draw and erase. It is never saved, and your canvas stays as it is.")
                }
            Picker("Canvas units", selection: $editor.units) {
                ForEach(CanvasUnits.allCases, id: \.self) { units in
                    Text(units.shortTitle).tag(units)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Canvas units")
            Menu {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { setting in
                        Label(setting.title, systemImage: setting.systemImage).tag(setting.rawValue)
                    }
                }
            } label: {
                Image(systemName: (AppearanceSetting(rawValue: appearance) ?? .default).systemImage)
                    .font(.system(size: 17))
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Appearance")
            .accessibilityValue((AppearanceSetting(rawValue: appearance) ?? .default).title)
            Button {
                editor.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 17)).frame(width: 30, height: 30)
            }
            .disabled(!editor.canUndo)
            .accessibilityLabel("Undo")
            Button {
                editor.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward").font(.system(size: 17)).frame(width: 30, height: 30)
            }
            .disabled(!editor.canRedo)
            .accessibilityLabel("Redo")
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 30, height: 30)
            }
            .accessibilityLabel("Settings")
            .accessibilityHint("Draw with finger and Dropbox")
            .sheet(isPresented: $showsSettings) { SettingsSheet(dropbox: .app) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Chrome.text)
        .tint(Chrome.text)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .chromePanel(cornerRadius: 12)
    }

    private static var launchesWithSettings: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-canvas-settings")
        #else
        false
        #endif
    }
}

/// Add sheet, Record and Send, at the top right. Add sheet opens the Dropbox browser (#11); Record and Send come with
/// later tickets and show where they will be.
private struct CanvasActions: View {
    let editor: CanvasEditor
    @State private var addSheet: AddSheetModel?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                open()
            } label: {
                Label("Add sheet", systemImage: "plus")
                    .font(.system(size: 13))
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .foregroundStyle(Chrome.text)
                    .background(Chrome.panel, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Chrome.border))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Browse Dropbox for a PDF, pick a page, confirm its scale, then tap where it goes")
            action("Record", systemImage: "record.circle", hint: "Recording meetings comes in a later update.")
            // Faded blue while disabled, as Place sheet is (#33).
            Button {} label: {
                Label("Send", systemImage: "paperplane.fill").font(.system(size: 13, weight: .semibold))
            }
            // The old width, so the canvas name keeps its room.
            .buttonStyle(ChromePrimaryButtonStyle(horizontalPadding: 11))
            .disabled(true)
            .accessibilityHint("Not available yet. Sending to an agent comes in a later update.")
        }
        .lineLimit(1)
        // Each action stays on one line (#35); the canvas name gives way first.
        .fixedSize(horizontal: true, vertical: false)
        .sheet(item: $addSheet) { model in
            AddSheetFlow(model: model)
        }
        #if DEBUG
        .task { await debugOpen() }
        #endif
    }

    private func makeModel() -> AddSheetModel {
        let editor = editor
        let model = AddSheetModel(dropbox: .app, units: editor.canvas.units, covers: { editor.covers($0) })
        model.onPlace = { [weak model] pending in
            model?.close?()
            editor.beginPlacing(pending)
        }
        model.close = { addSheet = nil }
        return model
    }

    private func open() {
        editor.cancelPlacing()
        addSheet = makeModel()
    }

    #if DEBUG
    /// `--ui-add-sheet <step>` opens Add sheet at a step for the captures, on the made-up Dropbox
    /// (`--ui-dropbox sheets`): `browser` (the made-up project's drawings), `grid` (the IFC set's pages), `confirm` (the
    /// 1/4" plan), `asnoted` (the AS NOTED detail sheet, its scale areas outlined) or `scan` (the scan, asking).
    private func debugOpen() async {
        guard let step = DebugLaunch.argument("--ui-add-sheet") else { return }
        try? await Task.sleep(for: .seconds(1))
        let model = makeModel()
        addSheet = model
        try? await Task.sleep(for: .seconds(0.6))
        let set = MadeUpSheets.files[0].name, scan = MadeUpSheets.files[2].name
        switch step {
        case "grid": await model.debugGo(to: MadeUpSheets.folder, file: set, page: nil)
        case "confirm": await model.debugGo(to: MadeUpSheets.folder, file: set, page: 0)
        case "asnoted": await model.debugGo(to: MadeUpSheets.folder, file: set, page: 1)
        case "scan": await model.debugGo(to: MadeUpSheets.folder, file: scan, page: nil)
        default: await model.debugGo(to: MadeUpSheets.folder, file: nil, page: nil)
        }
    }
    #endif

    private func action(_ title: String, systemImage: String, hint: String) -> some View {
        Button {} label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .frame(height: 34)
                .foregroundStyle(Chrome.text)
                .background(Chrome.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Chrome.border))
                .opacity(0.45)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityHint("Not available yet. " + hint)
    }
}

/// The paper a frame is drawn on, under the top bar while the frame tool is in hand (#8, "drag a box"): the scale
/// comes from the drag, so the paper is the only thing to pick.
private struct FramePaperPicker: View {
    @Bindable var editor: CanvasEditor

    var body: some View {
        HStack(spacing: 8) {
            Text("Frame paper").foregroundStyle(Chrome.secondaryText)
            Picker("Frame paper", selection: $editor.framePaper) {
                ForEach(PaperSize.frameSizes, id: \.self) { paper in
                    Text(paper.name).tag(paper)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text("Scale: from your drag").foregroundStyle(Chrome.secondaryText)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 36)
        .chromePanel(cornerRadius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityHint("The paper size of the next frame. Its drawing scale is the one whose paper covers your drag")
    }
}

// MARK: - Status bar

#if !DEBUG
private extension View {
    func debugReportsCountWidth() -> some View { self }
    func debugReportsStatusBarWidth() -> some View { self }
}
#endif

/// The pen's position, the scale bar, what the tool expects next, the sheet and frame count, zoom to everything, and
/// whether the canvas is saved.
private struct StatusBar: View {
    let editor: CanvasEditor
    /// The Canvases tab's model, for the canvas's sync (#12); nil in previews and on the test canvas.
    @Environment(CanvasesModel.self) private var canvases: CanvasesModel?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        HStack(spacing: 8) {
            // The readouts are their own views, so the pen moving or the zoom changing redraws only them.
            PenReadout(editor: editor)
            ScaleReadout(editor: editor)
            // The prompt always shows in full (#12): the status wording is kept short enough to leave it room.
            ToolPrompt(tool: editor.tool, hasSelection: !editor.selection.isEmpty, hasSheet: editor.selection.sheet != nil,
                       step: editor.toolStep)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
            // The count takes the shortest wording that leaves everything else whole (#33).
            ViewThatFits(in: .horizontal) {
                ForEach(counts, id: \.self) { Text($0).lineLimit(1) }
            }
            .debugReportsCountWidth()
            .foregroundStyle(Chrome.secondaryText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(counts[0])
            .layoutPriority(1)
            Button {
                editor.zoomToEverything()
            } label: {
                Image(systemName: "viewfinder").font(.system(size: 16)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom to everything")
            SyncStatusLabel(line: statusLine,
                            act: SyncActions(model: canvases, webAuthentication: webAuthenticationSession).run)
        }
        .font(.system(size: 12))
        .foregroundStyle(Chrome.text)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .chromePanel(cornerRadius: 11)
        .debugReportsStatusBarWidth()
    }

    /// Saved on the Duo first, then synced to Dropbox (#12).
    private var statusLine: SyncStatusLine {
        let sync = editor.saver == nil ? CanvasSyncState.off : canvases?.syncState(of: editor.canvasID) ?? .off
        return SyncStatusLine.statusBar(save: editor.saveState, sync: sync, edited: editor.hasEdits,
                                        online: canvases?.syncReport.online ?? true)
    }

    private var counts: [String] {
        StatusBarText.counts(sheets: editor.canvas.sheets.count, frames: editor.frameCount)
    }
}

/// What the tool expects next. Its own view, holding the Draw with finger setting, so turning the switch redraws only
/// this text.
private struct ToolPrompt: View {
    let tool: CanvasTool
    /// Whether the lasso has a selection, which it then says to drag (#7).
    let hasSelection: Bool
    /// Whether the lasso has picked up a sheet, which it then says to twist or drag (#44).
    let hasSheet: Bool
    /// Where a measure, dimension or window is up to (#8).
    let step: CanvasTool.Step
    @AppStorage(FingerDrawingSetting.storageKey) private var fingerDraws = FingerDrawingSetting.default

    var body: some View {
        Text(tool.prompt(fingerDraws: fingerDraws, hasSelection: hasSelection, hasSheet: hasSheet, step: step))
            .foregroundStyle(Chrome.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The pen's position in canvas units, on one line at 11 pt monospaced so digits don't jump (#33). The canvas view
/// publishes the position at most once a display frame, and the text is formatted once per update and used for both the
/// label and VoiceOver. Its width is set, so the pen moving lays out only this text; `StatusBarText` says when it grows.
private struct PenReadout: View {
    let editor: CanvasEditor
    @State private var reserved = StatusBarText.usualPositionCharacters
    private static let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width

    var body: some View {
        let position = editor.penPosition
        let text = position.map(editor.canvas.units.formatPosition)
        Text(text ?? "X –  Y –")
            .font(Font(Self.font))
            .lineLimit(1)
            .fixedSize()
            .frame(width: (CGFloat(reserved) * Self.advance).rounded(.up), alignment: .leading)
            .onChange(of: text?.count ?? 0) { _, count in
                reserved = StatusBarText.reservedCharacters(reserved, showing: count)
            }
            .accessibilityLabel(position == nil ? "No pen position yet" : "Pen position")
            .accessibilityValue(text ?? "")
    }
}

/// The scale bar: the longest round length that fits, labelled exactly. Its width follows the label alone, never the
/// bar, so a pinch lays out only the bar until the label changes, and only a label too long for `labelRoom` moves the
/// prompt and may shorten the count (#45). The hidden copy is what sets the width; the label stays on one line, whole.
private struct ScaleReadout: View {
    let editor: CanvasEditor
    private static let gap = 6.0
    /// Room for any label up to `50'-0"`, so the prompt holds still through the usual zooms and the three longer prompts
    /// keep the full count beside them.
    private static let labelRoom = 40.0

    var body: some View {
        let pointsPerInch = editor.viewport.pointsPerInch
        let bar = ScaleBar.mark(fitting: StatusBarText.scaleBarLongest, pointsPerInch: pointsPerInch,
                                units: editor.canvas.units)
        Text(bar.label).monospacedDigit().fixedSize().hidden()
            .frame(minWidth: Self.labelRoom, alignment: .leading)
            // Rigid: without this the bar's row is told the readout can squeeze to its minimum, gives the count that
            // room, and a longer label then pushes the whole bar wider.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, StatusBarText.scaleBarLongest + Self.gap)
            .overlay(alignment: .leading) {
                HStack(spacing: Self.gap) {
                    ScaleBarShape()
                        .stroke(Chrome.text, lineWidth: 1.5)
                        .frame(width: ScaleBar.points(for: bar.length, pointsPerInch: pointsPerInch), height: 6)
                    Text(bar.label).monospacedDigit().fixedSize()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Scale bar")
            .accessibilityValue(bar.label)
    }
}

/// A scale bar's open bracket: down the left end, along the bottom, up the right end.
private struct ScaleBarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

// MARK: - Chrome colours

/// The drafting rail's chrome colours, light and dark, from the prototype.
enum Chrome {
    static let panel = dynamic(light: 0xFCFAF6, lightAlpha: 0.94, dark: 0x242529, darkAlpha: 0.94)
    static let border = dynamic(light: 0xD9D4C9, dark: 0x3A3B40)
    static let text = dynamic(light: 0x1D1D1F, dark: 0xE8E6E1)
    static let secondaryText = dynamic(light: 0x6B6B70, dark: 0xA9A9AE)
    static let accent = dynamic(light: 0x2F5D8A, dark: 0x9CC4EC)
    static let selected = dynamic(light: 0xE6EDF5, dark: 0x2C3A4A)
    static let primary = dynamic(light: 0x2F5D8A, dark: 0x3F74A8)
    /// A disabled button (#35): faded blue, `ChromeColourPair.disabledButton`, which a test holds at 4.5:1.
    static let disabledText = dynamic(light: ChromeColourPair.disabledButton(dark: false).text,
                                      dark: ChromeColourPair.disabledButton(dark: true).text)
    static let disabledFill = dynamic(light: ChromeColourPair.disabledButton(dark: false).fill,
                                      dark: ChromeColourPair.disabledButton(dark: true).fill)
    /// The Canvases list's ground: the canvas's paper in light, its dark ground in dark.
    static let listGround = dynamic(light: 0xF3EFE6, dark: 0x1C1D20)
    static let chipRim = dynamic(light: 0xFFFFFF, dark: 0x26272B)
    /// For a canvas with changes not yet written on the Duo: amber, never green.
    static let unsaved = dynamic(light: 0x9A5B00, dark: 0xE0A458)
    /// The tint behind "Saved · offline" (#12): the amber, faint.
    static let unsavedTint = dynamic(light: 0x9A5B00, lightAlpha: 0.11, dark: 0xE0A458, darkAlpha: 0.13)

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// A primary button: white on the chrome's primary blue, and faded blue when disabled (#35). Its label stays on one line.
struct ChromePrimaryButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 14
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: 34)
            .foregroundStyle(isEnabled ? Color.white : Chrome.disabledText)
            .background(isEnabled ? Chrome.primary : Chrome.disabledFill, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private extension View {
    func chromePanel(cornerRadius: CGFloat) -> some View {
        background(Chrome.panel, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Chrome.border))
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

extension CanvasUnits {
    /// The units' name in the top bar's menu.
    var shortTitle: String {
        switch self {
        case .feetAndInches: "ft-in"
        case .decimalFeet: "Decimal ft"
        case .metric: "Metric"
        }
    }
}

extension AppearanceSetting {
    /// Where the setting is kept on the Duo.
    static let storageKey = "appearance"

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// The style the window is pinned to; unspecified follows the Duo.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 951, height: 669)) {
    CanvasScreen(editor: CanvasEditor(canvas: DebugFixture.canvas, startingView: .everything))
}
#endif
