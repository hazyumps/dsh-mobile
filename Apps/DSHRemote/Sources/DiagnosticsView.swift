import DSHRemoteKit
import SwiftUI

/// The diagnostic log, as text a person can read before deciding to send it.
///
/// SPEC §11 asks for an export that is explicit and previewable, and this screen is both: the
/// preview *is* the export — the same string `DiagnosticLog.export()` returns — so there is no
/// "what will be sent" question left to answer. Nothing is uploaded anywhere; copying is a
/// deliberate act.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    @State private var didCopy = false

    var body: some View {
        let text = model.diagnosticsText()

        return Group {
            if text.isEmpty {
                ContentUnavailableView(
                    "Nothing recorded yet",
                    systemImage: "stethoscope",
                    description: Text("Connection and resource state changes appear here as they happen.")
                )
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DSHMetrics.spaceCard)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(didCopy ? "Copied" : "Copy") {
                    UIPasteboard.general.string = text
                    didCopy = true
                }
                .disabled(text.isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear", role: .destructive) {
                    model.clearDiagnostics()
                    didCopy = false
                }
                .disabled(text.isEmpty)
            }
        }
    }
}
