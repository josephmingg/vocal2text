import BridgeKit
import SwiftUI

/// The Vocal keyboard's whole surface: a status line, the review row, and one
/// big mic key flanked by the globe and delete keys.
///
/// There is no letter grid on purpose — this keyboard exists to get dictated
/// text into the field, and the user switches back to their usual keyboard to
/// type. Delete is here because fixing a mis-insert without leaving is worth
/// one key.
struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    /// iOS decides whether the globe key must be shown at all.
    let showsInputModeSwitch: Bool
    let onAdvanceInputMode: () -> Void
    let onDeleteBackward: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            centerRow
            keyRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGray5))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            profileMenu
        }
    }

    @ViewBuilder
    private var profileMenu: some View {
        if model.profileNames.count > 1 {
            Menu {
                Button("Session default") { model.chosenProfileName = nil }
                Divider()
                ForEach(model.profileNames, id: \.self) { name in
                    Button(name) { model.chosenProfileName = name }
                }
            } label: {
                Label(model.chosenProfileName ?? "Auto", systemImage: "slider.horizontal.3")
                    .font(.footnote)
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("Dictation profile")
            .accessibilityValue(model.chosenProfileName ?? "Session default")
        }
    }

    // MARK: - Centre

    @ViewBuilder
    private var centerRow: some View {
        if let pending = model.pendingInsert {
            previewRow(pending)
        } else if let notice = model.notice {
            noticeRow(notice)
        } else {
            hintRow
        }
    }

    private func previewRow(_ pending: KeyboardModel.PendingInsert) -> some View {
        HStack(spacing: 10) {
            Text(pending.text)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Transcript preview: \(pending.text)")

            Button {
                model.discardPendingInsert()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .tint(.secondary)
            .accessibilityLabel("Discard transcript")

            Button {
                model.confirmPendingInsert()
            } label: {
                Image(systemName: "checkmark.circle.fill").font(.title2)
            }
            .tint(.accentColor)
            .accessibilityLabel("Insert transcript")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 10))
    }

    private func noticeRow(_ notice: String) -> some View {
        Button {
            model.dismissNotice()
        } label: {
            Text(notice)
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Double tap to dismiss")
    }

    private var hintRow: some View {
        Text(micHint)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private var micHint: String {
        switch model.micAction {
        case .startRecording: "Tap the mic to dictate into this field"
        case .stopRecording: "Tap to finish · hold to cancel"
        case .openApp: "Tap the mic to open Vocal and arm a session"
        case .busy(let message), .unavailable(let message): message
        }
    }

    // MARK: - Keys

    private var keyRow: some View {
        HStack(spacing: 10) {
            if showsInputModeSwitch {
                KeyButton(systemImage: "globe", accessibilityLabel: "Next keyboard") {
                    onAdvanceInputMode()
                }
            }

            micKey

            KeyButton(systemImage: "delete.left", accessibilityLabel: "Delete") {
                onDeleteBackward()
            }
        }
        .frame(height: 56)
    }

    private var micKey: some View {
        Button {
            model.micKeyTapped()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: micSymbol)
                    .font(.title2)
                Text(micTitle)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(micTint, in: .rect(cornerRadius: 12))
            .foregroundStyle(micForeground)
        }
        .buttonStyle(.plain)
        .disabled(isMicDisabled)
        .accessibilityLabel(micTitle)
        .accessibilityHint(micHint)
        // Hold to throw away a take that went wrong, without leaving the app.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in model.cancelRecording() }
        )
    }

    private var isMicDisabled: Bool {
        if case .unavailable = model.micAction { return true }
        return false
    }

    private var micSymbol: String {
        switch model.micAction {
        case .startRecording: "mic.fill"
        case .stopRecording: "stop.fill"
        case .openApp: "arrow.up.forward.app.fill"
        case .busy: "ellipsis"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var micTitle: String {
        switch model.micAction {
        case .startRecording: "Dictate"
        case .stopRecording: "Stop"
        case .openApp: "Open Vocal"
        case .busy: "Working…"
        case .unavailable: "Needs Full Access"
        }
    }

    private var micTint: Color {
        switch model.micAction {
        case .startRecording: Color.accentColor
        case .stopRecording: Color.red
        case .openApp: Color(uiColor: .systemBackground)
        case .busy, .unavailable: Color(uiColor: .systemGray4)
        }
    }

    private var micForeground: Color {
        switch model.micAction {
        case .startRecording, .stopRecording: .white
        case .openApp, .busy, .unavailable: .primary
        }
    }
}

/// A plain utility key, sized to sit either side of the mic.
private struct KeyButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                // Two frames, not one: SwiftUI has no overload mixing a fixed
                // width with a flexible height.
                .frame(maxHeight: .infinity)
                .frame(width: 56)
                .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 12))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
