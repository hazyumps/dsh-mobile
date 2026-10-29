import Foundation

// Which await parks when the TLS challenge is refused: send or receive?
// The first probe only tested receive, and it resumed in 0.02s. The app's
// socket-open path may instead be awaiting a send, which is a different code
// path inside URLSession.

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
    let task = session.webSocketTask(with: URL(string: "wss://192.0.2.10:3443/api/remote.mux")!)
    task.resume()
    return task
}

func run(_ name: String, seconds: Double = 6, _ body: @escaping () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task {
        await body()
        done.signal()
    }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        print("[\(elapsed())] \(name): STILL PARKED after \(seconds)s")
    }
}

// Case 1: await receive() after the refusal.
run("receive") {
    let task = makeTask()
    do { _ = try await task.receive(); print("[\(elapsed())] receive returned") }
    catch { print("[\(elapsed())] receive threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 7)

// Case 2: await send() after the refusal.
run("send") {
    let task = makeTask()
    do { try await task.send(.string("{\"type\":\"open\"}")); print("[\(elapsed())] send returned") }
    catch { print("[\(elapsed())] send threw \((error as NSError).code)") }
}

Thread.sleep(forTimeInterval: 7)
exit(0)
