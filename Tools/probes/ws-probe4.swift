import Foundation

// The app registers a receive loop *before* it sends the open frame. The two
// earlier probes tested send and receive separately, never both. If a pending
// receive changes what send does on a refused challenge, that is the hang.

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

func makeTask() -> URLSessionWebSocketTask {
    let session = URLSession(configuration: .ephemeral, delegate: Refuser(), delegateQueue: nil)
    let task = session.webSocketTask(with: URL(string: "wss://10.1.0.138:3443/api/remote.mux")!)
    task.resume()
    return task
}

func run(_ name: String, seconds: Double = 8, _ body: @escaping () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { await body(); done.signal() }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        print("[\(elapsed())] \(name): PARKED, no result after \(seconds)s")
    }
}

// Case 1: the app's order — a receive is already parked when send is called.
run("A pending-receive then send") {
    let task = makeTask()
    Task { _ = try? await task.receive() }
    try? await Task.sleep(for: .milliseconds(200))
    print("[\(elapsed())] A calling send")
    do { try await task.send(.string("x")); print("[\(elapsed())] A send returned") }
    catch { print("[\(elapsed())] A send threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 9)

// Case 2: control — the earlier probe's order, send with nothing else pending.
run("B send alone") {
    let task = makeTask()
    print("[\(elapsed())] B calling send")
    do { try await task.send(.string("x")); print("[\(elapsed())] B send returned") }
    catch { print("[\(elapsed())] B send threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 9)
exit(0)
