import AppKit
import WebKit

@MainActor final class BridgeTests: NSObject, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var failures = 0
    func start() throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame:NSRect(x:0,y:0,width:700,height:500),configuration:config); web.navigationDelegate = self
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:500),styleMask:[.titled],backing:.buffered,defer:false); window.contentView = web
        web.loadHTMLString("<html><body><h1>测试商品</h1></body></html>",baseURL:URL(string:"https://www.apple.com.cn/shop/product/test001/a"))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let bridge = try String(contentsOfFile:"native/StoreBridge.js",encoding:.utf8)
                let tests = try String(contentsOfFile:"native/BridgeTests.js",encoding:.utf8)
                // Feed the real public page script into an inert script element.
                let raw = try String(contentsOfFile:"tests/fixtures/live/iphoneduo-20260919.html",encoding:.utf8)
                let data = try JSONSerialization.data(withJSONObject:[raw])
                let encoded = String(data:data,encoding:.utf8)!
                let script = bridge + "\nwindow.fixtureHTML = " + encoded + "[0];\n" + tests
                let result = try await web.evaluateJavaScript(script)
                print(result ?? "no result")
                guard let report = result as? [String:Any], report["failed"] as? Int == 0 else { exit(1) }
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"build/native/bridge-test-result.json"),options:.atomic)
                exit(0)
            } catch { print("Bridge tests failed: \(error)"); exit(1) }
        }
    }
}
@main struct BridgeMain {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let test = BridgeTests(); try test.start()
        withExtendedLifetime(test) { app.run() }
    }
}
