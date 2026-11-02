import AuthenticationServices
import SwiftUI
import VellumCore

/// The sync wording (`SyncStatusLine`, decided in VellumCore and tested there) drawn in the drafting rail's chrome, as
/// variant B of the tag `prototype/sync-status` draws it: grey when all is well, amber and tinted with a warning sign
/// while changes wait offline, and the text colour with a small Retry or Sign in when syncing needs Zach.
struct SyncStatusLabel: View {
    let line: SyncStatusLine
    let act: @MainActor (SyncStatusLine.Action) -> Void
    /// The status bar's 12 pt, or the list's.
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 5) {
            if line.showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size - 2, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(line.text)
                .font(.system(size: size, weight: weight))
                .accessibilityLabel("Save status")
                .accessibilityValue(line.accessibilityLabel)
            if let action = line.action {
                SyncActionButton(action: action, act: act)
            }
        }
        .foregroundStyle(SyncStatusStyle.colour(line.tone))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, line.tone == .offline ? 6 : 0)
        .padding(.vertical, line.tone == .offline ? 3 : 0)
        .background(line.tone == .offline ? Chrome.unsavedTint : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }

    private var weight: Font.Weight {
        switch line.tone {
        case .offline: .semibold
        case .attention: .medium
        case .calm, .notSaved: .regular
        }
    }
}

/// Retry or Sign in, small, beside the wording.
struct SyncActionButton: View {
    let action: SyncStatusLine.Action
    let act: @MainActor (SyncStatusLine.Action) -> Void

    var body: some View {
        Button(action.title) { act(action) }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Chrome.accent)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Chrome.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.border))
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityLabel(action.accessibilityLabel)
    }
}

enum SyncStatusStyle {
    static func colour(_ tone: SyncStatusLine.Tone) -> Color {
        switch tone {
        case .calm: Chrome.secondaryText
        case .notSaved, .offline: Chrome.unsaved
        case .attention: Chrome.text
        }
    }
}

/// Runs a sync action from wherever it is shown: Retry asks the sync engine to try now; Sign in opens Dropbox's sign-in
/// sheet, as the Drawings tab's Connect Dropbox does, and tells the engine once it is done.
struct SyncActions {
    let model: CanvasesModel?
    let webAuthentication: WebAuthenticationSession

    @MainActor
    func run(_ action: SyncStatusLine.Action) {
        switch action {
        case .retry:
            model?.retrySync()
        case .signIn:
            let model = model
            Task {
                let dropbox = DropboxConnection.app
                await dropbox.appeared()
                await dropbox.signIn(with: webAuthentication)
                model?.dropboxSignInChanged()
            }
        }
    }
}
