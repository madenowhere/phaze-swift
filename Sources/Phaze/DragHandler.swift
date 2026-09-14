#if os(macOS)
import AppKit
import WebKit

/// Answers the drag script `PhazeRouter` injects. WKWebView keeps the mouse, so the script posts
/// `drag` on a primary press in the page's drag region, and this runs AppKit's window drag with
/// the event being dispatched.
final class DragHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? String == "drag", let event = NSApp.currentEvent,
              let window = message.webView?.window ?? NSApp.keyWindow else { return }
        window.performDrag(with: event)
    }
}
#endif
