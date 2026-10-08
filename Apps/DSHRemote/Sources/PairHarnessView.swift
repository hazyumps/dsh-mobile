import DSHRemoteKit
import SwiftUI

/// SPEC §3.2: read the payload, say where it points and what it pins, then
/// claim the one-time code and keep the token.
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
                    Section("This host") {
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
                        TextField("This phone's name", text: Bindable(model).deviceName)
                        Button {
                            Task {
                                await model.claim(pasted: pasted)
                                if model.claimError == nil { dismiss() }
                            }
                        } label: {
                            if model.isClaiming {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Claiming…")
                                }
                            } else {
                                Text("Claim pairing")
                            }
                        }
                        .disabled(model.isClaiming)
                    } footer: {
                        if let error = model.claimError {
                            Text(error).foregroundStyle(.red)
                        } else {
                            Text("The relay records this name so you can tell devices apart later.")
                        }
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
