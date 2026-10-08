import SwiftUI

/// The first half of SPEC §3.2: read the payload, say where it points and what
/// it pins, and refuse anything malformed before a credential exists.
///
/// Claiming the code is the second half and needs the network layer, so the
/// button says so rather than pretending to work.
struct PairHarnessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pairing JSON", text: $pasted, axis: .vertical)
                        .lineLimit(6, reservesSpace: true)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: pasted) { _, newValue in
                            model.inspect(pasted: newValue)
                        }
                } header: {
                    Text("Pairing data")
                } footer: {
                    Text("Scan the QR on the relay's pairing page, or copy that JSON here. The code is single use and expires in five minutes.")
                }

                switch model.pairingOutcome {
                case .none:
                    EmptyView()
                case .accepted(let summary):
                    Section("This would pair") {
                        LabeledContent("Host", value: summary.host)
                        LabeledContent("Code", value: summary.code)
                        LabeledContent("Expires") {
                            Text(summary.expiresAt, style: .relative)
                        }
                        if let fingerprint = summary.fingerprint {
                            LabeledContent("Pinned key") {
                                Text(fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Section {
                        Button("Claim pairing") {}
                            .disabled(true)
                    } footer: {
                        Text("Claiming needs the transport layer, which is not wired yet.")
                    }
                case .refused(let reason):
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Pair a harness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
