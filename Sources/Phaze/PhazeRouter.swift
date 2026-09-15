import SwiftUI
import WebKit

/// A phaze-native app in a SwiftUI `WebView`, with its route as observable state.
///
/// The router owns the `WebPage` a `WebView` shows and serves the app's build directory at
/// `<scheme>://localhost`. `path` is the route on screen: it follows every navigation the phaze
/// router makes, and setting it navigates the phaze router, so a `List` selection bound to it
/// both shows and drives the page. Build the app with `native({ shell: 'swift', router: true })`.
///
/// ```swift
/// @State private var phaze = PhazeRouter(dist: distURL, scheme: "app")
///
/// NavigationSplitView {
///     List(selection: $phaze.path) { … }
/// } detail: {
///     WebView(phaze.page)
/// }
/// ```
@MainActor
@Observable
public final class PhazeRouter {
    /// The page a `WebView` shows.
    public let page: WebPage

    /// Serves `dist` at `<scheme>://localhost` and drags the window from the page's
    /// `[data-tauri-drag-region]`, the attribute Tauri's shell honours, so markup moves between
    /// shells. Load the app with `page.load(_:)`.
    ///
    /// `api` is the origin the app's Phaze Transport calls are forwarded to — the page keeps
    /// calling `/transport/*` and `/api/*` on its own origin, and the shell carries them to the
    /// cloud with its own credentials, the session cookie the API sets living in this process's
    /// cookie store (see `APIForward`). Without it those paths are a 404, like any other miss.
    public init(dist: URL, scheme: String = "app", api: URL? = nil) {
        guard let urlScheme = URLScheme(scheme) else {
            preconditionFailure("PhazeRouter: '\(scheme)' is not a valid URL scheme")
        }
        let origin = "\(scheme)://localhost"
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers[urlScheme] = DistHandler(
            root: dist, origin: origin, forward: api.map { APIForward(origin: $0, pageOrigin: origin) }
        )
        #if os(macOS)
        // A primary-button mousedown inside `[data-tauri-drag-region]` posts `drag`; the shell
        // runs AppKit's window drag with that event.
        configuration.userContentController.add(DragHandler(), name: "drag")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            addEventListener('mousedown', (e) => {
              if (e.button !== 0 || !(e.target instanceof Element)) return
              if (!e.target.closest('[data-tauri-drag-region]') || e.target.closest('[data-no-drag]')) return
              window.webkit.messageHandlers.drag.postMessage('drag')
            }, true)
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #endif
        page = WebPage(configuration: configuration)
    }

    /// The route on screen, or `nil` before the first load. Reading it follows `WebPage.url`,
    /// which moves on the router's `pushState` as well as on a full load. Setting it runs what
    /// `go()` compiles to — push the path, then the `popstate` the phaze router listens for —
    /// so the router fetches the route's document and swaps the page.
    public var path: String? {
        get {
            page.url.map { url in
                let path = url.path(percentEncoded: false)
                return path.isEmpty ? "/" : path
            }
        }
        set {
            guard let newValue, newValue != path else { return }
            Task {
                _ = try? await page.callJavaScript(
                    "history.pushState(null, '', path); dispatchEvent(new PopStateEvent('popstate'))",
                    arguments: ["path": newValue]
                )
            }
        }
    }
}
