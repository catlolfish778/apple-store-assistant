import Foundation

struct PendingAppleOrder {
    let orderNumber: String?
    let createdAt: Date
    let paymentDeadline: Date?
}

struct CheckoutOrderFlowOutcome {
    let message: String
    let order: PendingAppleOrder?
    let submissionMayHaveBeenIssued: Bool
    let preparedSubmission: Bool
}

/// Drives only Apple's visible checkout pages. It stops as soon as Apple
/// confirms an unpaid order and never activates the payment action.
@MainActor
final class CheckoutOrderFlow {
    private let browser: BrowserController
    private let paymentMethod: CheckoutPaymentMethod
    private let expectedPrice: Double
    private let priceLimit: Double
    private let prepareSubmission: () throws -> Void
    private let progress: (String) -> Void

    init(browser: BrowserController, paymentMethod: CheckoutPaymentMethod,
         expectedPrice: Double, priceLimit: Double,
         prepareSubmission: @escaping () throws -> Void,
         progress: @escaping (String) -> Void = { _ in }) {
        self.browser = browser
        self.paymentMethod = paymentMethod
        self.expectedPrice = expectedPrice
        self.priceLimit = priceLimit
        self.prepareSubmission = prepareSubmission
        self.progress = progress
    }

    func run() async -> CheckoutOrderFlowOutcome {
        guard expectedPrice > 0, expectedPrice.isFinite else {
            return stopped("购买计划没有可核对的商品价格；程序停在付款方式页。")
        }
        do {
            let firstPage = try await pageFacts()
            guard isBillingPage(firstPage) else {
                return stopped("结账页当前不是付款方式页面；程序没有选择付款方式或继续。")
            }

            let selection = try await waitForPaymentOption(timeout: 12)
            let selectionState = selection["state"] as? String ?? "unknown"
            guard ["selected", "selection_clicked", "selection_pending"].contains(selectionState) else {
                return stopped(selection["message"] as? String ?? "无法唯一识别" + paymentMethod.title + "选项；程序没有继续。")
            }
            if selectionState == "selection_clicked" || selectionState == "selection_pending" {
                if selectionState == "selection_clicked" {
                    progress("已点击" + paymentMethod.title + "选项，正在核验页面选中状态…")
                }
                let selected = await waitForPaymentSelection(timeout: 6)
                guard selected else {
                    return stopped("已尝试选择" + paymentMethod.title + "，但 Apple 页面没有确认单选框已选中；程序没有点击“检查订单”。")
                }
            }
            progress("已确认" + paymentMethod.title + "，正在检查订单…")

            var reviewReached = false
            do {
                let checkResult = try await browser.evaluate(checkOrderExpression()) as? [String: Any] ?? [:]
                let checkState = checkResult["state"] as? String ?? "unknown"
                if checkState == "clicked" || checkState == "pending" {
                    reviewReached = await waitForReview(timeout: 20)
                } else {
                    return stopped(checkResult["message"] as? String ?? "无法唯一确认“检查订单”按钮；程序没有继续。")
                }
            } catch {
                // The click may have completed before its protocol response was
                // lost. Observe the route without issuing another click.
                reviewReached = await waitForReview(timeout: 20)
            }
            guard reviewReached else {
                return stopped("“检查订单”已点击，但未能确认进入 Review；程序不会重复点击。请核对专用浏览器。")
            }
            progress("已进入 Review，正在核对付款方式和总金额…")
            let review = try await reviewFacts()
            guard review["state"] as? String == "review_ready" else {
                return stopped(review["message"] as? String ?? "Review 页面信息未能核实；程序没有提交订单。")
            }

            do { try prepareSubmission() }
            catch {
                return CheckoutOrderFlowOutcome(
                    message: "Review 核对通过，但本机未能保存提交前记录；程序没有点击“立即下单”。",
                    order: nil, submissionMayHaveBeenIssued: false, preparedSubmission: false
                )
            }
            let orderClick: [String: Any]
            do {
                orderClick = try await browser.evaluate(placeOrderExpression()) as? [String: Any] ?? [:]
            } catch {
                // The browser may have dispatched the click before the DevTools
                // response timed out. Keep the persisted pending marker and
                // only inspect the resulting page; never issue a second click.
                if let order = await waitForPendingOrder(timeout: 25) {
                    return created(order)
                }
                return CheckoutOrderFlowOutcome(
                    message: "“立即下单”的浏览器响应超时，结果仍未确认；程序不会重复点击。请检查 Apple 订单。",
                    order: nil, submissionMayHaveBeenIssued: true, preparedSubmission: true
                )
            }

            let orderClickState = orderClick["state"] as? String ?? "unknown"
            if orderClickState == "pending" {
                if let order = await waitForPendingOrder(timeout: 25) { return created(order) }
                return CheckoutOrderFlowOutcome(
                    message: "检测到下单动作可能已发出，但 Apple 尚未确认结果；程序不会重复点击，请检查订单。",
                    order: nil, submissionMayHaveBeenIssued: true, preparedSubmission: true
                )
            }
            guard orderClickState == "clicked" else {
                return CheckoutOrderFlowOutcome(
                    message: orderClick["message"] as? String ?? "Review 页面发生变化；程序没有确认“立即下单”已发出。",
                    order: nil,
                    submissionMayHaveBeenIssued: !["review_changed", "order_button_ambiguous", "order_button_disabled"].contains(orderClickState),
                    preparedSubmission: true
                )
            }

            progress("已发出一次“立即下单”，正在等待 Apple 确认待付款订单…")
            if let order = await waitForPendingOrder(timeout: 35) { return created(order) }
            return CheckoutOrderFlowOutcome(
                message: "已点击一次“立即下单”，但 Apple 尚未确认待付款订单；程序不会重复提交，请检查专用浏览器和订单。",
                order: nil, submissionMayHaveBeenIssued: true, preparedSubmission: true
            )
        } catch is CancellationError {
            return CheckoutOrderFlowOutcome(
                message: "结账自动化已停止；如已发出“立即下单”，请检查 Apple 订单，程序不会重试。",
                order: nil, submissionMayHaveBeenIssued: false, preparedSubmission: false
            )
        } catch {
            return stopped("读取 Apple 结账页面失败；程序没有重复提交。请检查专用浏览器：\(error.localizedDescription)")
        }
    }

    private func stopped(_ message: String) -> CheckoutOrderFlowOutcome {
        CheckoutOrderFlowOutcome(message: message, order: nil, submissionMayHaveBeenIssued: false, preparedSubmission: false)
    }

    private func created(_ order: PendingAppleOrder) -> CheckoutOrderFlowOutcome {
        let orderSuffix = order.orderNumber.map { "（订单号 \($0)）" } ?? ""
        let deadlineSuffix: String
        if let deadline = order.paymentDeadline {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            deadlineSuffix = "；请在 \(formatter.string(from: deadline)) 前手动付款"
        } else {
            deadlineSuffix = "；请尽快手动付款"
        }
        return CheckoutOrderFlowOutcome(
            message: "抢购成功：Apple 已生成待付款订单\(orderSuffix)\(deadlineSuffix)。程序已停止，未发起付款。",
            order: order, submissionMayHaveBeenIssued: true, preparedSubmission: true
        )
    }

    private func pageFacts() async throws -> [String: Any] {
        try await browser.evaluate(Self.pageFactsExpression) as? [String: Any] ?? [:]
    }

    private func isBillingPage(_ facts: [String: Any]) -> Bool {
        guard let href = facts["href"] as? String, managedStoreURL(href),
              let components = URLComponents(string: href) else { return false }
        let step = components.queryItems?.first(where: { $0.name == "_s" })?.value ?? ""
        return components.path.lowercased().hasPrefix("/shop/checkout") && step.caseInsensitiveCompare("Billing-init") == .orderedSame
    }

    private func waitForPaymentOption(timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var latest: [String: Any] = [:]
        var waitingWasLogged = false
        while true {
            try Task.checkCancellation()
            latest = try await browser.evaluate(paymentSelectionExpression()) as? [String: Any] ?? [:]
            let observed = latest["state"] as? String ?? "unknown"
            guard observed == "missing" || observed == "ambiguous" else { return latest }

            if !waitingWasLogged {
                progress("付款方式页已打开，正在等待\(paymentMethod.title)选项加载…")
                waitingWasLogged = true
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                let seconds = Int(timeout.rounded(.up))
                if observed == "missing" {
                    latest["message"] = "付款方式页已打开，但等待 \(seconds) 秒后仍未检测到设置的\(paymentMethod.title)卡片（候选数：0）；程序没有选择付款方式或继续。"
                } else if let message = latest["message"] as? String {
                    latest["message"] = "付款方式选项等待 \(seconds) 秒后仍无法唯一确认；\(message)"
                }
                return latest
            }
            try await Task.sleep(nanoseconds: UInt64(min(0.2, remaining) * 1_000_000_000))
        }
    }

    private func waitForPaymentSelection(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            do {
                let facts = try await browser.evaluate(paymentStateExpression()) as? [String: Any] ?? [:]
                if facts["selected"] as? Bool == true { return true }
                if facts["state"] as? String == "wrong_page" { return false }
            } catch { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func waitForReview(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            do {
                let facts = try await pageFacts()
                if isReviewPage(facts) { return true }
                if isOrderPendingPage(facts) { return false }
            } catch { /* continue read-only observation */ }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func waitForPendingOrder(timeout: TimeInterval) async -> PendingAppleOrder? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            do {
                let facts = try await pageFacts()
                if isOrderPendingPage(facts), facts["waitingPayment"] as? Bool == true {
                    let now = Date()
                    let minutes = facts["paymentMinutes"] as? Int
                    return PendingAppleOrder(
                        orderNumber: facts["orderNumber"] as? String,
                        createdAt: now,
                        paymentDeadline: minutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) }
                    )
                }
            } catch { /* never repeat the order submission; keep observing */ }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    private func isReviewPage(_ facts: [String: Any]) -> Bool {
        guard let href = facts["href"] as? String, managedStoreURL(href),
              let components = URLComponents(string: href) else { return false }
        let step = components.queryItems?.first(where: { $0.name == "_s" })?.value ?? ""
        return step.caseInsensitiveCompare("Review") == .orderedSame
    }

    private func isOrderPendingPage(_ facts: [String: Any]) -> Bool {
        guard let href = facts["href"] as? String, managedStoreURL(href),
              let url = URL(string: href) else { return false }
        // Treat the immediate checkout interstitial as confirmation for this
        // submission. The account order list may contain older unpaid orders.
        return url.path.lowercased() == "/shop/checkout/interstitial"
    }

    private func paymentSelectionExpression() -> String {
        let method = paymentMethod == .alipay ? "alipay" : "wechat"
        return Self.paymentSelectionScript(method: method)
    }

    private func paymentStateExpression() -> String {
        let method = paymentMethod == .alipay ? "alipay" : "wechat"
        return Self.paymentStateScript(method: method)
    }

    private func checkOrderExpression() -> String {
        """
        (() => {
          const facts = \(Self.pageFactsExpression);
          if (facts.stage !== 'billing') return {state:'wrong_page'};
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const norm = e => String(e?.innerText || e?.value || e?.getAttribute?.('aria-label') || '').replace(/\\s+/g,' ').trim();
          const buttons = [...document.querySelectorAll('button,[role="button"],input[type="submit"],a')].filter(visible)
            .filter(e => norm(e) === '检查订单');
          if (buttons.length !== 1) return {state:buttons.length ? 'ambiguous' : 'missing',message:'无法唯一确认“检查订单”按钮'};
          const button = buttons[0];
          if (button.disabled || button.getAttribute('aria-disabled') === 'true') return {state:'disabled',message:'“检查订单”按钮当前不可用'};
          if (window.__asaCheckOrderAttempted) return {state:'pending'};
          window.__asaCheckOrderAttempted = true;
          button.click();
          return {state:'clicked'};
        })()
        """
    }

    private func reviewFacts() async throws -> [String: Any] {
        let method = paymentMethod == .alipay ? "alipay" : "wechat"
        let expected = expectedPrice
        let limit = priceLimit
        return try await browser.evaluate(Self.reviewFactsScript(method: method, expectedPrice: expected, priceLimit: limit)) as? [String: Any] ?? [:]
    }

    private func placeOrderExpression() -> String {
        let method = paymentMethod == .alipay ? "alipay" : "wechat"
        return Self.placeOrderScript(method: method, expectedPrice: expectedPrice, priceLimit: priceLimit)
    }

    private static let pageFactsExpression = """
    (() => {
      const href = location.href;
      const step = new URL(href).searchParams.get('_s') || '';
      const path = location.pathname.toLowerCase();
      const text = (document.body?.innerText || '').replace(/\\s+/g,' ').trim();
      const waitingPayment = /你的订单正在等待付款|订单正在等待付款|我们正在等待你的付款/.test(text);
      const orderLink = [...document.querySelectorAll('a')].map(a => (a.innerText || '').trim())
        .find(value => /订单\\s*#\\s*[A-Z0-9]{6,}/i.test(value)) || '';
      const orderMatch = orderLink.match(/订单\\s*#\\s*([A-Z0-9]{6,})/i);
      const minutesMatch = text.match(/(\\d{1,3})\\s*分钟内/);
      let stage = 'other';
      if (path.startsWith('/shop/checkout') && /^Billing-init$/i.test(step)) stage = 'billing';
      else if (path.startsWith('/shop/checkout') && /^Review$/i.test(step)) stage = 'review';
      else if (path === '/shop/checkout/interstitial') stage = 'interstitial';
      else if (path === '/shop/order/list') stage = 'order_list';
      return {href,stage,waitingPayment,orderNumber:orderMatch?.[1] || '',paymentMinutes:minutesMatch ? Number(minutesMatch[1]) : 0};
    })()
    """

    private static func paymentSelectionScript(method: String) -> String {
        """
        (() => {
          const step = new URL(location.href).searchParams.get('_s') || '';
          if (!location.pathname.toLowerCase().startsWith('/shop/checkout') || step.toLowerCase() !== 'billing-init')
            return {state:'wrong_page',message:'当前页面不是付款方式页'};
          const token = '\(method)';
          const root = document.querySelector('#checkout-container') || document;
          const radios = [...root.querySelectorAll('input[type="radio"]')]
            .filter(e => e.id.toLowerCase().endsWith('.' + token) && /selectbillingoption/i.test(e.name || ''));
          if (radios.length !== 1) return {state:radios.length ? 'ambiguous' : 'missing',message:'无法唯一确认 Apple 的' + (token === 'alipay' ? '支付宝' : '微信支付') + '单选框（候选数：' + radios.length + '）；程序没有继续。'};
          const radio = radios[0];
          const labels = [...document.querySelectorAll('label')].filter(label => label.htmlFor === radio.id);
          const expectedClass = 'rf-paymentoptions-item-' + token;
          const item = radio.closest('.rf-paymentoptions-item');
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          if (labels.length !== 1 || !visible(labels[0]) || !item || !item.classList.contains(expectedClass))
            return {state:'ambiguous',message:'已找到' + (token === 'alipay' ? '支付宝' : '微信支付') + '单选框，但未能唯一确认对应的可见选项标签；程序没有继续。'};
          if (radio.checked) return {state:'selected'};
          if (window.__asaPaymentRadioSelectionAttempted === radio.id) return {state:'selection_pending'};
          // Mark before dispatch: if the DevTools response is lost after the
          // event reaches Apple's page, a retry must not click a second time.
          window.__asaPaymentRadioSelectionAttempted = radio.id;
          labels[0].click();
          return {state:'selection_clicked'};
        })()
        """
    }

    private static func paymentStateScript(method: String) -> String {
        """
        (() => {
          const step = new URL(location.href).searchParams.get('_s') || '';
          if (!location.pathname.toLowerCase().startsWith('/shop/checkout') || step.toLowerCase() !== 'billing-init')
            return {state:'wrong_page',selected:false};
          const token = '\(method)';
          const root = document.querySelector('#checkout-container') || document;
          const radios = [...root.querySelectorAll('input[type="radio"]')]
            .filter(e => e.id.toLowerCase().endsWith('.' + token) && /selectbillingoption/i.test(e.name || ''));
          if (radios.length !== 1) return {state:radios.length ? 'ambiguous' : 'missing',selected:false};
          const radio = radios[0];
          const labels = [...document.querySelectorAll('label')].filter(label => label.htmlFor === radio.id);
          const item = radio.closest('.rf-paymentoptions-item');
          if (labels.length !== 1 || !item || !item.classList.contains('rf-paymentoptions-item-' + token))
            return {state:'ambiguous',selected:false};
          return {state:'observed',selected:radio.checked};
        })()
        """
    }

    private static func reviewFactsScript(method: String, expectedPrice: Double, priceLimit: Double) -> String {
        let expected = String(format: "%.2f", expectedPrice)
        let limit = String(format: "%.2f", priceLimit)
        let methodPattern = method == "alipay" ? "/支付宝|alipay/i" : "/微信支付|微信|wechat\\s*pay/i"
        return """
        (() => {
          const facts = \(pageFactsExpression);
          if (facts.stage !== 'review') return {state:'wrong_page',message:'未处于 Apple Review 页面'};
          const text = (document.body?.innerText || '').replace(/\\s+/g,' ').trim();
          // Review pages may list several supported payment methods at once.
          // Only require the configured method to be present; unrelated options
          // elsewhere in the page must not be treated as a selection conflict.
          const methodMatches = \(methodPattern).test(text);
          const totalLine = text.match(/总计.{0,100}?(?:RMB|¥|￥)\\s*([0-9][0-9,]*(?:\\.\\d{1,2})?)/i);
          const total = totalLine ? Number(totalLine[1].replace(/,/g,'')) : NaN;
          const expected = Number('\(expected)');
          const limit = Number('\(limit)');
          const amountMatches = Number.isFinite(total) && Math.abs(total-expected) < 0.01 && (!(limit > 0) || total <= limit + 0.01);
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const buttons = [...document.querySelectorAll('button,[role="button"],input[type="submit"],a')].filter(visible)
            .filter(e => String(e.innerText || e.value || e.getAttribute('aria-label') || '').replace(/\\s+/g,' ').trim() === '立即下单');
          if (!methodMatches) return {state:'payment_mismatch',message:'Review 页面未能确认设置的付款方式'};
          if (!amountMatches) return {state:'amount_mismatch',message:'Review 页面总金额与购买计划价格不一致或无法读取'};
          if (buttons.length !== 1) return {state:'order_button_ambiguous',message:'无法唯一确认 Review 页的“立即下单”按钮'};
          if (buttons[0].disabled || buttons[0].getAttribute('aria-disabled') === 'true') return {state:'order_button_disabled',message:'Review 页的“立即下单”按钮当前不可用'};
          return {state:'review_ready'};
        })()
        """
    }

    private static func placeOrderScript(method: String, expectedPrice: Double, priceLimit: Double) -> String {
        let expected = String(format: "%.2f", expectedPrice)
        let limit = String(format: "%.2f", priceLimit)
        let methodPattern = method == "alipay" ? "/支付宝|alipay/i" : "/微信支付|微信|wechat/i"
        return """
        (() => {
          const facts = \(pageFactsExpression);
          if (facts.stage !== 'review') return {state:'review_changed',message:'Review 页面已变化，没有发出下单操作'};
          if (window.__asaPlaceOrderAttempted) return {state:'pending'};
          const text = (document.body?.innerText || '').replace(/\\s+/g,' ').trim();
          // The Review page can contain labels for multiple payment options.
          // Do not reject the configured option just because other labels exist.
          const methodMatches = \(methodPattern).test(text);
          const totalLine = text.match(/总计.{0,100}?(?:RMB|¥|￥)\\s*([0-9][0-9,]*(?:\\.\\d{1,2})?)/i);
          const total = totalLine ? Number(totalLine[1].replace(/,/g,'')) : NaN;
          const expected = Number('\(expected)');
          const limit = Number('\(limit)');
          if (!methodMatches || !Number.isFinite(total) || Math.abs(total-expected) >= 0.01 || (limit > 0 && total > limit + 0.01))
            return {state:'review_changed',message:'Review 页面未能确认设置的付款方式或总金额不符，没有发出下单操作'};
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const buttons = [...document.querySelectorAll('button,[role="button"],input[type="submit"],a')].filter(visible)
            .filter(e => String(e.innerText || e.value || e.getAttribute('aria-label') || '').replace(/\\s+/g,' ').trim() === '立即下单');
          if (buttons.length !== 1) return {state:'order_button_ambiguous',message:'无法唯一确认“立即下单”按钮，没有发出操作'};
          const button = buttons[0];
          if (button.disabled || button.getAttribute('aria-disabled') === 'true') return {state:'order_button_disabled',message:'“立即下单”按钮不可用，没有发出操作'};
          window.__asaPlaceOrderAttempted = true;
          button.click();
          return {state:'clicked'};
        })()
        """
    }
}
