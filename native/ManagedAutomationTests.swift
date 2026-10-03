import Foundation

@MainActor final class TestClock {
    var value: Double = 0
    func sleep(_ seconds: Double) async throws { try Task.checkCancellation(); value += seconds; await Task.yield() }
}

@MainActor final class ScriptedBrowser: AutomationBrowser {
    let clock: TestClock
    var connected = false
    var loginAt = 0.0
    var conflictUntil = 0.0
    var preexisting = false
    var needsRefresh = false
    var neverReady = false
    var useContinue = false
    var feedbackDelay = 0.0
    var checkoutDelay = 0.0
    var neverAcknowledges = false
    var throwAfterAdd = false
    var throwAfterContinue = false
    var throwAfterCheckout = false
    var addAt: Double?
    var checkoutAt: Double?
    var continued = false
    var refreshes = 0
    var reconnects = 0
    var productClicks = 0
    var addClicks = 0
    var checkoutClicks = 0
    var productTimes: [Double] = []
    init(_ clock: TestClock) { self.clock = clock }
    func connect() async throws { connected = true }
    func reconnect() async throws { reconnects += 1; connected = true }
    func openAccount() async throws {}
    func observeAccount() async throws -> AutomationObservation { AutomationObservation(loggedIn: clock.value >= loginAt, requiresLogin: clock.value < loginAt) }
    func openBag() async throws {}
    func observeBag() async throws -> AutomationObservation {
        AutomationObservation(bag: clock.value < conflictUntil ? "conflict" : (preexisting || addAt != nil ? "confirmed" : "empty"))
    }
    func openProduct(reload: Bool) async throws { if reload { refreshes += 1 } }
    func observeProduct() async throws -> AutomationObservation {
        AutomationObservation(configurationReady: true, actionReady: !neverReady && (!needsRefresh || refreshes > 0))
    }
    func clickProduct() async throws -> AutomationClick {
        productClicks += 1; productTimes.append(clock.value)
        if useContinue && !continued {
            continued = true
            if throwAfterContinue { connected = false; throw AppError("模拟继续响应断开") }
            return AutomationClick(state:"clicked",kind:"continue")
        }
        addClicks += 1; addAt = clock.value
        if throwAfterAdd { connected = false; throw AppError("模拟点击响应断开") }
        return AutomationClick(state:"clicked",kind:"add")
    }
    func observeProgress() async throws -> AutomationObservation {
        if let checkoutAt, clock.value >= checkoutAt + checkoutDelay { return AutomationObservation(progress:"checkout") }
        if let addAt, !neverAcknowledges, clock.value >= addAt + feedbackDelay { return AutomationObservation(progress:"acknowledged") }
        if continued && addAt == nil { return AutomationObservation(actionReady:true,progress:"add_ready",issuedKind:"continue") }
        return AutomationObservation()
    }
    func clickCheckout() async throws -> AutomationClick {
        checkoutClicks += 1; checkoutAt = clock.value
        if throwAfterCheckout { connected = false; throw AppError("模拟结账响应断开") }
        return AutomationClick(state:"clicked",kind:"checkout")
    }
}

@main struct ManagedAutomationTests {
    @MainActor static func main() async throws {
        let v = Variant(partNumber:"DEMO001/A",family:"demo",selections:[:],label:"demo",url:"https://www.apple.com.cn/shop/product/demo001/a",price:1,comingSoon:true)
        var passed = 0
        func test(_ name: String, recovery: Bool = true, persistFails: Bool = false,
                  configure: (ScriptedBrowser) -> Void = {_ in},
                  verify: (ScriptedBrowser, AutomationPhase, [AutomationCheckpoint], TestClock) -> Bool) async {
            let clock = TestClock(); let browser = ScriptedBrowser(clock)
            configure(browser)
            var plan = Plan(name:name,source:v.url,variant:v,catalogHash:"test",releaseAt:Date().addingTimeInterval(10))
            plan.prepareSeconds = 300; plan.quietSeconds = 60; plan.executionSeconds = 30; plan.recoverStalePage = recovery
            var checkpoints: [AutomationCheckpoint] = []
            let engine = ManagedAutomation(browser:browser,plan:plan,target:10,now:{clock.value},sleep:{try await clock.sleep($0)},persist:{ checkpoint in
                if persistFails { throw AppError("模拟磁盘写失败") }
                checkpoints.append(checkpoint)
            },event:{_,_,_ in})
            let result = await engine.run()
            precondition(verify(browser,result,checkpoints,clock), "FAIL: \(name), result=\(result), t=\(clock.value), add=\(browser.addClicks), checkout=\(browser.checkoutClicks)")
            precondition(browser.productTimes.allSatisfy {$0 >= 10 && $0 < 40}, "购买动作必须在原始执行窗口内")
            precondition(browser.addClicks <= 1 && browser.checkoutClicks <= 1, "未核验结果不得重复写入")
            print("PASS \(name)"); passed += 1
        }
        await test("登录完成后自动继续，无确认勾选",configure:{$0.loginAt=4}) {b,r,c,_ in r == .handoff && b.addClicks == 1 && c.first?.pending == "product"}
        await test("购物袋冲突人工清理后自动继续",configure:{$0.conflictUntil=6}) {b,r,_,_ in r == .handoff && b.addClicks == 1}
        await test("购物袋已有目标商品时不重复加购",configure:{$0.preexisting=true}) {b,r,_,_ in r == .handoff && b.addClicks == 0 && b.checkoutClicks == 1 && b.refreshes == 0}
        await test("继续与真正加购分别处理",configure:{$0.useContinue=true}) {b,r,_,_ in r == .handoff && b.productClicks == 2 && b.addClicks == 1}
        await test("继续响应丢失后凭本次动作标记恢复",configure:{$0.useContinue=true;$0.throwAfterContinue=true}) {b,r,_,_ in r == .handoff && b.productClicks == 2 && b.reconnects == 1}
        await test("官网十秒后反馈仍自动完成",configure:{$0.feedbackDelay=10}) {b,r,_,c in r == .handoff && b.addClicks == 1 && c.value >= 20}
        await test("结账十秒后跳转仍自动交接",configure:{$0.checkoutDelay=10}) {b,r,_,c in r == .handoff && b.checkoutClicks == 1 && c.value >= 20}
        await test("加购响应断开后重连并核验",configure:{$0.throwAfterAdd=true;$0.feedbackDelay=3}) {b,r,_,_ in r == .handoff && b.addClicks == 1 && b.reconnects == 1}
        await test("结账响应断开不重复结账",configure:{$0.throwAfterCheckout=true;$0.checkoutDelay=3}) {b,r,_,_ in r == .handoff && b.checkoutClicks == 1 && b.reconnects == 1}
        await test("未知加购结果保留原窗口截止",configure:{$0.neverAcknowledges=true}) {b,r,_,c in r == .attention && b.addClicks == 1 && b.checkoutClicks == 0 && c.value >= 40 && c.value < 40.01 && b.refreshes == 0}
        await test("可选页面恢复只更新一次",configure:{$0.needsRefresh=true}) {b,r,_,_ in r == .handoff && b.refreshes == 1 && b.productTimes.first! >= 15}
        await test("恢复开关关闭时不刷新",recovery:false,configure:{$0.needsRefresh=true}) {b,r,_,_ in r == .expired && b.refreshes == 0 && b.addClicks == 0}
        await test("始终不开售时更新次数有限",configure:{$0.neverReady=true}) {b,r,_,_ in r == .expired && b.refreshes == 1 && b.addClicks == 0}
        await test("持久化失败时绝不点击",persistFails:true) {b,r,_,_ in r == .attention && b.addClicks == 0 && b.checkoutClicks == 0}
        await test("迟到登录可在原窗口内继续",configure:{$0.loginAt=15}) {b,r,_,_ in r == .handoff && b.productTimes.first! >= 15}
        await test("登录未完成不会购买",configure:{$0.loginAt=100}) {b,r,_,_ in r == .expired && b.addClicks == 0}

        let clock = TestClock(); let browser = ScriptedBrowser(clock)
        let plan = Plan(name:"cancel",source:v.url,variant:v,catalogHash:"test",releaseAt:Date().addingTimeInterval(10))
        let engine = ManagedAutomation(browser:browser,plan:plan,target:10,now:{clock.value},sleep:{_ in throw CancellationError()},persist:{_ in},event:{_,_,_ in})
        let result = await engine.run()
        precondition(result == .cancelled && browser.addClicks == 0)
        passed += 1
        print("Managed automation: \(passed) scenarios passed; production coordinator, no Apple traffic")
    }
}
