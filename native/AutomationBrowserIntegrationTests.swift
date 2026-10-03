import Foundation

@main struct AutomationBrowserIntegrationTests {
    @MainActor static func main() async throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("asa-integration-\(UUID().uuidString)")
        let browser = BrowserController(isolatedProfileURL:profile, launchHeadless:true)
        defer { browser.stop(); try? FileManager.default.removeItem(at:profile) }
        _ = try await browser.start(attachExisting:false)
        let attached = BrowserController(isolatedProfileURL:profile, launchHeadless:true)
        let attachment = try await attached.start(attachExisting:true)
        precondition(attached.attachedToExisting && attachment.port == browser.info?.port, "Must attach only the profile owner's port")
        attached.stop()
        try await browser.reconnectToTarget()
        let product = "https://www.apple.com.cn/shop/product/demo001/a"
        let bag = "https://www.apple.com.cn/shop/bag"
        let checkout = "https://www.apple.com.cn/shop/checkout"
        let release = Date().addingTimeInterval(4)
        let targetMS = release.timeIntervalSince1970 * 1000
        try await browser.installIsolatedFixtures([
            "https://www.apple.com.cn/shop/account/home": """
            <!doctype html><meta charset="utf-8"><button id="login">登录</button>
            <script>setTimeout(()=>document.querySelector('button').textContent='退出登录',800)</script>
            """,
            product: """
            <!doctype html><meta charset="utf-8"><div id="options">
            <input id="noTradeIn" type="checkbox" checked><input data-autom="noapplecare" type="checkbox" checked></div>
            <button data-autom="continueButton" disabled onclick="this.remove();document.getElementById('options').remove();document.getElementById('add').hidden=false;sessionStorage.setItem('continueCount',String(Number(sessionStorage.getItem('continueCount')||0)+1))">继续</button>
            <button id="add" data-autom="add-to-cart" hidden onclick="sessionStorage.setItem('addCount',String(Number(sessionStorage.getItem('addCount')||0)+1));sessionStorage.setItem('clickedAt',String(Date.now()));setTimeout(()=>{sessionStorage.setItem('hasItem','yes');document.getElementById('feedback').outerHTML='<div role=alert>已加入购物袋</div>';},6000)">加入购物袋</button>
            <div id="feedback" role="alert">已加入购物袋</div>
            <script>setTimeout(()=>document.querySelector('[data-autom=continueButton]').disabled=false,Math.max(0,\(targetMS)-Date.now()))</script>
            """,
            bag: """
            <!doctype html><meta charset="utf-8"><div id="bag"></div><script>
            const has=sessionStorage.getItem('hasItem')==='yes';
            document.getElementById('bag').innerHTML=sessionStorage.getItem('unknownBag')==='yes'?'未识别的购物袋页面':(has?'<div data-autom="bag-item"><a href="\(product)">DEMO001/A</a><select name="quantity"><option value="1" selected>1</option></select></div><button id="checkout">结账</button>':'你的购物袋中没有商品。');
            if(has) document.getElementById('checkout').onclick=()=>{sessionStorage.setItem('checkoutCount',String(Number(sessionStorage.getItem('checkoutCount')||0)+1));location.href='\(checkout)'};
            </script>
            """,
            checkout: "<!doctype html><meta charset='utf-8'><h1>订单摘要</h1><p>配送地址 · 付款方式</p>"
        ])
        let v = Variant(partNumber:"DEMO001/A",family:"demo",selections:[:],label:"fixture",url:product,price:1,comingSoon:true)
        var plan = Plan(name:"integration",source:product,variant:v,catalogHash:"fixture",releaseAt:release)
        plan.executionSeconds = 20
        let target = ProcessInfo.processInfo.systemUptime + release.timeIntervalSinceNow
        let driver = DedicatedAutomationBrowser(controller:browser,plan:plan)
        // Navigation must settle before inspection; a later wrong page is recovered.
        try await driver.openBag()
        let bagPage = try await browser.evaluate("({href:location.href,ready:document.readyState})") as? [String:String] ?? [:]
        precondition(bagPage["href"] == bag && bagPage["ready"] == "complete")
        try await browser.navigate(URL(string:product)!)
        try await browser.waitForPage(URL(string:product)!)
        let recoveredBag = try await driver.observeBag()
        precondition(recoveredBag.bag == "empty", "Wrong page was not recovered")
        _ = try await browser.evaluate("sessionStorage.setItem('unknownBag','yes')")
        try await driver.openBag()
        let unknownBag = try await driver.observeBag()
        precondition(unknownBag.bag == "unknown" && unknownBag.bagDetails["reason"] == "购物袋商品数量或型号无法唯一核验")
        _ = try await browser.evaluate("sessionStorage.removeItem('unknownBag')")
        var pending: [String] = []
        let engine = ManagedAutomation(browser:driver,plan:plan,target:target,persist:{ if let action=$0.pending {pending.append(action)} },event:{phase,message,_ in print("\(phase.rawValue): \(message)")})
        let result = await engine.run()
        precondition(result == .handoff,"Browser integration did not reach checkout: \(result)")
        let counts = try await browser.evaluate("({next:Number(sessionStorage.getItem('continueCount')),add:Number(sessionStorage.getItem('addCount')),checkout:Number(sessionStorage.getItem('checkoutCount')),at:Number(sessionStorage.getItem('clickedAt'))})") as? [String:Double] ?? [:]
        precondition(counts["next"] == 1 && counts["add"] == 1 && counts["checkout"] == 1,"Duplicate or missing click: \(counts)")
        precondition((counts["at"] ?? 0) >= targetMS,"Early purchase click")
        precondition(Date().timeIntervalSince(release) >= 6,"Stale acknowledgement was accepted")
        precondition(pending.contains("product") && pending.contains("checkout"))
        print("PASS: profile-owner attach and original-tab reconnect; full production coordinator + dedicated browser adapter; login auto-resume, Continue→Add with removed options, stale banner ignored, six-second acknowledgement, exact bag, confirmed checkout; all requests intercepted locally")
    }
}
