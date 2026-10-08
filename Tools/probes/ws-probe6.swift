import Foundation

// The combination never tested: a send issued while a receive is STILL PENDING,
// with the challenge refused afterwards. Event probes either refused before the
// send (probe 3, 5B) or let the pending receive fail first (probe 4).
//
// A: app's ordering — resume, start receive, send at once; refusal lands with
//    both calls in flight.
// B: control — the refusal completes first, then the send.

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
    var request = URLRequest(url: URL(string: "wss://10.1.0.138:3443/api/remote.mux")!)
    request.httpMethod = "GET"
    request.setValue("Bearer dummy", forHTTPHeaderField: "Authorization")
    let task = session.webSocketTask(with: request)
    task.resume()
    return task
}

func run(_ name: String, seconds: Double = 8, _ body: @escaping () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { await body(); done.signal() }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        print("[\(elapsed())] \(name): PARKED, nothing after \(seconds)s")
    }
}

// A: send while the receive is still outstanding and the refusal is still to come.
run("A send with receive in flight during refusal") {
    let task = makeTask()
    Task { _ = try? await task.receive() }
    print("[\(elapsed())] A sending now")
    do { try await task.send(.string("{\"type\":\"open\"}")); print("[\(elapsed())] A send returned") }
    catch { print("[\(elapsed())] A send threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 9)

// B: let the refusal and the pending receive finish first.
run("B send after the refusal settled") {
    let task = makeTask()
    Task { _ = try? await task.receive() }
    try? await Task.sleep(for: .milliseconds(500))
    print("[\(elapsed())] B sending now")
    do { try await task.send(.string("{\"type\":\"open\"}")); print("[\(elapsed())] B send returned") }
    catch { print("[\(elapsed())] B send threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 9)
exit(0)
