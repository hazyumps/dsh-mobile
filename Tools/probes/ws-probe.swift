// ws-probe.swift — measures whether a parked await on a URLSessionWebSocketTask
// resumes when the session-level delegate refuses the server-trust challenge.
//
// Usage: ws-probe <mode> [cancelAfterSeconds] [--after-refusal] [--task-level-challenge]
//   mode: none | receive | ping | send
//     none  = never await anything; observe delegate events only (control run)
//     receive/ping/send = park that await on a live URLSessionWebSocketTask
//   cancelAfterSeconds = call task.cancel() at that time (default: never)
//   --after-refusal    = start the awaited call only AFTER the challenge is refused
//   --task-level-challenge = also implement the task-level challenge delegate
//
// Exit code: 0 = the awaited call resumed; 3 = still parked at the hard deadline.
// Does not touch any repository; writes nothing to disk.

import Foundation

// ---------------------------------------------------------------- utilities

let T0 = DispatchTime.now().uptimeNanoseconds

func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds &- T0) / 1e9 }
func ts() -> String { String(format: "%8.3f", elapsed()) }
func stamp(_ tag: String, _ msg: String) {
    print("[\(ts())s] \(tag.padding(toLength: 10, withPad: " ", startingAt: 0)) \(msg)")
    fflush(stdout)
}
func wallClock() -> String { ISO8601DateFormatter().string(from: Date()) }

func describe(_ error: Error?) -> String {
    guard let error = error else { return "nil" }
    let ns = error as NSError
    var s = "domain=\(ns.domain) code=\(ns.code) \"\(ns.localizedDescription)\""
    if !ns.userInfo.isEmpty {
        let body = ns.userInfo
            .map { key, value -> String in
                var v = "\(value)"
                if v.count > 200 { v = String(v.prefix(200)) + "…" }
                return "\(key)=\(v)"
            }
            .sorted()
            .joined(separator: " | ")
        s += " userInfo={ \(body) }"
    }
    return s
}

var exitCode: Int32 = 0
func finish() { fflush(stdout); exit(exitCode) }

// Set by the delegate when the refusal has been answered.
let refusalLock = NSLock()
var refusalElapsed: Double?

func markRefusal() {
    refusalLock.lock(); refusalElapsed = elapsed(); refusalLock.unlock()
}
func refusalSeen() -> Bool {
    refusalLock.lock(); defer { refusalLock.unlock() }
    return refusalElapsed != nil
}

// ---------------------------------------------------------------- delegate

class Probe: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    let url: URL
    var session: URLSession!
    var task: URLSessionWebSocketTask!

    init(url: URL) {
        self.url = url
        super.init()
        let config = URLSessionConfiguration.ephemeral
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
    }

    // --- session-level challenge handling: the mode under test ---
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        stamp("DELEGATE", "SESSION-level challenge method=\(space.authenticationMethod) "
            + "host=\(space.host):\(space.port) serverTrust=\(space.serverTrust != nil) "
            + "previousFailures=\(challenge.previousFailureCount)")
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            stamp("DELEGATE", "-> .cancelAuthenticationChallenge (deliberate refusal)")
            markRefusal()
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // --- observation only ---
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stamp("TASK-EVENT", "didCompleteWithError(\(describe(error))) "
            + "task.state=\(task.state.rawValue) task.error=\(describe(task.error))")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol proto: String?
    ) {
        stamp("TASK-EVENT", "didOpenWithProtocol \(proto ?? "nil")")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        stamp("TASK-EVENT", "didCloseWith code=\(closeCode.rawValue) "
            + "reason=\(reason.flatMap { String(data: $0, encoding: .utf8) } ?? "nil")")
    }
}

// Variant that ALSO implements the task-level challenge delegate, to test which
// level the system prefers when both exist.
final class BothProbe: Probe {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        stamp("DELEGATE", "TASK-level challenge method=\(challenge.protectionSpace.authenticationMethod) "
            + "host=\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)")
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            stamp("DELEGATE", "-> .cancelAuthenticationChallenge answered from TASK level")
            markRefusal()
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// ---------------------------------------------------------------- arguments

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "receive"
let afterRefusal = args.contains("--after-refusal")
let useTaskLevelChallenge = args.contains("--task-level-challenge")
var cancelAfter: Double?
if args.count > 2, let v = Double(args[2]) { cancelAfter = v }
let hardDeadline: Double = (cancelAfter ?? 0) > 0 ? (cancelAfter! + 12.0) : 18.0

let url = URL(string: "wss://10.1.0.138:3443/api/remote.mux")!
let probe: Probe = useTaskLevelChallenge ? BothProbe(url: url) : Probe(url: url)
let task = probe.task!
let stateQueue = DispatchQueue(label: "probe.state")

stamp("START", "mode=\(mode) taskLevelChallenge=\(useTaskLevelChallenge) "
    + "startAfterRefusal=\(afterRefusal) cancelAfter=\(cancelAfter.map { String($0) } ?? "never") "
    + "hardDeadline=\(hardDeadline)s wall=\(wallClock())")
stamp("START", "url=\(url.absoluteString) requestTimeout=\(probe.session.configuration.timeoutIntervalForRequest)s "
    + "resourceTimeout=\(probe.session.configuration.timeoutIntervalForResource)s "
    + "waitsForConnectivity=\(probe.session.configuration.waitsForConnectivity)")
stamp("START", "pre-resume task.state=\(task.state.rawValue) (0=running 1=suspended 2=canceling 3=completed)")

task.resume()
stamp("RESUME", "task.resume() called; task.state=\(task.state.rawValue)")

// Watchdog 1: cancel the task at T+cancelAfter, if requested.
if let cancelAfter = cancelAfter {
    stateQueue.asyncAfter(deadline: .now() + cancelAfter) {
        stamp("WATCHDOG", "calling task.cancel(with:.goingAway) at t=\(ts())s "
            + "(state before=\(task.state.rawValue))")
        task.cancel(with: .goingAway, reason: nil)
        stamp("WATCHDOG", "task.cancel() returned; task.state=\(task.state.rawValue) "
            + "task.error=\(describe(task.error))")
    }
}

// Watchdog 2: hard deadline -> report still parked and exit 3.
stateQueue.asyncAfter(deadline: .now() + hardDeadline) {
    stamp("WATCHDOG", "HARD DEADLINE \(hardDeadline)s reached: awaited call is STILL PARKED. "
        + "task.state=\(task.state.rawValue) task.error=\(describe(task.error))")
    exitCode = 3
    finish()
}

// State poller: report every transition, heartbeat while nothing changes.
var lastRaw = -1
var tick = 0
let timer = DispatchSource.makeTimerSource(queue: stateQueue)
timer.schedule(deadline: .now(), repeating: 1.0)
timer.setEventHandler {
    tick += 1
    let raw = task.state.rawValue
    if raw != lastRaw {
        lastRaw = raw
        stamp("STATE", "task.state -> \(raw) (0=running 1=suspended 2=canceling 3=completed) "
            + "at t=\(ts())s; task.error=\(describe(task.error))")
    } else if tick % 5 == 0 {
        stamp("STATE", "heartbeat: still state=\(raw) at t=\(ts())s; task.error=\(describe(task.error))")
    }
}
timer.resume()

// ---------------------------------------------------------------- the awaited call

if mode == "none" {
    stamp("NONE", "control run: nothing is awaited; observing delegate events only")
    stateQueue.asyncAfter(deadline: .now() + hardDeadline) {
        stamp("NONE", "control run finished at t=\(ts())s (exit 0)")
        exitCode = 0
        finish()
    }
} else {
    Task {
        if afterRefusal {
            // Wait until the delegate has answered the challenge, then park the call.
            while !refusalSeen() && elapsed() < hardDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            stamp("AWAIT", "starting \(mode)() at t=\(ts())s, "
                + "refusal was answered at t=\(refusalElapsed.map { String(format: "%.3f", $0) } ?? "never")s")
        } else {
            stamp("AWAIT", "starting \(mode)() at t=\(ts())s (immediately after resume)")
        }
        do {
            switch mode {
            case "receive":
                let message = try await task.receive()
                switch message {
                case .string(let s): stamp("AWAIT", "receive() RESUMED OK with .string at t=\(ts())s")
                    _ = s
                case .data(let d): stamp("AWAIT", "receive() RESUMED OK with .data(\(d.count) bytes) at t=\(ts())s")
                @unknown default: stamp("AWAIT", "receive() RESUMED OK (unknown case) at t=\(ts())s")
                }
            case "ping":
                // No async sendPing() on the macOS 27 SDK (only pongReceiveHandler:),
                // so bridge it the way the SDK's own async wrappers do.
                let pingStart = ts()
                stamp("AWAIT", "sendPing() parked at t=\(pingStart)s")
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        if let error = error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }
                stamp("AWAIT", "sendPing() RESUMED OK (pong received) at t=\(ts())s")
            case "send":
                try await task.send(.string("hello"))
                stamp("AWAIT", "send() RESUMED OK at t=\(ts())s")
            default:
                stamp("AWAIT", "unknown mode \(mode)")
            }
        } catch {
            stamp("AWAIT", "\(mode)() RESUMED WITH ERROR at t=\(ts())s -> \(describe(error))")
        }
        stamp("AWAIT", "after await: task.state=\(task.state.rawValue) task.error=\(describe(task.error))")
        exitCode = 0
        stateQueue.asyncAfter(deadline: .now() + 2.0) { finish() }
    }
}

dispatchMain()
