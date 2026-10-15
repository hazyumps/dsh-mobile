import Foundation
import Observation

/// Reuses a paired host's credentials while the app is active. Each return from
/// the background opens a new socket and publishes a new conversation identity.
@MainActor
@Observable
public final class ForegroundConnection {
    public private(set) var status: ConnectionStatus = .offline
    public private(set) var connectionID: UUID?
    public private(set) var error: ConnectionCoordinator.ConnectError?

    private let coordinator: ConnectionCoordinator
    private let sleeper: any RelaySleeper
    private let jitter: @Sendable () -> Double
    private var isForeground = false
    private var hasConnected = false
    private var revision: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        coordinator: ConnectionCoordinator,
        sleeper: any RelaySleeper = TaskRelaySleeper(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
    ) {
        self.coordinator = coordinator
        self.sleeper = sleeper
        self.jitter = jitter
    }

    public func setForeground(_ active: Bool) {
        guard active != isForeground else { return }
        isForeground = active
        revision &+= 1
        let current = revision
        let previous = task
        previous?.cancel()
        connectionID = nil
        status = active ? (hasConnected ? .reconnecting : .connecting) : .offline

        // Serialize teardown with the next attempt. Rapid background/foreground
        // transitions must never let an old shutdown close the replacement socket.
        task = Task {
            await previous?.value
            guard current == revision, !Task.isCancelled else { return }
            guard active else {
                await coordinator.shutdown()
                return
            }
            // A terminal failure is terminal for the *backoff loop*, not for the app. Returning
            // here made the park a dead end: `error` is only cleared by a success, so once a
            // non-retryable failure had been recorded, every later return to the foreground
            // repainted the same status and never dialled again — indistinguishable from a
            // connection that never comes back, and cured only by relaunching the app.
            //
            // A wake therefore earns one fresh attempt. If the cause has cleared, the app recovers
            // by itself; if it has not, the same status returns and ``run(revision:)`` parks again.
            // One attempt per wake cannot hot-loop, which is what SPEC §6.4/§6.9's "stop retrying"
            // protects — and `setForeground` only fires on a genuine phase change, so the app's own
            // lifecycle is the throttle.
            //
            // Reachable in normal use because the relay answers 403 for a Host-fence refusal as
            // well as for a bad credential (#79), so `.pairingRequired` can be wrong. Recovering
            // despite the misclassification is this type's job; correcting it is the relay's.
            await run(revision: current)
        }
    }

    public func stop() async {
        setForeground(false)
        await task?.value
    }

    private func run(revision current: UInt64) async {
        var failures = 0
        while current == revision, !Task.isCancelled {
            status = hasConnected || failures > 0 ? .reconnecting : .connecting
            do {
                try await coordinator.connect()
                guard current == revision, !Task.isCancelled else { break }
                hasConnected = true
                failures = 0
                error = nil
                status = .connected
                connectionID = UUID()

                for await next in await coordinator.statusUpdates() {
                    guard current == revision, !Task.isCancelled else { break }
                    guard next.isUsable else {
                        throw await coordinator.lastError
                            ?? .transportInterruption(detail: "connection closed")
                    }
                }
                if Task.isCancelled || current != revision { break }
                throw ConnectionCoordinator.ConnectError.transportInterruption(detail: "connection closed")
            } catch {
                guard current == revision, !Task.isCancelled else { break }
                let failure = ConnectionCoordinator.failure(from: error)
                self.error = failure
                connectionID = nil
                guard failure.isRetryable else {
                    status = failure.status
                    break
                }
                status = .reconnecting
                let delay = Self.retryDelay(for: failure, attempt: failures, jitter: jitter())
                failures = min(failures + 1, 10)
                do {
                    try await sleeper.sleep(seconds: delay)
                } catch {
                    break
                }
            }
        }
        await coordinator.shutdown()
    }

    static func retryDelay(
        for failure: ConnectionCoordinator.ConnectError, attempt: Int, jitter: Double
    ) -> Double {
        if case .rpc(.rateLimited(let seconds, _)) = failure {
            return max(0, seconds)
        }
        return min(10, 0.5 * pow(2, Double(min(max(attempt, 0), 10))) * max(0.1, jitter))
    }
}
