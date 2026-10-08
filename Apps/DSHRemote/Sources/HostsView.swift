import DSHRemoteKit
import SwiftUI

/// V1's landing screen. Sessions live under a host, so nothing else can be
/// reached until one is paired — which is why the empty state is an invitation
/// rather than a placeholder.
struct HostsView: View {
    @Environment(AppModel.self) private var model
    @State private var isPairing = false
    @State private var pendingForget: SavedHost?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.hosts.isEmpty {
                    emptyState
                } else {
                    hostList
                }
            }
            .navigationTitle("Hosts")
            .navigationDestination(for: SavedHost.self) { host in
                SessionsView(host: host)
            }
            .task {
                // Verification affordance: open the first host when asked, so the
                // session list and the chat screen can be checked on a simulator
                // where nothing can be tapped. Inert without the variable.
                guard model.shouldOpenFirstHostOnLaunch,
                      path.isEmpty,
                      let first = model.hosts.first
                else { return }
                path.append(first)
            }
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
                    model.forget(host)
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
            ForEach(model.hosts) { host in
                NavigationLink(value: host) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.displayName)
                            .font(.headline)
                        Text(host.origin.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let pin = host.pinnedFingerprint {
                            Label(pin, systemImage: "lock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { offsets in
                pendingForget = offsets.map { model.hosts[$0] }.first
            }
        }
    }
}
