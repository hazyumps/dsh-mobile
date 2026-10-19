import Foundation

/// The one connection failure the user can act on from the phone: a pin the
/// relay no longer presents. SPEC §6.9: "TLS pin mismatch: stop; show
/// certificate changed", and the app's half of that is to **offer re-pair**.
///
/// Logic lives in the kit (this file) so the rule is tested without a screen;
/// the views render whatever this decides.
public enum ConnectionNotice {
    /// The certificate-changed notice is exactly the pair of a
    /// ``ConnectionStatus/hostUnavailable`` status and the
    /// ``ConnectionCoordinator/ConnectError/certificateChanged`` error that
    /// caused it.
    ///
    /// Neither half alone says it: the status is a closed six-word list
    /// (SPEC §3.1) with no certificate word — ``ConnectionStatus``'s own
    /// "unverified" note prescribes deciding "from the carried error, not from
    /// the status alone" — and a carried error outlives the attempt that set
    /// it, so it must not notice once the connection is usable.
    public static func certificateChanged(
        status: ConnectionStatus,
        lastError: ConnectionCoordinator.ConnectError?
    ) -> Bool {
        // Stub carried by the Tests: commit of issue-89: the rule always
        // returns false, which the red table fails on its one true case.
        false
    }
}
