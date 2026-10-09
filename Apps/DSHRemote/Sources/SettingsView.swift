import DSHRemoteKit
import SwiftUI

/// Settings: which harness this phone talks to, and what it calls itself there.
///
/// UX spec "Settings and secondary sections" gives this screen appearance, host
/// selection and pairing, display name, version, connection details, and redacted
/// diagnostics. Appearance is the system's for now — every colour is a semantic token
/// that already follows it — and diagnostics export needs a screen of its own. What is
/// here is the part that decides *which host* the rest of the app is about, which is a
/// deliberate action per SPEC §11: switching closes the previous connection.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var isPairing = false
    @State private var pendingForget: SavedHost?

    var body: some View {
        @Bindable var model = model

        return NavigationStack {
            Form {
                hostSection
                connectionSection
                identitySection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
                Button("Cancel", role: .cancel) { pendingForget = nil }
            } message: { host in
                Text("Removes the credential, drafts, and staged files this phone keeps for \(host.displayName). It does not revoke the device at the relay.")
            }
        }
    }

    private var hostSection: some View {
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
    }

    private var connectionSection: some View {
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

    private var identitySection: some View {
        Section {
            TextField("Device name", text: Bindable(model).deviceName)
                .autocorrectionDisabled()
        } header: {
            Text("This phone")
        } footer: {
            Text("The name this phone uses when it pairs with a harness.")
        }
    }
}
