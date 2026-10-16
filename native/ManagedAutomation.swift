import Foundation

enum AutomationPhase: String, Codable {
    case connecting, login, checkingBag, preparing, waiting, purchasing, verifyingBag, checkingOut, awaitingCheckout
    case handoff, attention, expired, cancelled
    var title: String {
        switch self {
        case .connecting: return "正在连接专用浏览器"
        case .login: return "正在处理 Apple 登录"
        case .checkingBag: return "正在检查购物袋"
        case .preparing: return "正在锁定商品和配置"
        case .waiting: return "准备完成，等待抢购时间"
        case .purchasing: return "正在执行商品步骤并核验官网结果"
        case .verifyingBag: return "正在核验购物袋商品和数量"
        case .checkingOut: return "正在进入结账"
        case .awaitingCheckout: return "正在等待结账结果"
        case .handoff: return "已到结账页，请核对配送信息并决定付款"
        case .attention: return "需要你检查官网页面"
        case .expired: return "执行窗口已结束"
        case .cancelled: return "托管已停止"
        }
    }
}

struct AutomationObservation {
    var loggedIn = false
    var requiresLogin = false
    var challenge = false
    var configurationReady = false
    var actionReady = false
    var progress = "waiting" // waiting / add_ready / acknowledged / attach / bag / checkout
    var bag = "unknown" // empty / confirmed / conflict / unknown
    var bagDetails: [String: String] = [:]
    var checkoutDetails: [String: String] = [:]
    var issuedKind: String?
}

struct AutomationClick { var state: String; var kind: String; var message: String? = nil }

@MainActor
protocol AutomationBrowser: AnyObject {
    var connected: Bool { get }
    func connect() async throws
    func reconnect() async throws
    func openAccount() async throws
    func observeAccount() async throws -> AutomationObservation
    func openBag() async throws
    func observeBag() async throws -> AutomationObservation
    func openProduct(reload: Bool) async throws
    func observeProduct() async throws -> AutomationObservation
    func clickProduct() async throws -> AutomationClick
    func observeProgress() async throws -> AutomationObservation
    func clickCheckout() async throws -> AutomationClick
}

struct AutomationCheckpoint {
    var phase: AutomationPhase
    var pending: String? // Persisted BEFORE any purchase click.
    var purchaseIssued: Bool
}

/// The production coordinator is also driven by deterministic test browsers.
/// It never retries an issued purchase merely because a response is late.
@MainActor
final class ManagedAutomation {
    let browser: any AutomationBrowser
    let plan: Plan
    let target: TimeInterval
    let deadline: TimeInterval
    var phase: AutomationPhase = .connecting
    private(set) var pending: String?
    private(set) var purchaseIssued = false
    private var accountOpened = false
    private var bagOpened = false
    private var productOpened = false
    private var bagAlreadyContainsTarget = false
    private var preReleaseRefreshDone = false
    private var postReleaseRefreshDone = false
    private var lastProductLoad: TimeInterval = 0
    private var preparationRechecked = false
    private var lastNotice = ""
    private var failures = 0
    private var lastProgress: String = ""
    private var continueCompleted = false
    private var triggerObserved = false
    private var observedChecks = 0
    private var lastFacts = ""
    private var lastBagDetails: [String: String]?
    private var lastCheckoutClickReport = ""
    private var lastCheckoutDetails = ""
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let persist: (AutomationCheckpoint) throws -> Void
    private let event: (AutomationPhase, String, [String: String]) -> Void

    init(browser: any AutomationBrowser, plan: Plan, target: TimeInterval,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
         persist: @escaping (AutomationCheckpoint) throws -> Void,
         event: @escaping (AutomationPhase, String, [String: String]) -> Void) {
        self.browser = browser; self.plan = plan; self.target = target
        self.deadline = target + plan.executionSeconds
        self.now = now; self.sleep = sleep; self.persist = persist; self.event = event
    }

    private func notify(_ message: String, _ details: [String: String] = [:]) {
        let key = phase.rawValue + message
        guard key != lastNotice || !details.isEmpty else { return }
        lastNotice = key
        event(phase, message, details)
    }
    private func transition(_ next: AutomationPhase) {
        phase = next
        notify(next == .waiting && now() >= target ? "正在等待购买按钮开放" : next.title)
    }
    private func save() throws {
        try persist(AutomationCheckpoint(phase: phase, pending: pending, purchaseIssued: purchaseIssued))
    }
    private func checkActive() throws {
        try Task.checkCancellation()
        if now() >= deadline { throw AutomationEnd.expired }
    }
    private func checkClickTime() throws {
        try checkActive()
        if now() < target { throw AppError("尚未到购买时间") }
    }
    private func wait(_ seconds: TimeInterval) async throws {
        try checkActive()
        try await sleep(min(seconds, max(0, deadline - now())))
    }

    private func unresolvedActionMessage() -> String {
        switch pending {
        case "add": return "加购结果仍未确认；请检查官网购物袋，程序不会重复加购"
        case "checkout": return "结账结果仍未确认；请检查官网页面，程序不会重复点击"
        case "continue": return "继续购买步骤结果仍未确认；请检查官网页面，程序不会重复点击"
        default: return "购买动作结果仍未确认；请检查官网页面，程序不会重复执行该动作"
        }
    }

    func run() async -> AutomationPhase {
        notify(phase.title)
        do {
            while true {
                try checkActive()
                if !triggerObserved && now() >= target {
                    triggerObserved = true
                    notify("已到设定抢购时间", ["event":"release_triggered", "schedulerDelayMS":String((now()-target)*1000)])
                }
                do {
                    if phase != .connecting && !browser.connected {
                        notify("控制连接中断，正在重新连接原页面；购买结果会继续核验")
                        try await browser.reconnect()
                        try checkActive()
                    }
                    try await step()
                    failures = 0
                    if phase == .handoff || phase == .attention { return phase }
                } catch is CancellationError { throw CancellationError() }
                catch let end as AutomationEnd { throw end }
                catch let storage as AutomationPersistenceError {
                    transition(.attention); notify("执行记录保存失败，已停止发出购买动作：\(storage.message)"); return phase
                } catch {
                    // Reads, navigation and reconnects are recoverable. An issued
                    // write already moved to a pending phase before awaiting it.
                    failures += 1
                    notify("正在自动恢复：\(error.localizedDescription)", ["recoveryAttempt": String(failures)])
                    try await wait(min(5, Double(failures)))
                }
            }
        } catch is CancellationError {
            transition(.cancelled)
        } catch {
            transition(pending == nil ? .expired : .attention)
            notify(pending == nil ? "执行窗口已结束；请检查官网当前状态" : unresolvedActionMessage())
        }
        return phase
    }

    private func checkpoint() throws {
        do { try save() }
        catch { throw AutomationPersistenceError(message: error.localizedDescription) }
    }

    private func attemptCheckout() async throws {
        try checkClickTime()
        pending = "checkout"
        if phase == .checkingOut { transition(.awaitingCheckout) }
        try checkpoint()
        try checkClickTime()

        let click = try await browser.clickCheckout()
        try checkActive()
        let message = click.message ?? ""
        if click.state == "manual" || click.state == "ambiguous" {
            pending = nil
            try checkpoint()
            transition(.attention)
            var details = ["clickState": click.state]
            if !message.isEmpty { details["detail"] = message }
            notify(message.isEmpty ? "结账按钮无法安全区分，请检查官网页面" : message, details)
            return
        }
        let report = "\(click.state)|\(message)"
        if report != lastCheckoutClickReport {
            lastCheckoutClickReport = report
            var details = ["clickState": click.state]
            if !message.isEmpty { details["detail"] = message }
            notify(message.isEmpty ? "结账按钮调用返回" : message, details)
        }
        if click.state != "clicked" && click.state != "unknown" {
            pending = nil
            try checkpoint()
            try await wait(0.5)
        }
    }

    private func step() async throws {
        switch phase {
        case .connecting:
            try await browser.connect()
            try checkActive()
            transition(.login)
        case .login:
            // Inspect the current Apple page before navigating. Checkout can
            // present a server-side sign-in/identity challenge; navigating to
            // account home would discard that in-progress page. Mark the one
            // permitted account navigation before awaiting it so a CDP timeout
            // cannot cause the next recovery pass to navigate again.
            var facts = try await browser.observeAccount()
            try checkActive()
            if !facts.loggedIn && !facts.challenge && !facts.requiresLogin && !accountOpened {
                accountOpened = true
                try await browser.openAccount()
                facts = try await browser.observeAccount()
                try checkActive()
            }
            if facts.loggedIn && !facts.challenge && !facts.requiresLogin {
                notify("登录已确认，自动继续检查购物袋", ["account": "ready"])
                bagOpened = false; transition(.checkingBag)
            } else {
                if facts.challenge {
                    notify("Apple 要求完成身份验证；程序已停止自动登录并等待验证码或验证结果")
                } else if facts.requiresLogin {
                    notify("Apple 要求重新登录；程序正在尝试专用浏览器已保存的账号凭据")
                } else {
                    notify("请在专用浏览器完成登录，完成后会自动继续")
                }
                try await wait(1)
            }
        case .checkingBag:
            if !bagOpened { try await browser.openBag(); bagOpened = true }
            let facts = try await browser.observeBag()
            try checkActive()
            if facts.requiresLogin || facts.challenge {
                accountOpened = false; transition(.login); return
            }
            if !facts.bagDetails.isEmpty && facts.bagDetails != lastBagDetails {
                lastBagDetails = facts.bagDetails
                var details = facts.bagDetails
                details["event"] = "bag_observed"
                let reason = details["reason"] ?? ""
                notify(reason.isEmpty ? "购物袋核验：\(facts.bag)" : "购物袋核验：\(reason)", details)
            }
            switch facts.bag {
            case "empty", "confirmed":
                bagAlreadyContainsTarget = facts.bag == "confirmed"
                notify(bagAlreadyContainsTarget ? "购物袋已有目标商品 × 1，到点复核后直接结账" : "购物袋已确认为空", ["bag": facts.bag])
                if bagAlreadyContainsTarget {
                    lastProductLoad = now()
                    notify("已锁定购物袋中的目标商品 × 1", ["product": "locked"])
                    transition(.waiting)
                } else { productOpened = false; transition(.preparing) }
            case "conflict":
                notify("购物袋有其他商品或数量不符，请在官网调整；调整后自动继续")
                try await wait(1)
            default:
                notify("正在等待购物袋加载并确认内容")
                try await wait(1)
            }
        case .preparing:
            if !productOpened {
                try await browser.openProduct(reload: false)
                productOpened = true; lastProductLoad = now()
            }
            let facts = try await browser.observeProduct()
            try checkActive()
            if facts.requiresLogin || facts.challenge { accountOpened = false; transition(.login); return }
            if facts.configurationReady {
                notify("已锁定计划商品；不折抵换购、不加 AppleCare+、数量 1", ["product": "locked"])
                transition(.waiting)
            } else { try await wait(0.5) }
        case .waiting:
            let remaining = target - now()
            // Recheck session and bag once at the preparation boundary when
            // the task was armed much earlier, before entering quiet time.
            if !preparationRechecked && remaining <= plan.prepareSeconds {
                preparationRechecked = true
                if remaining > plan.quietSeconds + 30 && now() - lastProductLoad > 60 {
                    accountOpened = false; transition(.login); return
                }
            }
            if !bagAlreadyContainsTarget && !preReleaseRefreshDone && remaining <= plan.quietSeconds + 30 && remaining > plan.quietSeconds + 5 {
                preReleaseRefreshDone = true
                if now() - lastProductLoad > 15 && !purchaseIssued {
                    notify("静默前复核商品页数据", ["refresh": "pre_release"])
                    try await browser.openProduct(reload: true)
                    productOpened = true; lastProductLoad = now(); transition(.preparing); return
                }
            }
            if remaining > 5 && remaining <= plan.quietSeconds {
                notify("静默等待，开售前 5 秒开始观察按钮")
                try await wait(min(0.5, remaining - 5)); return
            }
            if remaining > 5 {
                try await wait(1); return
            }
            if remaining <= 0 && bagAlreadyContainsTarget {
                bagOpened = false; transition(.verifyingBag); return
            }
            if remaining > 0 && bagAlreadyContainsTarget { try await wait(min(0.1, remaining)); return }
            let facts = try await (continueCompleted ? browser.observeProgress() : browser.observeProduct())
            try checkActive()
            observedChecks += 1
            let signature = "\(facts.configurationReady):\(facts.actionReady):\(facts.requiresLogin):\(facts.progress)"
            if signature != lastFacts {
                lastFacts = signature
                notify(facts.actionReady ? "购买按钮已就绪" : "正在等待购买按钮开放", ["event":"product_observed", "configurationReady":String(facts.configurationReady), "actionReady":String(facts.actionReady), "purchaseIssued":String(purchaseIssued), "checks":String(observedChecks), "releaseDeltaMS":String((now()-target)*1000)])
            }
            if facts.requiresLogin || facts.challenge { accountOpened = false; transition(.login); return }
            if now() >= target && (facts.configurationReady || (continueCompleted && facts.progress == "add_ready")) && facts.actionReady {
                try checkClickTime()
                pending = "product"; purchaseIssued = true
                transition(.purchasing); try checkpoint(); try checkClickTime()
                let click = try await browser.clickProduct()
                try checkActive()
                let actionLabel = click.kind == "add" ? "加购" : (click.kind == "continue" ? "继续" : "购买步骤")
                notify("\(actionLabel)按钮调用返回", ["clickState": click.state, "kind": click.kind, "releaseDeltaMS": String((now() - target) * 1000)])
                if addAttemptWasNotIssued(click.state) {
                    pending = nil; purchaseIssued = continueCompleted; transition(.waiting); try checkpoint()
                } else if click.state == "clicked" {
                    pending = click.kind; try checkpoint()
                }
                return
            }
            // Optional bounded recovery only BEFORE any purchase was issued.
            // Never reload while a Continue/Add request could be in flight.
            if plan.recoverStalePage != false && now() - target >= 5 && !postReleaseRefreshDone && !purchaseIssued && !facts.actionReady {
                postReleaseRefreshDone = true
                notify("开售后按钮仍未开放，尝试一次页面更新", ["refresh": "post_release"])
                try await browser.openProduct(reload: true)
                productOpened = true; lastProductLoad = now(); transition(.preparing); return
            }
            try await wait(remaining > 0 ? 0.1 : 0.15)
        case .purchasing:
            let facts = try await browser.observeProgress()
            try checkActive()
            if pending == "product", facts.issuedKind == "continue" {
                pending = "continue"; try checkpoint()
            }
            if facts.progress != lastProgress {
                lastProgress = facts.progress
                let message: String
                switch facts.progress {
                case "attach": message = "已进入配件选择页，正在核验购物袋"
                case "bag": message = "已到购物袋，正在核验商品"
                case "acknowledged": message = "官网已反馈加购，正在核验购物袋"
                default: message = pending == "continue" ? "正在确认继续步骤结果" : "正在确认加购结果"
                }
                notify(message, ["progress": facts.progress])
            }
            if facts.progress == "bag" || facts.progress == "acknowledged" || facts.progress == "attach" {
                bagOpened = facts.progress == "bag"; transition(.verifyingBag)
            } else if pending == "continue" && facts.progress == "add_ready" {
                // A known Continue completed. The next Add is a separate action.
                continueCompleted = true; pending = nil; transition(.waiting); try checkpoint()
            } else {
                if facts.requiresLogin || facts.challenge { notify("官网需要登录或验证，请在当前页面完成；程序会继续核验已发出的动作") }
                try await wait(0.2)
            }
        case .verifyingBag:
            if !bagOpened { try await browser.openBag(); bagOpened = true }
            let facts = try await browser.observeBag()
            try checkActive()
            if facts.bag == "confirmed" {
                pending = nil; transition(.checkingOut); try checkpoint()
            } else {
                notify(facts.bag == "conflict" ? "购物袋内容与计划不符，请核对；程序会继续检查" : "等待购物袋确认目标型号与数量 1")
                try await wait(0.3)
            }
        case .checkingOut:
            try await attemptCheckout()
        case .awaitingCheckout:
            let facts = try await browser.observeProgress()
            try checkActive()
            if !facts.checkoutDetails.isEmpty {
                let signature = facts.checkoutDetails.keys.sorted().map { "\($0)=\(facts.checkoutDetails[$0] ?? "")" }.joined(separator: "|")
                if signature != lastCheckoutDetails {
                    lastCheckoutDetails = signature
                    notify("结账按钮监控状态", facts.checkoutDetails)
                }
            }
            if facts.progress == "checkout" {
                pending = nil; transition(.handoff); try checkpoint()
            } else {
                if facts.challenge {
                    notify("Apple 在结账时要求身份验证；程序等待验证结果，不会重复点击结账")
                } else if facts.requiresLogin {
                    notify("Apple 在结账时要求重新登录；程序正在尝试专用 Edge 已保存的凭据，不会重复点击结账")
                }
                if pending == nil && !facts.requiresLogin && !facts.challenge {
                    try await attemptCheckout()
                } else {
                    try await wait(0.1)
                }
            }
        default: throw CancellationError()
        }
    }
}

private enum AutomationEnd: Error { case expired }
private struct AutomationPersistenceError: Error { var message: String }
