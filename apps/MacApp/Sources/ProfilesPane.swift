import AppKit
import CoreModels
import SwiftUI

/// Settings → Profiles: the profile editor (docs/11 G17, spec docs/05 §4).
/// Master–detail: profile list on the left, the selected profile's settings
/// on the right. Every control writes through `ProfileStore`, so edits are
/// persisted immediately and picked up by the very next dictation.
@MainActor
struct ProfilesPane: View {
    @ObservedObject var profileStore: ProfileStore
    @State private var selectedID: UUID?
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 0) {
            profileList
                .frame(width: 180)
            Divider()
            if let profile = selectedProfile {
                ProfileEditorForm(
                    profileStore: profileStore,
                    profileID: profile.id,
                    confirmingDelete: $confirmingDelete
                )
            } else {
                Text("Select a profile")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = profileStore.profiles.first?.id
            }
        }
        .confirmationDialog(
            "Delete “\(selectedProfile?.name ?? "")”?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Profile", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps this profile routed will use the default profile instead.")
        }
    }

    private var selectedProfile: Profile? {
        guard let selectedID else { return nil }
        return profileStore.profile(id: selectedID)
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(profileStore.profiles) { profile in
                    Label {
                        Text(profile.name)
                        if profile.routes.contains(.defaultRoute) {
                            Text("Default")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: profile.icon)
                    }
                    .tag(profile.id)
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button {
                    selectedID = profileStore.addProfile().id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a profile")
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(!canDeleteSelected)
                .help(
                    canDeleteSelected
                        ? "Delete the selected profile"
                        : "The default profile cannot be deleted"
                )
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private var canDeleteSelected: Bool {
        guard let profile = selectedProfile else { return false }
        return !profile.routes.contains(.defaultRoute)
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        profileStore.delete(id: id)
        selectedID = profileStore.profiles.first?.id
    }
}

// MARK: - Editor form

/// The right-hand side of the pane. Bindings read the profile fresh from the
/// store and write every change straight back through `ProfileStore.save`,
/// so there is no draft state to desynchronize — what the form shows is what
/// the next dictation resolves.
@MainActor
private struct ProfileEditorForm: View {
    @ObservedObject var profileStore: ProfileStore
    let profileID: UUID
    @Binding var confirmingDelete: Bool

    /// Curated icon choices; the profile's current icon is always included so
    /// a hand-edited value never renders an empty picker.
    private static let iconChoices = [
        "wand.and.stars", "message", "envelope", "terminal", "note.text",
        "person.wave.2", "briefcase", "graduationcap", "globe", "keyboard",
        "doc.text", "bubble.left.and.bubble.right",
    ]

    var body: some View {
        Form {
            identitySection
            cleanupSection
            languageSection
            formattingSection
            chineseSection
            burmeseSection
            routingSection
            managementSection
        }
        .formStyle(.grouped)
    }

    /// The edited profile, read live. The fallback only defends the render
    /// pass that races a deletion; the pane clears the selection right after.
    private var profile: Profile {
        profileStore.profile(id: profileID) ?? Profile(name: "")
    }

    /// Write-through binding: every set persists via the store.
    private func field<Value>(
        _ keyPath: WritableKeyPath<Profile, Value>
    ) -> Binding<Value> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { newValue in
                var updated = profile
                updated[keyPath: keyPath] = newValue
                profileStore.save(updated)
            }
        )
    }

    // MARK: Sections

    private var identitySection: some View {
        Section {
            TextField("Name", text: field(\.name))
            Picker("Icon", selection: field(\.icon)) {
                ForEach(iconChoicesIncludingCurrent, id: \.self) { symbol in
                    Image(systemName: symbol).tag(symbol)
                }
            }
        }
    }

    private var iconChoicesIncludingCurrent: [String] {
        var choices = Self.iconChoices
        if !choices.contains(profile.icon) {
            choices.insert(profile.icon, at: 0)
        }
        return choices
    }

    private var cleanupSection: some View {
        Section("AI cleanup") {
            Toggle("Use AI cleanup in this profile", isOn: field(\.cleanupEnabled))
            Text(
                "Runs only while the global cleanup switch "
                    + "(Settings → Cleanup) is on."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleanup instructions")
                TextEditor(text: field(\.promptText))
                    .font(.body)
                    .frame(minHeight: 80)
            }
            Toggle("Ignore the global style prompt", isOn: field(\.ignoresGlobalStyle))
            TextField("Model override (optional)", text: providerOverrideModel)
            Text(
                "Leave empty to use the model from Settings → Cleanup. Name a "
                    + "different Ollama model to run this profile's cleanup on "
                    + "it — useful when one profile needs a stronger model."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The profile's Ollama model override as editable text (docs/11 G3).
    /// Empty clears the override; only Ollama is offered because it is the one
    /// provider Settings carries a URL for.
    private var providerOverrideModel: Binding<String> {
        Binding(
            get: {
                guard case .ollama(let model)? = profile.providerOverride else { return "" }
                return model
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                var updated = profile
                updated.providerOverride = trimmed.isEmpty ? nil : .ollama(model: trimmed)
                profileStore.save(updated)
            }
        )
    }

    private var languageSection: some View {
        Section("Language") {
            Picker("Language", selection: field(\.languageOverride)) {
                Text("Follow the menu-bar setting").tag(Optional<LanguageMode>.none)
                Text("Auto-detect").tag(Optional(LanguageMode.auto))
                ForEach(Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(Optional(LanguageMode.pinned(language)))
                }
            }
            if profile.languageOverride == .pinned(.burmese) {
                Text(
                    "Dictations in this profile run the dedicated Burmese "
                        + "model (first use downloads ~790 MB)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if profile.cleanupEnabled {
                    // The pin is the per-profile Burmese cleanup opt-in
                    // (docs/04 App. A: cleanup normally skips Burmese).
                    Text(
                        "Pinning မြန်မာ also lets this profile's AI cleanup "
                            + "run on Burmese text, which is otherwise "
                            + "skipped — small local models often corrupt it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var formattingSection: some View {
        Section("Formatting") {
            Toggle("Fix punctuation and capitalization", isOn: field(\.formatting.autoPunctuation))
            Toggle("Smart spacing around insertions", isOn: field(\.formatting.smartSpacing))
            Toggle("Allow paragraphs and bullet lists", isOn: field(\.formatting.structureAllowed))
        }
    }

    private var chineseSection: some View {
        Section("中文") {
            Toggle(
                "Use full-width punctuation（，。）",
                isOn: field(\.formatting.enforceFullWidthZhPunctuation)
            )
            Toggle(
                "Space between Han and Latin text",
                isOn: field(\.formatting.panguSpacing)
            )
        }
    }

    private var burmeseSection: some View {
        Section("မြန်မာ") {
            Picker("Digits", selection: field(\.formatting.myanmarDigits)) {
                ForEach(MyanmarDigits.allCases, id: \.self) { digits in
                    Text(digits.displayName).tag(digits)
                }
            }
            Toggle(
                "Spoken punctuation commands",
                isOn: field(\.formatting.myanmarSpokenPunctuation)
            )
            Text(
                "Turns “full stop” into ။ and “comma” into ၊. English command "
                    + "words only for now — the Myanmar-script commands need "
                    + "native-speaker validation first (docs/11 G18)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var routingSection: some View {
        Section("Automatic routing") {
            if profile.routes.contains(.defaultRoute) {
                Label(
                    "Default profile — used when no other profile matches.",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
            } else {
                Button("Make This the Default Profile") {
                    profileStore.makeDefault(id: profileID)
                }
            }
            RouteListEditor(profile: profile, profileStore: profileStore)
                // Reset the half-typed add-route fields when the selection
                // moves to another profile.
                .id(profileID)
            Stepper(
                "Priority: \(profile.priority)",
                value: field(\.priority),
                in: -100...100
            )
            Text("When two profiles match the same app, the higher priority wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var managementSection: some View {
        Section {
            if !profileStore.persists {
                Label(
                    "The Vocal database could not be opened — profile changes last until quit.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let errorText = profileStore.lastErrorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Delete Profile…", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(profile.routes.contains(.defaultRoute))
            if profile.routes.contains(.defaultRoute) {
                Text("Make another profile the default before deleting this one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Routes

/// The `.app` / `.website` route rows plus the add-route controls. The
/// `.defaultRoute` is deliberately not editable here — it moves only via
/// "Make This the Default Profile", which keeps exactly one owner
/// (docs/05 §4).
@MainActor
private struct RouteListEditor: View {
    let profile: Profile
    let profileStore: ProfileStore

    private enum NewRouteKind: String, CaseIterable {
        case app = "App"
        case website = "Website"
    }

    @State private var newKind: NewRouteKind = .app
    @State private var newValue = ""

    var body: some View {
        ForEach(editableRoutes, id: \.self) { route in
            HStack {
                routeLabel(route)
                Spacer()
                Button {
                    remove(route)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this rule")
            }
        }
        if editableRoutes.isEmpty {
            Text("No app or website rules — this profile is only used when picked by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 6) {
            Picker("", selection: $newKind) {
                ForEach(NewRouteKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 90)
            TextField(
                newKind == .app ? "Bundle ID (com.apple.mail)" : "Hostname (mail.google.com)",
                text: $newValue
            )
            .onSubmit(addTypedRoute)
            Button("Add", action: addTypedRoute)
                .disabled(trimmedNewValue.isEmpty)
        }
        // Nobody knows bundle IDs by heart; offer the apps that are running.
        Menu("Add a Running App…") {
            ForEach(runningApps, id: \.bundleID) { app in
                Button(app.name) { add(.app(bundleID: app.bundleID)) }
            }
        }
    }

    private var editableRoutes: [Route] {
        profile.routes.filter { $0 != .defaultRoute }
    }

    @ViewBuilder
    private func routeLabel(_ route: Route) -> some View {
        switch route {
        case .app(let bundleID):
            Label(bundleID, systemImage: "app")
        case .website(let hostname):
            Label(hostname, systemImage: "globe")
        case .defaultRoute:
            EmptyView()
        }
    }

    private var trimmedNewValue: String {
        newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTypedRoute() {
        let value = trimmedNewValue
        guard !value.isEmpty else { return }
        switch newKind {
        case .app:
            add(.app(bundleID: value))
        case .website:
            // Accept a pasted URL; routing matches hostnames only (docs/05 §4).
            let hostname = URL(string: value)?.host() ?? value
            add(.website(hostname: hostname.lowercased()))
        }
        newValue = ""
    }

    private func add(_ route: Route) {
        var updated = profile
        guard !updated.routes.contains(route) else { return }
        updated.routes.append(route)
        profileStore.save(updated)
    }

    private func remove(_ route: Route) {
        var updated = profile
        updated.routes.removeAll { $0 == route }
        profileStore.save(updated)
    }

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return (name: app.localizedName ?? bundleID, bundleID: bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
