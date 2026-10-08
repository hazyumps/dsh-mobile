import SwiftUI

/// V1's landing screen. Sessions live under a host, so nothing else can be
/// reached until one is paired — which is why the empty state is an invitation
/// rather than a placeholder.
struct HostsView: View {
    @Environment(AppModel.self) private var model
    @State private var isPairing = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No hosts yet", systemImage: "externaldrive.badge.wifi")
            } description: {
                Text("Pair a harness to read its sessions, follow a conversation, and answer what it asks.")
            } actions: {
                Button("Pair a harness") { isPairing = true }
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Hosts")
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
        }
    }
}

/// Text and symbol, never colour alone.
struct StatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}
