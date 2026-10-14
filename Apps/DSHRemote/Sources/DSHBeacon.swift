import DSHRemoteKit
import Foundation

/// A one-line trace of the decisions path, switched on by `DSH_TRACE` in debug builds.
///
/// This exists because the failure it was written for looks like nothing at all — a session
/// list with no "needs your input" badge — and there is no other way to see whether the
/// `$events` subscription was ever established. It writes to stdout, so
/// `xcrun simctl launch --console-pty` shows it.
///
/// The type exists in every configuration and is inert outside DEBUG. It used to be wrapped in
/// `#if DEBUG` whole, which left its unguarded call sites in `AppModel` failing to compile in
/// Release — unnoticed, because only Debug was ever built (#64). Keeping the type and emptying
/// the bodies means a new call site cannot reintroduce that, and the messages are autoclosures
/// so a release build never formats them.
enum DSHBeacon {
    #if DEBUG
    private static let isOn = ProcessInfo.processInfo.environment["DSH_TRACE"] != nil
    #else
    private static let isOn = false
    #endif

    static func note(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard isOn else { return }
        print("[dsh] \(message())")
        #endif
    }

    static func event(_ event: RemoteEvent) {
        #if DEBUG
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
        #endif
    }
}
