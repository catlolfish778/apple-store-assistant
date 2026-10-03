import Foundation

/// Offline CDP timing rehearsal. Never uses the app's managed profile or Apple pages.
@main
@MainActor
struct ManagedFlowSimulation {
    private static let partNumber = "DEMO001/A"

    static func main() async {
        do {
            try await run()
        } catch {
            fputs("模拟失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func dataURL(_ html: String) -> URL {
        URL(string: "data:text/html;charset=utf-8;base64,\(Data(html.utf8).base64EncodedString())")!
    }

    private static func run() async throws {
        let productURL = dataURL("""
        <!doctype html><html lang="zh"><head><meta charset="utf-8"><title>离线商品模拟</title></head>
        <body><label><input id="noTradeIn" type="checkbox" checked>不折抵换购</label>
        <label><input data-autom="noapplecare" type="checkbox" checked>不加 AppleCare</label>
        <button data-autom="continueButton" disabled onclick="this.hidden=true;document.querySelector('[data-autom=add-to-cart]').hidden=false;window.__asaContinueCount=(window.__asaContinueCount||0)+1">继续</button>
        <button data-autom="add-to-cart" hidden onclick="document.getElementById('feedback').textContent='已加入购物袋'; window.__asaClickCount=(window.__asaClickCount||0)+1">加入购物袋</button>
        <div id="feedback" role="alert"></div></body></html>
        """)
        let bagURL = dataURL("""
        <!doctype html><html lang="zh"><head><meta charset="utf-8"><title>离线购物袋模拟</title></head>
        <body><div data-autom="bag-item"><span>DEMO001/A</span><select name="quantity"><option value="1" selected>1</option></select></div>
        <button onclick="document.getElementById('checkout-result').textContent='模拟结账已点击'">结账</button>
        <div id="checkout-result"></div></body></html>
        """)
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("asa-flow-simulation-\(UUID().uuidString)", isDirectory: true)
        let browser = BrowserController(isolatedProfileURL: profile, launchHeadless: true)
        defer {
            browser.stop()
            try? FileManager.default.removeItem(at: profile)
        }

        var phases: [(String, Double)] = []
        func timed<T>(_ label: String, _ work: () async throws -> T) async throws -> T {
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await work()
            phases.append((label, (ProcessInfo.processInfo.systemUptime - started) * 1000))
            return result
        }

        let info = try await timed("浏览器冷启动/控制连接") {
            try await browser.start(initialURL: productURL, attachExisting: false)
        }
        try await timed("本地商品页加载") { try await browser.waitForPage(productURL) }
        let initial = try await browser.inspectProductPreparation()
        guard initial["state"] as? String == "waiting",
              initial["noTradeIn"] as? Bool == true,
              initial["noAppleCare"] as? Bool == true else {
            throw BrowserControllerError.protocolError("模拟商品页初始状态不符合预期：\(initial)")
        }
        try await timed("预开售单次刷新与新文档确认") { try await browser.reloadExpectedProductPage(productURL) }
        let noFeedback = try await browser.waitForAddFeedback(maxWaitSeconds: 0.2)
        guard !noFeedback else { throw BrowserControllerError.protocolError("未点击时不应出现加购反馈") }

        let target = Date().addingTimeInterval(1.5)
        let releaseDelayMS = max(0, Int(target.timeIntervalSinceNow * 1000))
        _ = try await browser.evaluate("setTimeout(() => { document.querySelector('[data-autom=continueButton]').disabled=false; window.simUnlockedAt=Date.now(); }, \(releaseDelayMS)); true")
        var preparationCalls = 0
        var preparationMS: [Double] = []
        var readyObservedAt: Date?
        while Date() < target.addingTimeInterval(2) {
            let started = ProcessInfo.processInfo.systemUptime
            let state = try await browser.inspectProductPreparation()
            preparationMS.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            preparationCalls += 1
            if Date() >= target, state["state"] as? String == "ready" {
                readyObservedAt = Date()
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let readyObservedAt else { throw BrowserControllerError.protocolError("模拟开售后仍未识别到可继续状态") }
        let continueClick = try await timed("继续阶段点击控制往返") {
            try await browser.clickProductAction(expectedURL: productURL.absoluteString)
        }
        guard continueClick["state"] as? String == "clicked", continueClick["kind"] as? String == "continue" else {
            throw BrowserControllerError.protocolError("模拟继续按钮未发出：\(continueClick)")
        }
        let progress = try await timed("继续后加购阶段确认") {
            try await browser.waitForContinueProgress(expectedURL: productURL)
        }
        guard progress == "add_ready" else { throw BrowserControllerError.protocolError("继续后没有进入加购阶段：\(progress)") }
        let click = try await timed("加购点击控制往返") {
            try await browser.clickProductAction(expectedURL: productURL.absoluteString)
        }
        guard click["state"] as? String == "clicked", click["kind"] as? String == "add" else {
            throw BrowserControllerError.protocolError("模拟加购未发出：\(click)")
        }
        let acknowledged = try await timed("加购反馈确认") { try await browser.waitForAddFeedback() }
        guard acknowledged else { throw BrowserControllerError.protocolError("模拟加购没有反馈") }
        let clickCounts = try await browser.evaluate("({next:window.__asaContinueCount||0,add:window.__asaClickCount||0})") as? [String: Int] ?? [:]
        guard clickCounts["next"] == 1, clickCounts["add"] == 1 else { throw BrowserControllerError.protocolError("模拟发生重复点击：\(clickCounts)") }
        try await timed("本地购物袋导航/加载") {
            try await browser.navigate(bagURL)
            try await browser.waitForPage(bagURL)
        }
        let bag = try await timed("购物袋型号/数量核验") {
            try await browser.inspectBag(expectedPartNumber: partNumber, requireOfficialLocation: false)
        }
        guard bag["state"] as? String == "confirmed" else {
            throw BrowserControllerError.protocolError("模拟购物袋未核验通过：\(bag)")
        }
        let checkout = try await timed("结账点击控制往返") { try await browser.clickCheckout() }
        guard checkout["state"] as? String == "clicked" else {
            throw BrowserControllerError.protocolError("模拟结账未发出：\(checkout)")
        }
        let result = try await browser.evaluate("document.getElementById('checkout-result').textContent") as? String
        guard result == "模拟结账已点击" else { throw BrowserControllerError.protocolError("模拟结账按钮未响应") }

        let criticalLabels: Set<String> = ["继续阶段点击控制往返", "继续后加购阶段确认", "加购点击控制往返", "加购反馈确认", "本地购物袋导航/加载", "购物袋型号/数量核验", "结账点击控制往返"]
        let criticalMS = phases.filter { criticalLabels.contains($0.0) }.reduce(0) { $0 + $1.1 }
        let sortedChecks = preparationMS.sorted()
        let p50 = sortedChecks[sortedChecks.count / 2]
        let p95 = sortedChecks[min(sortedChecks.count - 1, Int(Double(sortedChecks.count) * 0.95))]
        print("离线模拟成功 · \(info.browserName) · 临时隔离资料目录 · 不访问 Apple · 不产生订单")
        print(String(format: "开售前后检查 %d 次，单次 P50 %.1f ms / P95 %.1f ms", preparationCalls, p50, p95))
        print(String(format: "T0 后识别到可继续：%.1f ms", readyObservedAt.timeIntervalSince(target) * 1000))
        for (label, ms) in phases { print(String(format: "%@：%.1f ms", label, ms)) }
        print(String(format: "识别到可继续 → 结账点击完成（本地页面）：%.1f ms", criticalMS))
    }
}
