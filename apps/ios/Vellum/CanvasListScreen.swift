import SwiftUI
import UIKit
import VellumCore

/// The Canvases tab's list, layout C (the tag `prototype/canvas-list`): the canvases down the left with New canvas at
/// the top, each with when it last changed and what is in it, and on the right a large preview of the selected one with
/// Open, Rename and Delete…. The preview is a cached thumbnail drawn in the background after edits, never the ink.
struct CanvasListScreen: View {
    @Bindable var model: CanvasesModel
    @State private var renaming: CanvasSummary?
    @State private var newName = ""
    @State private var deleting: CanvasSummary?

    var body: some View {
        GeometryReader { proxy in
            let safe = proxy.safeAreaInsets
            HStack(alignment: .top, spacing: 18) {
                list
                    .frame(width: max(300, (proxy.size.width - max(92, safe.trailing + 8) - 40) * 0.4))
                preview
            }
            .padding(.leading, max(safe.leading, 16) + 8)
            .padding(.trailing, max(92, safe.trailing + 8))
            .padding(.top, safe.top + 14)
            .padding(.bottom, safe.bottom + 14)
        }
        .ignoresSafeArea()
        .background(Chrome.listGround)
        .alert("Rename canvas", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let canvas = renaming { Task { await model.rename(canvas.id, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Canvas", role: .destructive) {
                if let canvas = deleting { Task { await model.delete(canvas.id) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The canvas and all its ink will be gone from this Duo. This can't be undone.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
    }

    // MARK: The list

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Canvases").font(.system(size: 26, weight: .bold))
                Spacer()
                Button {
                    Task { await model.newCanvas() }
                } label: {
                    Label("New canvas", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .foregroundStyle(.white)
                        .background(Chrome.primary, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(model.library == nil)
            }
            if model.hasLoaded && model.summaries.isEmpty {
                ContentUnavailableView("No canvases yet", systemImage: "square.and.pencil",
                                       description: Text("Make one with New canvas. Everything you draw is saved on this Duo as you draw it."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.summaries) { canvas in
                            row(canvas)
                        }
                    }
                }
            }
        }
    }

    private func row(_ canvas: CanvasSummary) -> some View {
        let selected = model.selection == canvas.id
        return Button {
            if selected {
                Task { await model.open(canvas.id) }
            } else {
                model.selection = canvas.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(canvas.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(details(canvas)).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Chrome.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Chrome.text)
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square") { Task { await model.open(canvas.id) } }
            Button("Rename", systemImage: "pencil") { startRenaming(canvas) }
            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = canvas }
        }
        .accessibilityHint(selected ? "Opens the canvas" : "Shows its preview")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "Today 2:14 PM · 312 strokes", the sheets once they can be placed.
    private func details(_ canvas: CanvasSummary) -> String {
        var parts = [Self.when(canvas.modified)]
        if let info = model.previews[canvas.id] {
            parts.append(info.strokeCount == 1 ? "1 stroke" : "\(info.strokeCount.formatted()) strokes")
            if info.sheetCount > 0 { parts.append(info.sheetCount == 1 ? "1 sheet" : "\(info.sheetCount) sheets") }
        }
        return parts.joined(separator: " · ")
    }

    private static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: The preview

    @ViewBuilder
    private var preview: some View {
        if let canvas = model.summaries.first(where: { $0.id == model.selection }) {
            VStack(alignment: .leading, spacing: 10) {
                CanvasThumbnail(id: canvas.id, revision: model.previewRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) { Task { await model.open(canvas.id) } }
                HStack(spacing: 8) {
                    Text(canvas.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    actionButton("Open", primary: true) { Task { await model.open(canvas.id) } }
                        .disabled(model.opening != nil)
                    actionButton("Rename") { startRenaming(canvas) }
                    actionButton("Delete…") { deleting = canvas }
                }
            }
        } else {
            Color.clear
        }
    }

    private func actionButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: primary ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .foregroundStyle(primary ? Color.white : Chrome.text)
                .background(primary ? Chrome.primary : Chrome.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(primary ? Color.clear : Chrome.border))
        }
        .buttonStyle(.plain)
    }

    private func startRenaming(_ canvas: CanvasSummary) {
        newName = canvas.name
        renaming = canvas
    }
}

/// A canvas's cached thumbnail, loaded off the main thread, in the current appearance.
private struct CanvasThumbnail: View {
    let id: UUID
    let revision: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var loadedFor: String?

    var body: some View {
        let dark = colorScheme == .dark
        let key = "\(id.uuidString)-\(dark)-\(revision)"
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: Palette.ground(dark: dark)))
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(4)
            } else if loadedFor == key {
                Text("No preview yet").font(.system(size: 13)).foregroundStyle(Chrome.secondaryText)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Chrome.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the canvas's ink")
        .task(id: key) {
            let url = CanvasPreviews.imageURL(for: id, dark: dark)
            let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage(data: data)?.preparingForDisplay()
            }.value
            image = loaded
            loadedFor = key
        }
    }
}
