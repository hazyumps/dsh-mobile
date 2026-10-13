import DSHRemoteKit
import SwiftUI

/// The four screens the harness panel pushes.
///
/// These were sections of one Settings form. They are separate screens now because the
/// drawer's rows *are* the settings — a screen that only lists doors to other screens is a
/// step with nothing in it, and the drawer had already spent the space.
///
/// Nothing moved between them that was not already in Settings: hosts and pairing, the
/// connection's own details, this phone's name, and the reminder permission.

/// The model and preset a new session starts on (SPEC §6).
///
/// A destination rather than a control in the drawer because it is a *default*, not a
/// per-session choice: the choice that matters is made on the new-session screen, next to
/// the project it applies to, and this is where you change what that screen proposes.
struct ModelModeDefaultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSHMetrics.spaceCard) {
                Text("New sessions start on this pair. The choice is staged here and carried on the session when you send the first message — the host locks a preset once a session has started, so it cannot be changed afterwards.")
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ModelModeControls(
                    style: .rows,
                    catalog: model.catalog,
                    isLoading: model.catalogState == .loading,
                    failure: {
                        if case .failed(let reason) = model.catalogState { return reason }
                        return nil
                    }(),
                    selectedMode: model.effectiveMode,
                    selectedModel: model.effectiveModel,
                    isModeStaged: model.stagedMode != nil,
                    isModelStaged: model.stagedModel != nil,
                    onSelectMode: { model.stageMode($0) },
                    onSelectModel: { model.stageModel($0) },
                    onRefresh: { Task { await model.loadModelCatalog() } }
                )
                .padding(DSHMetrics.spaceCard)
                .dshCard()
            }
            .padding(.horizontal, DSHMetrics.pageMargin)
            .padding(.vertical, DSHMetrics.spaceCard)
        }
        .background(DSHPalette.canvas)
        .navigationTitle("Model & mode")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.catalog == nil { await model.loadModelCatalog() } }
    }
}

/// Which harness this phone talks to, and how it is doing.
///
/// The connection's own details live here rather than on a screen of their own: the state,
/// the last error and the pinned key are all answers to "why is this host not working",
/// which is the question you arrive with.
struct HostsPairingView: View {
    @Environment(AppModel.self) private var model

    @State private var isPairing = false
    @State private var pendingForget: SavedHost?

    var body: some View {
        Form {
            Section {
                ForEach(model.hosts) { host in
                    Button {
                        // Switching hosts is explicit and closes the previous connection
                        // (SPEC §11). Selecting the same host again is a no-op.
                        guard host.id != model.selectedHost?.id else { return }
                        Task { await model.select(host) }
                    } label: {
                        HStack(spacing: DSHMetrics.space) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.displayName)
                                    .foregroundStyle(DSHPalette.primaryText)
                                Text(host.origin.absoluteString)
                                    .font(.dshMetadata)
                                    .foregroundStyle(DSHPalette.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: DSHMetrics.space)
                            if host.id == model.selectedHost?.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DSHPalette.primaryActionText)
                                    .accessibilityLabel("Current host")
                            }
                        }
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) { pendingForget = host }
                    }
                }
                if model.hosts.isEmpty {
                    Text("No hosts yet.")
                        .foregroundStyle(DSHPalette.secondaryText)
                }
                Button("Pair a harness", systemImage: "plus") { isPairing = true }
            } header: {
                Text("Hosts")
            } footer: {
                Text("Forgetting a host removes this phone’s credential for it. It does not revoke the device at the relay.")
            }

            Section("Connection") {
                LabeledContent("State") {
                    DSHStatusChip(
                        DSHHostState(model.status).text,
                        tone: DSHHostState(model.status).tone,
                        symbol: DSHHostState(model.status).symbol
                    )
                }
                if let error = model.connectionError {
                    LabeledContent("Last error") {
                        Text(error)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(DSHPalette.secondaryText)
                    }
                }
                if let pin = model.selectedHost?.pinnedFingerprint {
                    LabeledContent("Pinned key") {
                        Text(pin)
                            .font(.dshCode)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(DSHPalette.secondaryText)
                    }
                }
            }
        }
        .navigationTitle("Hosts & pairing")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPairing) {
            PairHarnessView()
        }
        .confirmationDialog(
            "Forget this host?",
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            presenting: pendingForget
        ) { host in
            Button("Forget \(host.displayName)", role: .destructive) {
                model.forget(host)
                pendingForget = nil
            }
            Button("Cancel", role: .cancel) {
                pendingForget = nil
            }
        } message: { host in
            Text("Removes the credential, drafts, and staged files this phone keeps for \(host.displayName). It does not revoke the device at the relay.")
        }
    }
}

/// The name this phone uses when it pairs.
struct ThisPhoneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: Bindable(model).deviceName)
                    .autocorrectionDisabled()
            } footer: {
                Text("The name this phone uses when it pairs with a harness.")
            }
        }
        .navigationTitle("This phone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Reminders for scheduled tasks.
///
/// The permission lives here as well as on the Scheduled tasks screen, because that screen
/// only exists once a host with tasks is selected — and a notification permission that can
/// only be reached from a screen you might never see is one nobody grants.
///
/// `denied` is stated, never silent, and the only offered action is iOS Settings: there is
/// no API to re-ask, and a second `requestAuthorization` returns the same refusal without
/// showing anything, so a button that called it would do nothing at all.
struct RemindersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Notifications") {
                    Text(model.taskNotifications.authorization.dshDescription)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(DSHPalette.secondaryText)
                }
                switch model.taskNotifications.authorization {
                case .notDetermined:
                    Button("Turn on") {
                        Task { await model.taskNotifications.requestAuthorization() }
                    }
                case .denied:
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open iOS Settings", destination: url)
                    }
                default:
                    EmptyView()
                }
                if model.taskNotifications.pendingCount > 0 {
                    LabeledContent("Planned") {
                        Text(model.taskNotifications.pendingCount == 1
                             ? "1 reminder"
                             : "\(model.taskNotifications.pendingCount) reminders")
                            .foregroundStyle(DSHPalette.secondaryText)
                    }
                }
            } footer: {
                Text("A reminder is posted when a scheduled task's next run is due. It says the task is due — not that it ran, which the harness only reports afterwards.")
            }
        }
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.taskNotifications.refreshAuthorization() }
    }
}
