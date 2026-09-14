#if os(macOS)
import AppKit
import WebKit

/// Answers `drag()` from `@madenowhere/phaze-native/swift`. WKWebView keeps the mouse, so the
/// page posts `drag` on a primary press in its drag region, and this runs AppKit's window drag
/// with the event being dispatched.
final class DragHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? String == "drag", let event = NSApp.currentEvent,
              let window = message.webView?.window ?? NSApp.keyWindow else { return }
        window.performDrag(with: event)
    }
}
#endif
