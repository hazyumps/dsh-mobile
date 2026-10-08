import Foundation

// The difference that may explain the app's hang:
//   receive() awaited *while* the refusal happens  -> throws -999 immediately (probe 1)
//   receive() awaited *after* the task has already failed -> does it throw, or park?
// If it parks, then any drain loop started after the socket failed is a permanent
// hang, and a connect path that joins that task never returns.

let t0 = Date()
func elapsed() -> String { String(format: "%6.2f", Date().timeIntervalSince(t0)) }

final class Refuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        print("[\(elapsed())] refusing challenge")
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

func run(_ name: String, seconds: Double = 6, _ body: @escaping () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { await body(); done.signal() }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        print("[\(elapsed())] \(name): STILL PARKED after \(seconds)s (no error)")
    }
}

func makeTask() -> URLSessionWebSocketTask {
    let session = URLSession(configuration: .ephemeral, delegate: Refuser(), delegateQueue: nil)
    let task = session.webSocketTask(with: URL(string: "wss://10.1.0.138:3443/api/remote.mux")!)
    task.resume()
    return task
}

// Case A: receive immediately after resume (the control, already known).
run("A immediate receive") {
    let task = makeTask()
    do { _ = try await task.receive(); print("[\(elapsed())] A returned") }
    catch { print("[\(elapsed())] A threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 7)

// Case B: let the refusal happen first, then receive on the dead task.
let late = makeTask()
print("[\(elapsed())] B: task created, letting the refusal land")
Thread.sleep(forTimeInterval: 3)
run("B late receive") {
    do { _ = try await late.receive(); print("[\(elapsed())] B returned") }
    catch { print("[\(elapsed())] B threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 7)

// Case C: same, but a send on the dead task.
let lateSend = makeTask()
Thread.sleep(forTimeInterval: 3)
run("C late send") {
    do { try await lateSend.send(.string("x")); print("[\(elapsed())] C returned") }
    catch { print("[\(elapsed())] C threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 7)
exit(0)
