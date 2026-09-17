import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the app's shipped directory — the views marked `artifact: true` and the assets. A
/// route's path resolves to its document, `<route>/index.html`, anything else to the file itself.
/// Responses carry the exact origin as `Access-Control-Allow-Origin`, because the page's module
/// scripts load in CORS mode. With an API origin, the API's namespace — `/transport/*` and
/// `/api/*` — is forwarded there instead (`APIForward`), with the shell's credentials. With the
/// app's own worker (`views`), anything the directory does not hold — a view the server serves,
/// an asset of its build — is requested there the same way, with the same credentials, so the
/// worker's guard sees the app's session; without one a miss is a loud 404.
struct RequestHandler: URLSchemeHandler {
    let root: URL
    let origin: String
    let forward: APIForward?
    let views: APIForward?

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        if let forward, let path = request.url?.path(percentEncoded: false), APIForward.isAPI(path) {
            return forward.reply(for: request)
        }
        if let views, let path = request.url?.path(percentEncoded: false), resolve(path) == nil {
            return views.reply(for: request)
        }
        return AsyncThrowingStream { continuation in
            guard let url = request.url else {
                continuation.finish(throwing: URLError(.badURL))
                return
            }
            let path = url.path(percentEncoded: false)
            guard let file = resolve(path), let data = try? Data(contentsOf: file) else {
                print("phaze: 404 \(path)")
                continuation.yield(.response(HTTPURLResponse(
                    url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!))
                continuation.yield(.data(Data("not found".utf8)))
                continuation.finish()
                return
            }
            continuation.yield(.response(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": Self.mimeType(for: file.pathExtension),
                    "Content-Length": String(data.count),
                    "Access-Control-Allow-Origin": origin,
                ]
            )!))
            continuation.yield(.data(data))
            continuation.finish()
        }
    }

    /// The file a request path names: the file itself, or the route document inside the
    /// directory of that name. Never a path outside `root`.
    private func resolve(_ path: String) -> URL? {
        let base = root.standardizedFileURL
        let target = base.appending(path: String(path.drop(while: { $0 == "/" }))).standardizedFileURL
        let basePath = base.path(percentEncoded: false)
        let targetPath = target.path(percentEncoded: false)
        guard targetPath == basePath || targetPath.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/") else {
            return nil
        }
        for candidate in [target, target.appending(path: "index.html")] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false), isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension {
        case "html": "text/html"
        case "js": "text/javascript"
        case "css": "text/css"
        case "json": "application/json"
        case "wasm": "application/wasm"
        case "svg": "image/svg+xml"
        default: UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
