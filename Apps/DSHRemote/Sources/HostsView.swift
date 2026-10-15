import DSHRemoteKit
import SwiftUI

/// Where a phone that has not chosen a harness starts: pairing, and the hosts it
/// already knows.
///
/// UX spec "Navigation and returning to work": with no saved host this is the pairing
/// introduction; a cold launch with a valid saved selection goes straight to ``HomeView``
/// instead. Host administration also lives in Settings once a host is current, so this
/// screen is the one you see before there is one — it keeps the pairing flow and the
/// explanation of what pairing does and does not do.
struct HostsView: View {
    @Environment(AppModel.self) private var model
    @State private var isPairing = false
    @State private var pendingForget: SavedHost?

    var body: some View {
        NavigationStack {
            Group {
                if model.hosts.isEmpty {
                    emptyState
                } else {
                    hostList
                }
            }
            .navigationTitle("Harness")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusBadge(status: model.status)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair a harness", systemImage: "plus") { isPairing = true }
                        .labelStyle(.iconOnly)
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
                    Task { await model.forget(host) }
                    pendingForget = nil
                }
                Button("Cancel", role: .cancel) { pendingForget = nil }
            } message: { host in
                Text("Removes the credential, drafts, and staged files this phone keeps for \(host.displayName). It does not revoke the device at the relay.")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No hosts yet", systemImage: "externaldrive.badge.wifi")
        } description: {
            Text("Pair a harness to read its sessions, follow a conversation, and answer what it asks.")
        } actions: {
            Button("Pair a harness") { isPairing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var hostList: some View {
        List {
            // A refused pair used to be visible only inside the pairing sheet,
            // which meant an automatic pair that failed looked exactly like one
            // that never ran. Say it where the hosts are.
            //
            // Two fields, because the flow uses both: a claim that reached the
            // relay and failed lands in `claimError`, while a payload rejected
            // before that lands in `pairingOutcome`. Checking only the second is
            // why the first attempt at this showed nothing.
            if let claimError = model.claimError {
                Label(claimError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if case .refused(let reason) = model.pairingOutcome {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            // A forget that did not fully happen says so where the host is (#65).
            if let hostError = model.hostError {
                Label(hostError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.hosts) { host in
                Button {
                    Task { await model.select(host) }
                } label: {
                    HStack(spacing: DSHMetrics.space) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.displayName)
                                .font(.headline)
                                .foregroundStyle(DSHPalette.primaryText)
                            Text(host.origin.absoluteString)
                                .font(.caption)
                                .foregroundStyle(DSHPalette.secondaryText)
                            if let pin = host.pinnedFingerprint {
                                Label(pin, systemImage: "lock")
                                    .font(.caption2)
                                    .foregroundStyle(DSHPalette.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: DSHMetrics.space)
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(DSHPalette.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                pendingForget = offsets.map { model.hosts[$0] }.first
            }
        }
    }
}
