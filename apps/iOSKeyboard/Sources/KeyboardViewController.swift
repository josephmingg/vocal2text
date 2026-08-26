import BridgeKit
import SwiftUI
import UIKit

/// The Vocal keyboard extension (docs/02 §3.1, design D2b).
///
/// Research settled this shape before any code was written: in-keyboard mic
/// recording fails with entitlement errors, and the ~48–80 MB keyboard jetsam
/// ceiling fits no ASR model. So this process only ever renders a few keys,
/// reads and writes small JSON files in the App Group, and calls
/// `insertText`. All capture and transcription happen in the container app.
///
/// Nothing here opens a socket. That claim is checkable: the extension links
/// `BridgeKit` and `SwiftUI` only — no networking module is imported anywhere
/// in this target, and BridgeKit depends on CoreModels alone (Package.swift).
final class KeyboardViewController: UIInputViewController {

    private var model: KeyboardModel?
    private var hosting: UIHostingController<KeyboardRootView>?

    /// Tall enough for the status line, the review row, and a comfortable key
    /// row; short enough to leave the host app's conversation visible.
    private static let preferredHeight: CGFloat = 232

    override func viewDidLoad() {
        super.viewDidLoad()

        let model = KeyboardModel(hasFullAccess: { [weak self] in self?.hasFullAccess ?? false })
        model.insertText = { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }
        model.openURL = { [weak self] url in
            self?.open(url)
        }
        self.model = model

        let root = KeyboardRootView(
            model: model,
            showsInputModeSwitch: needsInputModeSwitchKey,
            onAdvanceInputMode: { [weak self] in self?.advanceToNextInputMode() },
            onDeleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() }
        )
        let hosting = UIHostingController(rootView: root)
        self.hosting = hosting

        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)

        // The system supplies its own height constraints; ours has to yield to
        // them or Auto Layout logs a conflict on every appearance.
        let height = view.heightAnchor.constraint(equalToConstant: Self.preferredHeight)
        height.priority = .defaultHigh
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Re-read on every appearance: the session may have expired, or the
        // app may have finished a take, while this keyboard was off screen.
        model?.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model?.stop()
    }

    /// Fires on every text or selection change, including a move to another
    /// field. The model treats that as "the target moved" and drops any
    /// transcript still awaiting ✓, because `textDocumentProxy` always writes
    /// to whatever is first responder now.
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model?.inputContextChanged()
    }

    /// Opening the container app from a keyboard requires Full Access on
    /// current iOS (docs/02 §6). `NSExtensionContext.open` is the supported
    /// route; `UIApplication.shared` does not exist in an app extension.
    private func open(_ url: URL) {
        extensionContext?.open(url, completionHandler: nil)
    }
}
