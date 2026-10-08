import Foundation

// Two questions about the exact budget shape the coordinator uses:
//   A. when the operation throws at once, does the group return its error
//      promptly, or does the cancelled sleeper get in the way?
//   B. when the operation parks on a continuation that is never resumed, does
//      the group ever return — even though the sleeper fires?
// B is the shape of the app's hang, and it does not involve URLSession at all.

enum BudgetError: Error { case expired }

func withBudget<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw BudgetError.expired
        }
        guard let first = try await group.next() else { throw BudgetError.expired }
        group.cancelAll()
        return first
    }
}

let t0 = Date()
func elapsed() -> String { String(format: "%6.2f", Date().timeIntervalSince(t0)) }

// A: the operation throws immediately; the sleeper is cancelled at once.
let doneA = DispatchSemaphore(value: 0)
Task {
    do { _ = try await withBudget(seconds: 5) { throw BudgetError.expired }; print("[\(elapsed())] A returned") }
    catch { print("[\(elapsed())] A threw \(error)") }
    doneA.signal()
}
if doneA.wait(timeout: .now() + 8) == .timedOut { print("[\(elapsed())] A PARKED past 8s") }

Thread.sleep(forTimeInterval: 1)

// B: the operation parks on a continuation that never resumes, and ignores
// cancellation — which is what a stuck socket call looks like from here.
let doneB = DispatchSemaphore(value: 0)
Task {
    do {
        _ = try await withBudget(seconds: 2) { () -> Int in
            await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in
                // Never resumed, by design.
            }
        }
        print("[\(elapsed())] B returned")
    } catch { print("[\(elapsed())] B threw \(error)") }
    doneB.signal()
}
if doneB.wait(timeout: .now() + 10) == .timedOut {
    print("[\(elapsed())] B PARKED past 10s even though the 2s budget fired")
}

exit(0)
