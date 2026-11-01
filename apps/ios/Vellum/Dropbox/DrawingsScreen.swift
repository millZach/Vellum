import AuthenticationServices
import SwiftUI
import VellumCore

/// The Drawings tab. Until the drawing index exists (ADR-0007) it shows Zach's Dropbox: Connect Dropbox while signed
/// out, then the top-level folders, which proves Vellum's full Dropbox access. Settings, with Sign Out, opens from the
/// toolbar. Browsing deeper and placing PDFs is #11.
struct DrawingsScreen: View {
    @State private var dropbox = DropboxConnection.live()
    /// Debug builds accept `--ui-settings` to open with the Settings sheet up, for the captures.
    @State private var showsSettings = DrawingsScreen.launchesWithSettings

    var body: some View {
        NavigationStack {
            DropboxFoldersView(dropbox: dropbox)
                .navigationTitle("Drawings")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    }
                }
                .sheet(isPresented: $showsSettings) { DropboxSettingsSheet(dropbox: dropbox) }
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
        .task { await dropbox.refresh() }
    }
}

/// A small Settings sheet; for now it holds the Dropbox connection and Sign Out.
struct DropboxSettingsSheet: View {
    let dropbox: DropboxConnection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Dropbox") {
                    switch dropbox.phase {
                    case .notSetUp:
                        Text("Dropbox isn't set up in this build.")
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
    DrawingsScreen()
}
