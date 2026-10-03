import Foundation

/// In-app rehearsal uses the SAME coordinator with a local simulated website.
/// No real account, remote browser, bag, or order is touched.
@MainActor
final class DemoAutomationBrowser: AutomationBrowser {
    var connected = false
    private var page = "account"
    private var productClicks = 0
    func connect() async throws { connected = true }
    func reconnect() async throws { connected = true }
    func openAccount() async throws { page = "account" }
    func observeAccount() async throws -> AutomationObservation { AutomationObservation(loggedIn: true) }
    func openBag() async throws { page = "bag" }
    func observeBag() async throws -> AutomationObservation { AutomationObservation(bag: productClicks >= 2 ? "confirmed" : "empty") }
    func openProduct(reload: Bool) async throws { page = "product" }
    func observeProduct() async throws -> AutomationObservation { AutomationObservation(configurationReady: true, actionReady: true) }
    func clickProduct() async throws -> AutomationClick {
        productClicks += 1
        return AutomationClick(state: "clicked", kind: productClicks == 1 ? "continue" : "add")
    }
    func observeProgress() async throws -> AutomationObservation {
        if page == "checkout" { return AutomationObservation(progress: "checkout") }
        return AutomationObservation(actionReady: true, progress: productClicks == 1 ? "add_ready" : "acknowledged")
    }
    func clickCheckout() async throws -> AutomationClick { page = "checkout"; return AutomationClick(state: "clicked", kind: "checkout") }
}
