import Foundation

/// Adapts the dedicated Chromium tab to the production coordinator.
@MainActor
final class DedicatedAutomationBrowser: AutomationBrowser {
    let controller: BrowserController
    let plan: Plan
    private var actionID = ""
    var connected: Bool { controller.isConnected }
    private let accountURL = URL(string: "https://www.apple.com.cn/shop/account/home")!
    private let bagURL = URL(string: "https://www.apple.com.cn/shop/bag")!
    init(controller: BrowserController, plan: Plan) { self.controller = controller; self.plan = plan }

    func connect() async throws { _ = try await controller.start(initialURL: accountURL) }
    func reconnect() async throws { try await controller.reconnectToTarget() }
    func openAccount() async throws {
        // Do not refresh/revisit an account page while Apple is rendering its
        // login form. The coordinator calls this only once per login episode.
        let current = try? await controller.evaluate("location.href") as? String
        if let current, isManagedAccountPage(current) { return }
        try await controller.navigate(accountURL)
    }
    func openBag() async throws {
        try await controller.navigate(bagURL)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try Task.checkCancellation()
            let (facts, href, ready) = try await accountFacts()
            // Let the coordinator resume its existing login/verification flow.
            if facts.requiresLogin || facts.challenge { return }
            if isBagPage(href) && ready == "complete" { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserControllerError.protocolError("购物袋页面未在限定时间内完成加载")
    }
    private func isBagPage(_ href: String) -> Bool {
        guard let url = URL(string: href) else { return false }
        return url.scheme == bagURL.scheme && url.host == bagURL.host && url.path == bagURL.path
    }
    func openProduct(reload: Bool) async throws {
        guard let url = URL(string: plan.variant.url), officialProductURL(plan.variant.url) else { throw AppError("商品网址无效") }
        let facts = try? await controller.evaluate("({href:location.href,ready:document.readyState})") as? [String: Any]
        let observed = URL(string: facts?["href"] as? String ?? "")
        let same = observed?.host == url.host && observed?.path == url.path
        if reload && same { try await controller.reloadExpectedProductPage(url) }
        else {
            if !same { try await controller.navigate(url) }
            try await controller.waitForPage(url)
        }
    }

    static func accountExpression() -> String {
        """
        (() => {
          const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const text = (document.body?.innerText || '').replace(/\\s+/g,' ');
          const controls = [...document.querySelectorAll('a,button,[role=button]')].filter(visible)
            .map(e => (e.innerText || e.getAttribute('aria-label') || '').trim());
          const challenge = /验证你的身份|验证您的身份|输入验证码|安全验证|verify your identity/i.test(text);
          const login = /\\/shop\\/(signin|login)(\\/|$)/i.test(location.pathname) ||
            [...document.querySelectorAll('input[type=password]')].some(visible);
          const logged = controls.some(v => /^(退出登录|退出账户|退出|Sign Out|Account Settings)$/i.test(v)) ||
            [...document.querySelectorAll('[data-autom*="signout" i],[data-autom*="account-name" i],[aria-label*="退出" i]')].some(visible);
          return {href:location.href, ready:document.readyState, loggedIn:logged, loginRequired:login, challenge};
        })()
        """
    }
    private func accountFacts() async throws -> (AutomationObservation, String, String) {
        let facts = try await controller.evaluate(Self.accountExpression()) as? [String: Any] ?? [:]
        let href = facts["href"] as? String ?? ""
        let trusted = managedStoreURL(href)
        var result = AutomationObservation()
        result.loggedIn = trusted && facts["loggedIn"] as? Bool == true
        result.requiresLogin = facts["loginRequired"] as? Bool == true
        result.challenge = facts["challenge"] as? Bool == true
        return (result, href, facts["ready"] as? String ?? "loading")
    }
    func observeAccount() async throws -> AutomationObservation {
        var (result, _, ready) = try await accountFacts()
        // Apple can ask for authentication again at checkout. Recognize the
        // signed-in account marker on any trusted Apple Store page so the
        // coordinator does not navigate away from the checkout challenge.
        result.loggedIn = result.loggedIn && ready != "loading"
        if result.requiresLogin && !result.challenge {
            if try await controller.attemptSavedAppleLogin() == "challenge" { result.challenge = true }
        }
        return result
    }
    func observeBag() async throws -> AutomationObservation {
        var (result, href, ready) = try await accountFacts()
        if !result.requiresLogin && !result.challenge && !isBagPage(href) {
            try await openBag()
            (result, href, ready) = try await accountFacts()
        }
        let url = URL(string: href)
        result.bagDetails = ["page": managedStoreURL(href) ? "\(url?.host ?? "")\(url?.path ?? "")" : "非官网页面", "ready": ready]
        if result.requiresLogin || result.challenge { return result }
        if !isBagPage(href) || ready != "complete" {
            result.bagDetails["reason"] = "购物袋页面尚未就绪"
            return result
        }
        let bag = try await controller.inspectBag(expectedPartNumber: plan.variant.partNumber)
        result.bag = bag["state"] as? String ?? "unknown"
        result.bagDetails["bag"] = result.bag
        result.bagDetails["reason"] = bag["message"] as? String ?? ""
        return result
    }
    func observeProduct() async throws -> AutomationObservation {
        var (result, href, _) = try await accountFacts()
        guard sameProduct(href) else { return result }
        let facts = try await controller.inspectProductPreparation()
        result.configurationReady = facts["noTradeIn"] as? Bool == true && facts["noAppleCare"] as? Bool == true
        result.actionReady = facts["state"] as? String == "ready"
        return result
    }
    private func sameProduct(_ href: String) -> Bool {
        guard let current = URL(string: href), let expected = URL(string: plan.variant.url) else { return false }
        return current.scheme == expected.scheme && current.host == expected.host && current.path == expected.path
    }
    private func isAttachPage(_ href: String, ready: String) -> Bool {
        guard ready == "complete", managedStoreURL(href),
              let current = URLComponents(string: href),
              let source = URL(string: plan.source),
              current.path == source.path else { return false }
        let step = current.queryItems?.first(where: { $0.name == "step" })?.value?.lowercased()
        let product = current.queryItems?.first(where: { $0.name == "product" })?.value
        return step == "attach" && product?.caseInsensitiveCompare(plan.variant.partNumber) == .orderedSame
    }
    private func timedExpression(_ body: String) -> String {
        let start = plan.releaseAt.timeIntervalSince1970 * 1000
        let end = plan.releaseAt.addingTimeInterval(plan.executionSeconds).timeIntervalSince1970 * 1000
        return "(() => { if(Date.now() < \(start) || Date.now() >= \(end)) return {state:'disabled',kind:'none'}; return \(body); })()"
    }
    func clickProduct() async throws -> AutomationClick {
        actionID = UUID().uuidString
        let expression = try BrowserController.productActionExpression(expectedURL: plan.variant.url, actionID: actionID)
        let result = try await controller.evaluate(timedExpression(expression)) as? [String: Any] ?? [:]
        return AutomationClick(state: result["state"] as? String ?? "unknown", kind: result["kind"] as? String ?? "unknown")
    }
    func observeProgress() async throws -> AutomationObservation {
        var (result, href, ready) = try await accountFacts()
        guard managedStoreURL(href), let url = URL(string: href) else { return result }
        if result.requiresLogin && !result.challenge {
            if try await controller.attemptSavedAppleLogin() == "challenge" { result.challenge = true }
            return result
        }
        if BrowserController.checkoutTransitionState(href) == "handoff", ready != "loading", !result.requiresLogin, !result.challenge {
            let content = try await controller.evaluate("(() => { const text=document.body?.innerText || ''; return /送货地址|配送地址|订单摘要|付款方式|账单地址|Shipping Address|Payment Method|Order Summary/i.test(text) && !/Something went wrong|服务暂不可用|无法处理你的请求/i.test(text); })()") as? Bool ?? false
            if content { result.progress = "checkout" }
            return result
        }
        if url.host == bagURL.host && url.path == bagURL.path { result.progress = "bag"; return result }
        // Apple redirects a successful iPhone add into an accessory-attachment
        // page. Its SKU is carried in the query, not the product URL path.
        // Treat it only as a signal to inspect the official bag; never as proof
        // that the target item was added.
        if isAttachPage(href, ready: ready), !result.requiresLogin, !result.challenge {
            result.progress = "attach"
            return result
        }
        guard sameProduct(href) else { return result }
        let facts = try await controller.evaluate("""
        (() => {
          const visible = e => !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const add = document.querySelector('button[data-autom="add-to-cart"],button[name="add-to-cart"]');
          return {addReady:visible(add) && !add.disabled && add.getAttribute('aria-disabled') !== 'true',
            acknowledged:window.__asaPurchaseFeedback === true, issuedAction:window.__asaIssuedAction || null};
        })()
        """) as? [String: Any] ?? [:]
        if let action = facts["issuedAction"] as? [String: String], !actionID.isEmpty, action["id"] == actionID {
            result.issuedKind = action["kind"]
        }
        if facts["acknowledged"] as? Bool == true { result.progress = "acknowledged" }
        else if facts["addReady"] as? Bool == true { result.progress = "add_ready"; result.actionReady = true }
        return result
    }
    func clickCheckout() async throws -> AutomationClick {
        // Validate the bag and click in ONE renderer call. A user changing the
        // tab/bag between two roundtrips must not cause checkout of other goods.
        let bag = try BrowserController.bagInspectionExpression(expectedPartNumber: plan.variant.partNumber)
        let expression = """
        (() => {
          const bag = \(bag);
          if (bag.state !== 'confirmed') return {state:'disabled', message:bag.message || '购物袋中的商品或数量尚未核实'};
          const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const label = e => (e.innerText || e.getAttribute('aria-label') || '').replace(/\\s+/g,' ').trim();
          const matches = [...document.querySelectorAll('button,a,[role=button]')].filter(visible)
            .filter(e => /^(结账|结算|去结账|Check Out|Checkout)$/i.test(label(e)));
          if (!matches.length) return {state:'missing', message:'购物袋页暂未找到可见的结账按钮'};
          const enabled = matches.filter(e => !e.disabled && e.getAttribute('aria-disabled') !== 'true');
          if (!enabled.length) return {state:'disabled', message:'购物袋页的结账按钮暂不可用'};

          let button;
          let selectionMessage = '';
          if (enabled.length === 1) {
            button = enabled[0];
          } else {
            const labels = new Set(enabled.map(label));
            const areDuplicateButtons = enabled.length === 2 && labels.size === 1 && enabled.every(e => e.tagName === 'BUTTON');
            if (!areDuplicateButtons) return {state:'ambiguous', message:'检测到多个不同或无法区分的结账按钮，已停止自动点击'};

            // Apple's bag currently renders the same checkout action above and
            // below the item summary. After the bag is verified, choose the
            // upper visible button deterministically.
            button = enabled.slice().sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0];
            selectionMessage = '检测到两个同名结账按钮，已选择页面上方的结账按钮';
          }
          button.click();
          return {state:'clicked', message:selectionMessage || '已点击唯一可用的结账按钮'};
        })()
        """
        let result = try await controller.evaluate(timedExpression(expression)) as? [String: Any] ?? [:]
        return AutomationClick(state: result["state"] as? String ?? "unknown", kind: "checkout", message: result["message"] as? String)
    }
}
