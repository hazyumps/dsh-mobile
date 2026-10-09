#if DEBUG
import DSHRemoteKit
import Foundation

/// Debug builds only: a one-line trace of the decisions path, switched on by `DSH_TRACE`.
///
/// This exists because the failure it was written for looks like nothing at all — a session
/// list with no "needs your input" badge — and there is no other way to see whether the
/// `$events` subscription was ever established. It writes to stdout, so
/// `xcrun simctl launch --console-pty` shows it; release builds have none of it.
enum DSHBeacon {
    private static let isOn = ProcessInfo.processInfo.environment["DSH_TRACE"] != nil

    static func note(_ message: String) {
        guard isOn else { return }
        print("[dsh] \(message)")
    }

    static func event(_ event: RemoteEvent) {
        guard isOn else { return }
        switch event {
        case .waterfall(let waterfall):
            note("waterfall \(waterfall.event) session=\(waterfall.agentId) id=\(waterfall.eventId)")
        case .cancel(let id):
            note("cancel \(id)")
        case .ready:
            break
        case .emit(let name, _):
            note("emit \(name)")
        case .unknown(let type):
            note("unknown event \(type)")
        }
    }
}
#endif
