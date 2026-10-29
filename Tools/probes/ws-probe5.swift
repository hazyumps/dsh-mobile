import Foundation

// The last untested difference: the app creates its WebSocket task from a
// URLRequest (GET + Authorization header); every probe so far used a plain URL.
// If that changes what send() does on a refused challenge, it is the hang.

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

func run(_ name: String, seconds: Double = 8, _ body: @escaping () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { await body(); done.signal() }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        print("[\(elapsed())] \(name): PARKED, nothing after \(seconds)s")
    }
}

func session() -> URLSession {
    URLSession(configuration: .ephemeral, delegate: Refuser(), delegateQueue: nil)
}

// Case A: URLRequest with the Authorization header, as the app builds it.
run("A URLRequest + auth header, send") {
    var request = URLRequest(url: URL(string: "wss://192.0.2.10:3443/api/remote.mux")!)
    request.httpMethod = "GET"
    request.setValue("Bearer dummy", forHTTPHeaderField: "Authorization")
    let task = session().webSocketTask(with: request)
    task.resume()
    do { try await task.send(.string("{\"type\":\"open\"}")); print("[\(elapsed())] A send returned") }
    catch { print("[\(elapsed())] A send threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 9)

// Case B: the same, but with a pending receive registered first, as the app does.
run("B URLRequest, pending receive then send") {
    var request = URLRequest(url: URL(string: "wss://192.0.2.10:3443/api/remote.mux")!)
    request.httpMethod = "GET"
    request.setValue("Bearer dummy", forHTTPHeaderField: "Authorization")
    let task = session().webSocketTask(with: request)
    task.resume()
    Task { _ = try? await task.receive() }
    try? await Task.sleep(for: .milliseconds(200))
    do { try await task.send(.string("{\"type\":\"open\"}")); print("[\(elapsed())] B send returned") }
    catch { print("[\(elapsed())] B send threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 9)
exit(0)
