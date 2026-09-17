#if os(macOS)
import AppKit
import WebKit

/// Answers the drag script `PhazeRouter` injects. WKWebView keeps the mouse, so the script posts
/// `drag` on a primary press in the view's drag region, and this runs AppKit's window drag with
/// the event being dispatched. WebKit installs a handler in every frame and the script runs only in
/// the main frame, so a message from any other frame is ignored.
final class DragHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.body as? String == "drag", let event = NSApp.currentEvent,
              let window = message.webView?.window ?? NSApp.keyWindow else { return }
        window.performDrag(with: event)
    }
}
#endif
