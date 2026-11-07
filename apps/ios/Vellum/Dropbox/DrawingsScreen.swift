import AuthenticationServices
import SwiftUI
import UIKit
import VellumCore

/// The Drawings tab: the search over the Duo's copy of the drawing index (#68, `DrawingSearchView`), or, while
/// Vellum isn't signed in to Dropbox, Connect Dropbox. Browsing Zach's Dropbox folders opens from under the search.
/// Settings, with Sign Out, opens from the toolbar.
struct DrawingsScreen: View {
    let index: DrawingIndexModel
    @State private var dropbox = DropboxConnection.app
    /// Debug builds accept `--ui-settings` to open with the Settings sheet up, for the captures.
    @State private var showsSettings = DrawingsScreen.launchesWithSettings

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Drawings")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    }
                }
                .sheet(isPresented: $showsSettings) { SettingsSheet(dropbox: dropbox) }
        }
        .task { await dropbox.appeared() }
    }

    @ViewBuilder
    private var content: some View {
        switch dropbox.phase {
        case .notSetUp, .signedOut, .signingIn:
            DropboxFoldersView(dropbox: dropbox)
        case .checkingSignIn:
            // Only a moment, reading the Keychain; a copy already read shows meanwhile.
            if index.copyState == .ready { DrawingSearchView(model: index, dropbox: dropbox) } else { Color.clear }
        case .loadingFolders, .signedIn:
            DrawingSearchView(model: index, dropbox: dropbox)
        }
    }
}

/// Dropbox's part of a screen, in one view so it can move to wherever Zach wants it: not set up, Connect Dropbox, or
/// the folders at the top of his Dropbox.
struct DropboxFoldersView: View {
    let dropbox: DropboxConnection
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        Group {
            switch dropbox.phase {
            case .checkingSignIn:
                Color.clear
            case .notSetUp:
                ContentUnavailableView {
                    Label("Dropbox isn't set up in this build", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text("This build was made without Vellum's Dropbox app key. TestFlight builds have it.")
                }
            case .signedOut:
                ContentUnavailableView {
                    Label("Connect Dropbox", systemImage: "folder.badge.plus")
                } description: {
                    Text("Sign in to Dropbox once so Vellum can open the PDFs in your project folders and keep your canvases there.")
                    if let problem = dropbox.problem {
                        Text(problem.message).foregroundStyle(.red)
                    }
                    if let notice = dropbox.notice {
                        Text(notice)
                    }
                } actions: {
                    Button("Connect Dropbox") {
                        Task { await dropbox.signIn(with: webAuthenticationSession) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .signingIn:
                ProgressView("Signing in to Dropbox…")
            case .loadingFolders:
                ProgressView("Reaching your Dropbox…")
            case .signedIn(let folders):
                List {
                    if let problem = dropbox.problem {
                        Section {
                            Label(problem.message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Button("Try Again") { Task { await dropbox.refresh() } }
                        }
                    }
                    Section {
                        ForEach(folders) { folder in
                            Label(folder.name, systemImage: "folder.fill")
                        }
                    } header: {
                        Text("Your Dropbox")
                    } footer: {
                        if folders.isEmpty && dropbox.problem == nil {
                            Text("Your Dropbox has no folders at the top.")
                        }
                    }
                }
                .refreshable { await dropbox.refresh() }
            }
        }
        .task { await dropbox.appeared() }
    }
}

/// A small Settings sheet: Draw with finger (#24), the Speed check (#42), then the Dropbox connection and Sign Out.
struct SettingsSheet: View {
    let dropbox: DropboxConnection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false
    /// Kept on this Duo; the canvas reads it when it changes.
    @AppStorage(FingerDrawingSetting.storageKey) private var drawsWithFinger = FingerDrawingSetting.default
    /// Kept on this Duo, as Draw with finger is; the canvas reads it when it changes.
    @AppStorage(SpeedCheckSetting.storageKey) private var speedCheck = SpeedCheckSetting.default

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Draw with finger", isOn: $drawsWithFinger)
                } header: {
                    Text("Drawing")
                } footer: {
                    Text(drawsWithFinger
                         ? "One finger draws, erases or uses the selected tool. Two fingers pan and pinch. The Apple Pencil always draws."
                         : "Only the Apple Pencil draws. Fingers pan and pinch.")
                }
                SpeedCheckSection(isOn: $speedCheck)
                Section("Dropbox") {
                    switch dropbox.phase {
                    case .notSetUp:
                        Text("Dropbox isn't set up in this build.")
                    case .checkingSignIn:
                        EmptyView()
                    case .signedOut:
                        Text("Not connected.")
                        if let notice = dropbox.notice {
                            Text(notice).foregroundStyle(.secondary)
                        }
                    case .signingIn:
                        Text("Signing in…")
                    case .loadingFolders, .signedIn:
                        Text("Connected. Vellum can read and write your whole Dropbox.")
                        if let problem = dropbox.problem {
                            Text(problem.message).foregroundStyle(.red)
                        }
                        if dropbox.isSigningOut {
                            ProgressView("Signing out…")
                        } else {
                            Button("Sign Out of Dropbox", role: .destructive) { confirmsSignOut = true }
                                .confirmationDialog("Sign out of Dropbox?", isPresented: $confirmsSignOut,
                                                    titleVisibility: .visible) {
                                    Button("Sign Out", role: .destructive) {
                                        Task { await dropbox.signOut() }
                                    }
                                } message: {
                                    Text("Vellum forgets its Dropbox sign-in on this Duo and asks Dropbox to end it.")
                                }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// The Speed check (#42, variant B of the prototype at the tag `prototype/speed-check`): the switch, and while it is on
/// the last ten timed gestures, newest first, with Copy all and Clear. They are held in memory only.
private struct SpeedCheckSection: View {
    @Binding var isOn: Bool
    private let recorder = SpeedCheckRecorder.shared
    @State private var copied = false

    var body: some View {
        Section {
            Toggle("Speed check", isOn: $isOn)
            if isOn {
                if recorder.gestures.isEmpty {
                    Text("No gestures timed yet. Pan or pinch on a canvas.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recorder.gestures) { gesture in
                        row(gesture)
                    }
                    HStack(spacing: 12) {
                        Button(copied ? "Copied" : "Copy all") {
                            UIPasteboard.general.string = recorder.copyText()
                            copied = true
                        }
                        .buttonStyle(.bordered)
                        Button("Clear", role: .destructive) {
                            recorder.clear()
                            copied = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        } header: {
            Text("Speed")
        } footer: {
            Text(SpeedCheckSetting.footer(isOn: isOn))
        }
        .onChange(of: isOn) { _, on in
            if !on { copied = false }
        }
    }

    private func row(_ gesture: SpeedCheckGesture) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(gesture.title)
                Text(gesture.timeOfDay).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                // The missed frames in red when there are any, as the prototype has them.
                Text("\(SpeedCheckText.seconds(gesture.seconds)) s · \(Text("\(gesture.summary.missed) missed").foregroundStyle(gesture.summary.missed > 0 ? Color.red : Color.secondary))")
                    .foregroundStyle(.secondary)
                Text(gesture.worst).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
    }
}

extension DrawingsScreen {
    fileprivate static var launchesWithSettings: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-settings")
        #else
        false
        #endif
    }
}

#Preview(traits: .fixedLayout(width: 951, height: 669)) {
    DrawingsScreen(index: DrawingIndexModel())
}
