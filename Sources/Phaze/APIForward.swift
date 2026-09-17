import Foundation
import WebKit

/// The shell's side of Phaze Transport. The view's calls stay relative to its own origin —
/// `/transport/action/<Group>/<action>`, a stream, a direct `/api/*` fence — and land here, on
/// the scheme handler; this forwards each to the API origin and streams the answer back as the
/// scheme task's results. Identity rides with the shell: the cookies the API sets (the session,
/// once signed in) live in this process's cookie store — `HTTPCookieStorage.shared`, the app's
/// own, sandboxed, with expiry, `Secure` and domain scoping honoured by the system — and are sent
/// on every later forward. The view never holds a credential.
///
/// Bodies are handed to the view as they arrive, so a `transport: sse` stream's frames reach it
/// as frames. `Content-Encoding` never reaches the view (URLSession has already decoded, and
/// WebKit hands a scheme-handler body to the parser as given); `Set-Cookie` never does either.
struct APIForward: Sendable {
    let origin: URL
    let viewOrigin: String
    private let session: URLSession
    private let delegate: ForwardDelegate

    init(origin: URL, viewOrigin: String) {
        self.origin = origin
        self.viewOrigin = viewOrigin
        let config = URLSessionConfiguration.default
        // Idle time between bytes, not a total: a held stream is kept alive by its pings.
        config.timeoutIntervalForRequest = 120
        // The API's cookies are the shell's credentials: stored whatever the request's main
        // document (there is none — this is not a browser), sent on every later forward.
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        delegate = ForwardDelegate(viewOrigin: viewOrigin)
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// The API's namespace: the dispatcher's (`/transport/action`, `/transport/stream`,
    /// `/transport/rust`) and the app's endpoints, where a direct fence's path lives.
    static func isAPI(_ path: String) -> Bool {
        path.hasPrefix("/transport/") || path.hasPrefix("/api/")
    }

    /// Request headers that describe the view's origin rather than the request, or that WebKit
    /// would not send anyway; the rest (`Content-Type`, `X-Phaze-Edge`, `Accept`) pass through.
    private static let droppedRequestHeaders: Set<String> = ["host", "origin", "referer", "cookie"]

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url,
                  var target = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
                continuation.finish(throwing: URLError(.badURL))
                return
            }
            target.path = url.path(percentEncoded: false)
            target.percentEncodedQuery = url.query(percentEncoded: true)
            guard let forwardURL = target.url else {
                continuation.finish(throwing: URLError(.badURL))
                return
            }
            var out = URLRequest(url: forwardURL)
            out.httpMethod = request.httpMethod
            for (name, value) in request.allHTTPHeaderFields ?? [:]
            where !Self.droppedRequestHeaders.contains(name.lowercased()) {
                out.setValue(value, forHTTPHeaderField: name)
            }
            out.httpBody = request.httpBody ?? Self.read(request.httpBodyStream)
            if let method = out.httpMethod, method != "GET", method != "HEAD", out.httpBody == nil {
                // A body that WebKit did not hand over would fail every action, silently.
                print("phaze: forward \(method) \(url.path(percentEncoded: false)) — no request body reached the handler")
            }
            let task = session.dataTask(with: out)
            delegate.attach(task, continuation: continuation, viewURL: url)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    /// A body WebKit hands over as a stream rather than bytes.
    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// One delegate for every forwarded task: each task's scheme-task continuation and view URL are
/// kept by task id, and URLSession's calls — response, each data chunk, completion — become the
/// scheme task's results. Serialised by URLSession's own delegate queue; the map is locked for
/// the attach that happens on the caller's side.
final class ForwardDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    fileprivate typealias Continuation = AsyncThrowingStream<URLSchemeTaskResult, any Error>.Continuation

    let viewOrigin: String
    /// `PHAZE_LOG=1` in the environment: one line per forward — method, path, status, bytes.
    private let trace = ProcessInfo.processInfo.environment["PHAZE_LOG"] != nil
    private let lock = NSLock()
    private var tasks: [Int: (continuation: Continuation, viewURL: URL)] = [:]

    init(viewOrigin: String) {
        self.viewOrigin = viewOrigin
    }

    fileprivate func attach(_ task: URLSessionTask, continuation: Continuation, viewURL: URL) {
        lock.lock()
        tasks[task.taskIdentifier] = (continuation, viewURL)
        lock.unlock()
    }

    private func entry(for task: URLSessionTask) -> (continuation: Continuation, viewURL: URL)? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[task.taskIdentifier]
    }

    private func detach(_ task: URLSessionTask) -> Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.removeValue(forKey: task.taskIdentifier)?.continuation
    }

    /// Response headers that must not reach the view: the encoding URLSession already undid and
    /// the length that went with it, the connection's own, and the cookies — those are the shell's.
    private static let droppedResponseHeaders: Set<String> = [
        "content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive", "set-cookie",
    ]

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let entry = entry(for: dataTask) else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            guard let name = name as? String, let value = value as? String else { continue }
            if Self.droppedResponseHeaders.contains(name.lowercased()) { continue }
            headers[name] = value
        }
        // The view's module scripts and fetches run in CORS mode against the exact origin.
        headers["Access-Control-Allow-Origin"] = viewOrigin
        let forView = HTTPURLResponse(
            url: entry.viewURL, statusCode: http?.statusCode ?? 200, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        entry.continuation.yield(.response(forView))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        entry(for: dataTask)?.continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let continuation = detach(task) else { return }
        let method = task.originalRequest?.httpMethod ?? "GET"
        let path = task.originalRequest?.url?.path(percentEncoded: false) ?? "?"
        if let error {
            print("phaze: forward \(method) \(path) failed — \(error.localizedDescription)")
            continuation.finish(throwing: error)
        } else {
            if trace {
                let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                print("phaze: \(method) \(path) → \(status) (\(task.countOfBytesReceived) B)")
            }
            continuation.finish()
        }
    }
}
