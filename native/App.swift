import AppKit
import WebKit
import Darwin

final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

@MainActor
final class StoreApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, WKScriptMessageHandler, NSTextFieldDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var accountWeb: WKWebView!
    var browser: BrowserController?
    var accountWindow: NSWindow?
    var rightStack: NSStackView!
    var accountMode = false
    var accountWebConstraints: [NSLayoutConstraint] = []
    let processPool = WKProcessPool()
    var popupWindows: [ObjectIdentifier: NSWindow] = [:]
    var accountHost: NSView?
    var accountOverlay: NSStackView?
    var accountSpinner: NSProgressIndicator?
    var accountStatus: NSTextField?
    var accountRetry: NSButton?
    var accountLoadTimer: Timer?
    var accountHealthTimer: Timer?
    var accountHealthStarted = Date.distantPast
    var managedAccountMonitor: Task<Void, Never>?
    var managedBrowserStartTask: Task<Void, Never>?
    // One coordinator drives production and the isolated rehearsal.
    var automation: ManagedAutomation?
    var automationTask: Task<Void, Never>?
    var automationPhase: AutomationPhase?
    var checkoutHandoffRunState = "manual"
    var manualBrowserOperations = 0
    var managedBrowserButton: NSButton!
    var accountCheckButton: NSButton!
    var store: Storage!
    var saved = Saved()
    var pickupDirectory: AppleStoreDirectory?
    var pickupSettings = PickupSettings()
    let checkoutProfileKeychain = CheckoutProfileKeychain()
    var checkoutProfile = SecureCheckoutProfile()
    var checkoutProfileLoadError: String?
    var editingInvoiceType: AppleInvoiceType = .personal
    var suppressPickupActions = false
    var catalog: Catalog?
    var variant: Variant?
    var plan: ProductPlan?
    var run: RunRecord?
    var taskRecording: TaskRecording?
    var timer: Timer?
    var activity: NSObjectProtocol?
    var bridge = ""
    var busy = false
    var generation = UUID()
    var monotonicTarget: TimeInterval = 0
    var isDemo = false
    var completedDemo = false
    var readyConfirmed = false
    var lockFD: Int32 = -1
    var logLines: [String] = []
    var options: [(Group, NSPopUpButton)] = []
    var editControls: [NSControl] = []
    var latestActions: [Action] = []
    var productDetails = FlippedStack()
    var productSectionCollapsed = true
    var collapseProductButton: NSButton!
    var pickupDetails = FlippedStack()
    var pickupSectionCollapsed = false
    var collapsePickupButton: NSButton!
    var accountExtrasButton: NSButton!
    let accountExtras = FlippedStack()
    var rightBrowserStack: NSStackView!
    var logScroll: NSScrollView!
    var logHeightConstraint: NSLayoutConstraint!
    var workflowStatusStack: NSStackView!
    var workflowIcons: [NSImageView] = []
    var workflowConnectors: [NSBox] = []
    var workflowPlanSelected = false
    var workflowAccountReady = false
    var workflowProductLocked = false
    var workflowCompleted = false
    // The popup is rebuilt after every save/rename. Never let a programmatic
    // selection fire selectPreset while its menu is being rebuilt; doing so
    // can apply an item using a stale visual index.
    var suppressPresetAction = false
    let source = NSTextField(string: "https://www.apple.com.cn/shop/buy-iphone/iphone-duo")
    let name = NSTextField(string: "我的购买计划")
    let presets = NSPopUpButton()
    let pickupCountry = NSPopUpButton()
    let pickupCity = NSPopUpButton()
    let pickupStore = NSPopUpButton()
    let pickupAutoSelect = NSButton(checkboxWithTitle: "允许结账时自动选用首选门店", target: nil, action: nil)
    let autoCompleteCheckout = NSButton(checkboxWithTitle: "自动完成下单并停在待付款（不会付款）", target: nil, action: nil)
    let paymentMethod = NSPopUpButton()
    let pickupAddress = NSTextField(wrappingLabelWithString: "请选择取货城市和门店。")
    let pickupSummary = NSTextField(wrappingLabelWithString: "尚未确认取货门店")
    let contactSurname = NSTextField()
    let contactGivenName = NSTextField()
    let contactEmail = NSTextField()
    let contactPhone = NSTextField()
    let contactIDLastFour = NSSecureTextField()
    let rememberContactIDLastFour = NSButton(checkboxWithTitle: "在钥匙串保存后四位，供下次自动填写", target: nil, action: nil)
    let confirmPickupName = NSButton(checkboxWithTitle: "我确认取货姓名与购买人及证件一致", target: nil, action: nil)
    let defaultInvoiceType = NSPopUpButton()
    let invoiceProfileEditor = NSSegmentedControl(labels: ["个人", "公司/其他", "增值税专票"], trackingMode: .selectOne, target: nil, action: nil)
    let personalInvoiceFields = FlippedStack()
    let companyInvoiceFields = FlippedStack()
    let vatInvoiceFields = FlippedStack()
    let personalInvoiceHeader = NSTextField()
    let companyInvoiceName = NSTextField()
    let companyInvoiceTaxID = NSSecureTextField()
    let companyHasNoTaxID = NSButton(checkboxWithTitle: "我司无纳税人识别号", target: nil, action: nil)
    let vatInvoiceCompanyName = NSTextField()
    let vatInvoiceTaxID = NSSecureTextField()
    let vatInvoiceBankName = NSTextField()
    let vatInvoiceBankAccount = NSSecureTextField()
    let vatTermsAuthorization = NSButton(checkboxWithTitle: "我已阅读专票条款，确认代表该公司采购且资料属实，并授权程序自动勾选", target: nil, action: nil)
    let checkoutProfileStatus = NSTextField(wrappingLabelWithString: "个人资料尚未保存到本机钥匙串")
    var locatePickupButton: NSButton!
    var saveCheckoutProfileButton: NSButton!
    var clearCheckoutProfileButton: NSButton!
    let specs = NSStackView()
    let advanced = NSStackView()
    let preview = NSTextField(wrappingLabelWithString: "打开官方购买页，然后读取规格。")
    let state = NSTextField(wrappingLabelWithString: "尚未托管")
    let countdown = NSTextField(labelWithString: "准备你的下一件 Apple 产品")
    let session = NSTextField(wrappingLabelWithString: "账号：启动专用浏览器后自动检查")
    let browserWindowStatus = NSTextField(wrappingLabelWithString: "浏览器窗口：尚未启动")
    let browserControlStatus = NSTextField(wrappingLabelWithString: "控制连接：未连接")
    let browserSession = NSTextField(wrappingLabelWithString: "浏览器：未连接")
    let pageURL = NSTextField(labelWithString: "Apple 官方网页 · 规格读取/诊断页面")
    let logView = NSTextView()
    let release = NSDatePicker()
    let prepare = NSTextField(string: "300")
    let quiet = NSTextField(string: "60")
    let duration = NSTextField(string: "60")
    let staleRecovery = NSButton(checkboxWithTitle: "开售 5 秒后仍未开放：最多更新一次页面", target: nil, action: nil)
    let schedulePreview = NSTextField(wrappingLabelWithString: "")
    let maxTotal = NSTextField(string: "0")
    let accountConfirmed = NSButton(checkboxWithTitle: "已在专用浏览器确认登录、配送地址及支付方式", target: nil, action: nil)
    let autoSubmit = NSButton(checkboxWithTitle: "自动提交订单（需采集最终按钮及设置金额上限）", target: nil, action: nil)
    let actionChoices = NSPopUpButton()
    let stepsLabel = NSTextField(wrappingLabelWithString: "1. 确认配置 → 2. 加入购物袋 → 3. 进入结账")
    var armButton: NSButton!
    var resumeButton: NSButton!
    var stopButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let isolated = CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--preview")
            let root = isolated ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["ASA_TEST_DATA_DIR"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("asa-preview-\(UUID().uuidString)").path) : base.appendingPathComponent("AppleStoreAssistantNative")
            store = try Storage(root: root)
            lockFD = Darwin.open(store.root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw AppError("另一个购买助手已在运行，请使用已有窗口") }
            saved = try store.read("plans.json", as: Saved.self) ?? Saved()
            pickupSettings = try store.read("pickup-settings.json", as: PickupSettings.self) ?? PickupSettings()
            do { checkoutProfile = try CheckoutProfileLaunchPolicy.load(isolated: isolated, from: checkoutProfileKeychain.load) }
            catch { checkoutProfileLoadError = error.localizedDescription }
            let hasSavedContact = !checkoutProfile.surname.isEmpty && !checkoutProfile.givenName.isEmpty &&
                !checkoutProfile.email.isEmpty && !checkoutProfile.phone.isEmpty && checkoutProfile.contactNameConfirmed
            pickupSectionCollapsed = !pickupSettings.preferredStoreNumber.isEmpty && hasSavedContact
            guard let directoryURL = Bundle.main.url(forResource: "AppleChinaStoreDirectory", withExtension: "json") else {
                throw AppError("缺少 Apple 官方门店目录")
            }
            pickupDirectory = try JSONDecoder().decode(AppleStoreDirectory.self, from: Data(contentsOf: directoryURL))
            let savedURL = store.root.appendingPathComponent("plans.json")
            if let data = try? Data(contentsOf: savedURL),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entries = json["plans"] as? [[String: Any]],
               entries.contains(where: { $0["releaseAt"] != nil }) {
                let backup = store.root.appendingPathComponent("plans.backup-before-product-only-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: savedURL, to: backup)
                try store.write(saved, "plans.json")
            }
            bridge = try String(contentsOf: Bundle.main.url(forResource: "StoreBridge", withExtension: "js")!, encoding: .utf8)
        } catch { alert("无法读取本地数据：\(error.localizedDescription)"); NSApp.terminate(nil); return }
        let browserSelfTest = CommandLine.arguments.contains("--browser-self-test")
        makeMenu()
        if browserSelfTest {
            Task { @MainActor [weak self] in await self?.runBrowserSelfTest() }
            return
        }
        makeWindow(); refreshPresets()
        if CommandLine.arguments.contains("--preview") {
            let v = Variant(partNumber:"DEMO001/A",family:"demo",selections:[:],label:"界面预览 · 演示商品",url:"https://www.apple.com.cn/shop/product/demo001/a",price:9999,comingSoon:true)
            let p = Plan(name:"预览计划",source:v.url,variant:v,catalogHash:"demo",releaseAt:Date().addingTimeInterval(600))
            saved = Saved(plans:[ProductPlan(p)],selectedID:p.id); refreshPresets()
        }
        if let p = saved.plans.first(where: { $0.id == saved.selectedID }) { apply(p) }
        if let checkoutProfileLoadError { log("钥匙串资料读取失败；本次不会自动填写个人资料：\(checkoutProfileLoadError)") }
        do {
            if let old = try store.read("run.json", as: RunRecord.self), !["cancelled", "handoff", "complete"].contains(old.state) {
                log("发现上次未完成的任务（\(old.state)）。已停止，不会在重启后补发；请检查购物袋/订单后重新托管。")
            }
        } catch { log("执行记录无法读取，请核实上次订单后再开始：\(error.localizedDescription)") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--self-test") {
            startDemo()
        } else {
            web.loadHTMLString(welcomeHTML, baseURL: nil)
            if !CommandLine.arguments.contains("--preview") { startManagedBrowser() }
        }
    }
    func makeMenu() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 Apple Store Assistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "编辑"; menu.addItem(editItem); let edit = NSMenu(); editItem.submenu = edit
        for (t,a,k) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] { edit.addItem(withTitle:t,action:Selector(a),keyEquivalent:k) }
        NSApp.mainMenu = menu
    }
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func collapseIcon(_ collapsed: Bool) -> NSImage {
        let name = collapsed ? "chevron.down.2" : "chevron.up.2"
        let fallback = collapsed ? "chevron.down" : "chevron.up"
        return NSImage(systemSymbolName: name, accessibilityDescription: collapsed ? "展开商品配置" : "收起商品配置")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: collapsed ? "展开商品配置" : "收起商品配置")
            ?? NSImage()
    }
    func workflowStatusItem(_ title: String) -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "circle", accessibilityDescription: title) ?? NSImage())
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .tertiaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        workflowIcons.append(icon)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.textColor = .secondaryLabelColor

        let item = NSStackView(views: [icon, label])
        item.orientation = .vertical
        item.alignment = .centerX
        item.spacing = 3
        item.widthAnchor.constraint(equalToConstant: 58).isActive = true
        return item
    }
    func makeWorkflowStatus() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        let titles = ["计划", "账号", "商品", "购买", "待付款"]
        for (index, title) in titles.enumerated() {
            stack.addArrangedSubview(workflowStatusItem(title))
            if index < titles.count - 1 {
                let connector = NSBox()
                connector.boxType = .custom
                connector.fillColor = .tertiaryLabelColor
                connector.widthAnchor.constraint(equalToConstant: 10).isActive = true
                connector.heightAnchor.constraint(equalToConstant: 1).isActive = true
                workflowConnectors.append(connector)
                stack.addArrangedSubview(connector)
            }
        }
        stack.setAccessibilityLabel("购买流程状态：计划、账号、商品、购买、待付款")
        return stack
    }
    func updateWorkflowStatus() {
        guard workflowIcons.count == 5, workflowConnectors.count == 4 else { return }
        let statuses = [
            workflowPlanSelected,
            workflowAccountReady,
            workflowProductLocked,
            [.purchasing, .verifyingBag, .checkingOut, .awaitingCheckout, .handoff].contains(automationPhase) || workflowCompleted,
            workflowCompleted
        ]
        let titles = ["计划", "账号", "商品", "购买", "待付款"]
        for (index, icon) in workflowIcons.enumerated() {
            let active = statuses[index]
            icon.image = NSImage(systemSymbolName: active ? "checkmark.circle.fill" : "circle", accessibilityDescription: titles[index])
            icon.contentTintColor = active ? .systemGreen : .tertiaryLabelColor
            icon.setAccessibilityLabel("\(titles[index])：\(active ? "已完成" : "未完成")")
        }
        for (index, connector) in workflowConnectors.enumerated() {
            connector.fillColor = statuses[index] ? .systemGreen : .tertiaryLabelColor
        }
    }
    func heading(_ text: String) -> NSTextField { let v = NSTextField(labelWithString: text); v.font = .systemFont(ofSize: 16, weight: .semibold); return v }
    func row(_ views: [NSView]) -> NSStackView { let r = NSStackView(views: views); r.orientation = .horizontal; r.spacing = 8; return r }
    func timingInput(_ title: String, _ field: NSTextField) -> NSStackView {
        let column = NSStackView(views: [NSTextField(labelWithString: title), field])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }
    func add(_ v: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }
    func settingsCard(_ title: String, content: NSStackView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .atTop
        box.title = title
        box.titleFont = .systemFont(ofSize: 13, weight: .semibold)
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 9
        box.contentViewMargins = NSSize(width: 12, height: 10)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        guard let cardContentView = box.contentView else { return box }
        cardContentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cardContentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cardContentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: cardContentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: cardContentView.bottomAnchor)
        ])
        box.setAccessibilityLabel(title)
        return box
    }
    func labeledSetting(_ title: String, control: NSControl) -> NSStackView {
        let column = FlippedStack()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.setAccessibilityLabel(title)
        control.setAccessibilityLabel(title)
        column.addArrangedSubview(label)
        column.addArrangedSubview(control)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }
    func newWeb() -> WKWebView {
        let c = WKWebViewConfiguration(); c.websiteDataStore = .default(); c.processPool = processPool
        c.preferences.javaScriptCanOpenWindowsAutomatically = true
        let w = WKWebView(frame: .zero, configuration: c); w.navigationDelegate = self; w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.setValue(false, forKey: "drawsBackground")
        return w
    }
    func installAccountDiagnostics(on webView: WKWebView) {
        webView.configuration.userContentController.add(self, name: "asaAccountNetwork")
        let source = #"""
        (() => {
          if (window.__asaAccountNetworkInstalled) return;
          window.__asaAccountNetworkInstalled = true;
          const safe = value => {
            try { const u = new URL(String(value), location.href); return u.origin + u.pathname; }
            catch (_) { return '<invalid-url>'; }
          };
          const send = (kind, url, status) => {
            try { window.webkit.messageHandlers.asaAccountNetwork.postMessage({kind, url:safe(url), status: Number(status) || 0}); } catch (_) {}
          };
          const originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function(input) {
              const url = typeof input === 'string' ? input : (input && input.url) || location.href;
              return originalFetch.apply(this, arguments).then(response => { send('fetch', response.url || url, response.status); return response; }, error => { send('fetch-error', url, 0); throw error; });
            };
          }
          const originalOpen = XMLHttpRequest.prototype.open;
          const originalSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method, url) { this.__asaURL = url; return originalOpen.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function() {
            this.addEventListener('load', () => send('xhr', this.responseURL || this.__asaURL || location.href, this.status));
            this.addEventListener('error', () => send('xhr-error', this.__asaURL || location.href, 0));
            return originalSend.apply(this, arguments);
          };
        })();
        """#
        webView.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1400,height: 940),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.title = "Apple Store Assistant · 购买托管"; window.minSize = NSSize(width: 1100,height: 760); window.center(); window.delegate = self
        web = newWeb(); accountWeb = web; accountWeb.customUserAgent = safariCompatibleUserAgent(); installAccountDiagnostics(on: accountWeb)
        let outer = NSStackView(); outer.orientation = .horizontal; outer.spacing = 0; outer.alignment = .top; outer.detachesHiddenViews = true
        window.contentView = outer
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let left = FlippedStack(); left.orientation = .vertical; left.alignment = .leading; left.spacing = 12
        left.edgeInsets = NSEdgeInsets(top:24,left:20,bottom:24,right:20)
        scroll.documentView = left
        left.translatesAutoresizingMaskIntoConstraints = false
        left.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        outer.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalToConstant: 410).isActive = true
        scroll.heightAnchor.constraint(equalTo: outer.heightAnchor).isActive = true
        let title = heading("选好计划，交给托管。"); title.font = .systemFont(ofSize:24,weight:.bold); add(title,to:left)
        workflowStatusStack = makeWorkflowStatus()
        add(workflowStatusStack,to:left)
        collapseProductButton = NSButton(image: collapseIcon(productSectionCollapsed), target: self, action: #selector(toggleProductSection))
        collapseProductButton.toolTip = productSectionCollapsed ? "展开商品配置" : "收起商品配置"
        collapseProductButton.setAccessibilityLabel(productSectionCollapsed ? "展开商品配置" : "收起商品配置")
        collapseProductButton.bezelStyle = .texturedRounded
        collapseProductButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let productHeading = row([heading("01  商品与配置"),collapseProductButton]); productHeading.alignment = .centerY
        add(productHeading,to:left)
        presets.target = self; presets.action = #selector(selectPreset); add(presets,to:left)
        preview.font = .monospacedSystemFont(ofSize:12,weight:.regular); preview.textColor = .secondaryLabelColor; add(preview,to:left)
        productDetails.orientation = .vertical; productDetails.spacing = 12; productDetails.alignment = .leading
        source.placeholderString = "粘贴 Apple 官方购买页链接"; add(source,to:productDetails)
        add(row([button("打开官网",#selector(openProduct)),button("读取规格",#selector(readCatalog)),button("读取当前商品",#selector(readCurrent))]),to:productDetails)
        specs.orientation = .vertical; specs.spacing = 8; specs.alignment = .leading; add(specs,to:productDetails)
        add(NSTextField(labelWithString:"计划名称（仅用于识别，不改变商品容量或型号）"),to:productDetails)
        add(name,to:productDetails)
        add(row([button("保存计划",#selector(savePlan)),button("另存为",#selector(saveAs)),button("删除计划",#selector(deletePlan))]),to:productDetails)
        add(row([button("导出",#selector(exportPlan)),button("导入",#selector(importPlan))]),to:productDetails)
        add(productDetails,to:left)
        productDetails.isHidden = productSectionCollapsed
        collapsePickupButton = NSButton(image: collapseIcon(pickupSectionCollapsed), target: self, action: #selector(togglePickupSection))
        collapsePickupButton.bezelStyle = .texturedRounded
        collapsePickupButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let pickupHeading = row([heading("02  取货与结账资料"),collapsePickupButton]); pickupHeading.alignment = .centerY
        add(pickupHeading,to:left)
        pickupSummary.textColor = .secondaryLabelColor
        pickupSummary.maximumNumberOfLines = 4
        add(pickupSummary,to:left)
        pickupDetails.orientation = .vertical; pickupDetails.spacing = 10; pickupDetails.alignment = .leading

        let storeCardContent = FlippedStack()
        storeCardContent.spacing = 7
        pickupCountry.addItem(withTitle: pickupDirectory?.countryName ?? "中国大陆")
        pickupCountry.isEnabled = false
        pickupCountry.toolTip = "当前购买流程使用 Apple 中国大陆商店；其他国家/地区尚未接入购买流程。"
        add(labeledSetting("国家/地区", control: pickupCountry),to:storeCardContent)
        pickupCity.addItem(withTitle:"请选择城市")
        pickupCity.target = self; pickupCity.action = #selector(selectPickupCity)
        add(labeledSetting("城市", control: pickupCity),to:storeCardContent)
        pickupStore.addItem(withTitle:"请选择首选门店")
        pickupStore.target = self; pickupStore.action = #selector(selectPickupStore)
        add(labeledSetting("首选门店", control: pickupStore),to:storeCardContent)
        pickupAutoSelect.target = self; pickupAutoSelect.action = #selector(togglePickupAutoSelect)
        pickupAutoSelect.state = pickupSettings.autoSelectPreferredStore ? .on : .off
        add(pickupAutoSelect,to:storeCardContent)
        let autoPickupHint = NSTextField(wrappingLabelWithString:"若结账页的取货搜索区域不同，会尝试切换到首选门店所在城市并选择可取货门店。不会改动配送地址或账户地区；无法确认时会停下提示。")
        autoPickupHint.textColor = .secondaryLabelColor
        autoPickupHint.maximumNumberOfLines = 3
        add(autoPickupHint,to:storeCardContent)
        pickupAddress.textColor = .secondaryLabelColor
        pickupAddress.maximumNumberOfLines = 3
        add(pickupAddress,to:storeCardContent)
        locatePickupButton = button("在结账页定位首选门店",#selector(locatePreferredPickupStore))
        locatePickupButton.toolTip = "在 Apple 结账页滚动并短暂高亮已保存的门店。"
        add(locatePickupButton,to:storeCardContent)
        let pickupHint = NSTextField(wrappingLabelWithString:"默认到店取货。门店目录来自 Apple；是否有货以结账页实时显示为准。")
        pickupHint.textColor = .secondaryLabelColor
        pickupHint.maximumNumberOfLines = 2
        add(pickupHint,to:storeCardContent)
        add(settingsCard("取货门店",content:storeCardContent),to:pickupDetails)

        let contactCardContent = FlippedStack()
        contactCardContent.spacing = 7
        contactSurname.placeholderString = "姓氏"
        contactGivenName.placeholderString = "名字"
        contactEmail.placeholderString = "Apple 取货通知邮箱"
        contactPhone.placeholderString = "联系人手机号码"
        contactIDLastFour.placeholderString = "身份证件号码后四位"
        add(labeledSetting("姓氏",control:contactSurname),to:contactCardContent)
        add(labeledSetting("名字",control:contactGivenName),to:contactCardContent)
        add(labeledSetting("电子邮件地址",control:contactEmail),to:contactCardContent)
        add(labeledSetting("联系人手机号码",control:contactPhone),to:contactCardContent)
        add(labeledSetting("政府身份证件号码后四位",control:contactIDLastFour),to:contactCardContent)
        add(confirmPickupName,to:contactCardContent)
        add(rememberContactIDLastFour,to:contactCardContent)
        let contactHint = NSTextField(wrappingLabelWithString:"取货姓名需与购买人和证件一致。只有 Apple 结账页要求时才填写身份证件后四位；默认不跨次保存。")
        contactHint.textColor = .secondaryLabelColor
        contactHint.maximumNumberOfLines = 3
        add(contactHint,to:contactCardContent)
        add(settingsCard("取货联系人",content:contactCardContent),to:pickupDetails)

        let invoiceCardContent = FlippedStack()
        invoiceCardContent.spacing = 8
        for invoiceType in AppleInvoiceType.allCases { defaultInvoiceType.addItem(withTitle:invoiceType.title) }
        defaultInvoiceType.target = self
        defaultInvoiceType.action = #selector(changeDefaultInvoiceType)
        add(labeledSetting("本次默认发票类型",control:defaultInvoiceType),to:invoiceCardContent)
        let invoiceEditorLabel = NSTextField(labelWithString:"编辑哪种发票预设")
        invoiceEditorLabel.font = .systemFont(ofSize:12,weight:.medium)
        add(invoiceEditorLabel,to:invoiceCardContent)
        invoiceProfileEditor.segmentStyle = .rounded
        invoiceProfileEditor.target = self
        invoiceProfileEditor.action = #selector(changeInvoiceProfileEditor)
        add(invoiceProfileEditor,to:invoiceCardContent)

        personalInvoiceFields.orientation = .vertical
        personalInvoiceFields.alignment = .leading
        personalInvoiceFields.spacing = 7
        personalInvoiceHeader.placeholderString = "留空时使用个人默认抬头"
        add(labeledSetting("发票抬头（选填）",control:personalInvoiceHeader),to:personalInvoiceFields)
        companyInvoiceFields.orientation = .vertical
        companyInvoiceFields.alignment = .leading
        companyInvoiceFields.spacing = 7
        companyInvoiceName.placeholderString = "公司名称"
        companyInvoiceTaxID.placeholderString = "纳税人识别号"
        add(labeledSetting("公司名称",control:companyInvoiceName),to:companyInvoiceFields)
        add(labeledSetting("纳税人识别号",control:companyInvoiceTaxID),to:companyInvoiceFields)
        companyHasNoTaxID.target = self
        companyHasNoTaxID.action = #selector(toggleCompanyHasNoTaxID)
        add(companyHasNoTaxID,to:companyInvoiceFields)
        vatInvoiceFields.orientation = .vertical
        vatInvoiceFields.alignment = .leading
        vatInvoiceFields.spacing = 7
        vatInvoiceCompanyName.placeholderString = "公司名称"
        vatInvoiceTaxID.placeholderString = "纳税人识别号"
        vatInvoiceBankName.placeholderString = "银行名称（选填）"
        vatInvoiceBankAccount.placeholderString = "银行账号"
        add(labeledSetting("公司名称",control:vatInvoiceCompanyName),to:vatInvoiceFields)
        add(labeledSetting("纳税人识别号",control:vatInvoiceTaxID),to:vatInvoiceFields)
        add(labeledSetting("银行名称（选填）",control:vatInvoiceBankName),to:vatInvoiceFields)
        add(labeledSetting("银行账号",control:vatInvoiceBankAccount),to:vatInvoiceFields)
        vatTermsAuthorization.lineBreakMode = .byWordWrapping
        vatTermsAuthorization.target = self
        vatTermsAuthorization.action = #selector(toggleVATTermsAuthorization)
        add(vatTermsAuthorization,to:vatInvoiceFields)
        let termsLink = button("阅读 Apple《发票条款》",#selector(openInvoiceTerms))
        add(termsLink,to:vatInvoiceFields)
        let companyInvoiceHint = NSTextField(wrappingLabelWithString:"公司发票只用于符合条件的公司采购。公司名称、税号和银行资料按 Apple 当前页面要求填写。")
        companyInvoiceHint.textColor = .secondaryLabelColor
        companyInvoiceHint.maximumNumberOfLines = 3
        add(companyInvoiceHint,to:invoiceCardContent)
        add(personalInvoiceFields,to:invoiceCardContent)
        add(companyInvoiceFields,to:invoiceCardContent)
        add(vatInvoiceFields,to:invoiceCardContent)
        checkoutProfileStatus.textColor = .secondaryLabelColor
        checkoutProfileStatus.maximumNumberOfLines = 2
        add(checkoutProfileStatus,to:invoiceCardContent)
        saveCheckoutProfileButton = button("保存联系人与发票资料",#selector(saveCheckoutProfile))
        clearCheckoutProfileButton = button("清除本机保存资料",#selector(clearCheckoutProfile))
        add(row([saveCheckoutProfileButton,clearCheckoutProfileButton]),to:invoiceCardContent)
        add(settingsCard("发票预设",content:invoiceCardContent),to:pickupDetails)

        let paymentCardContent = FlippedStack()
        paymentCardContent.spacing = 8
        paymentMethod.addItem(withTitle:"请选择付款方式")
        paymentMethod.addItem(withTitle:CheckoutPaymentMethod.alipay.title)
        paymentMethod.lastItem?.representedObject = CheckoutPaymentMethod.alipay.rawValue
        paymentMethod.addItem(withTitle:CheckoutPaymentMethod.wechat.title)
        paymentMethod.lastItem?.representedObject = CheckoutPaymentMethod.wechat.rawValue
        paymentMethod.target = self
        paymentMethod.action = #selector(changeCheckoutPaymentMethod)
        add(labeledSetting("付款方式",control:paymentMethod),to:paymentCardContent)
        let autoCheckoutHint = NSTextField(wrappingLabelWithString:"开启后会按所选支付宝或微信完成付款方式选择、检查订单和 Review 核对，最后创建待付款订单。程序不会点击“现在支付”或发起付款。")
        autoCheckoutHint.textColor = .secondaryLabelColor
        autoCheckoutHint.maximumNumberOfLines = 4
        add(autoCheckoutHint,to:paymentCardContent)
        autoCompleteCheckout.state = pickupSettings.autoCompleteCheckout ? .on : .off
        autoCompleteCheckout.target = self
        autoCompleteCheckout.action = #selector(toggleAutoCompleteCheckout)
        add(autoCompleteCheckout,to:paymentCardContent)
        add(settingsCard("付款与下单",content:paymentCardContent),to:pickupDetails)

        add(pickupDetails,to:left)
        refreshPickupControls()
        refreshCheckoutProfileControls()
        applyPickupSectionLayout()
        add(heading("03  抢购时间"),to:left)
        managedBrowserButton = button("启动专用浏览器",#selector(startManagedBrowser))
        accountCheckButton = button("重新检查",#selector(checkManagedAccount))
        accountCheckButton.toolTip = "自动检查异常时手动重试"
        accountExtras.orientation = .vertical; accountExtras.alignment = .leading; accountExtras.spacing = 8
        add(row([managedBrowserButton,button("打开专用商品页",#selector(openManagedProduct))]),to:accountExtras)
        add(row([accountCheckButton,button("检查浏览器连接",#selector(checkManagedBrowser))]),to:accountExtras)
        add(row([button("查看购物袋",#selector(openManagedBag)),button("准备商品页选项",#selector(prepareManagedProduct))]),to:accountExtras)
        add(browserWindowStatus,to:accountExtras)
        add(browserControlStatus,to:accountExtras)
        add(browserSession,to:accountExtras)
        release.datePickerStyle = .textFieldAndStepper; release.datePickerElements = [.yearMonthDay,.hourMinuteSecond]; release.dateValue = Date().addingTimeInterval(600)
        release.target = self; release.action = #selector(updateSchedulePreview)
        release.timeZone = .current; add(release,to:left)
        add(NSTextField(labelWithString:"时区：\(TimeZone.current.identifier) · 托管以当前设置时间为准"),to:left)
        let timingRow = row([
            timingInput("准备（秒）", prepare),
            timingInput("静默（秒）", quiet),
            timingInput("执行窗口（秒）", duration)
        ])
        timingRow.distribution = .fillEqually
        add(timingRow,to:left)
        for field in [prepare, quiet, duration] { field.delegate = self }
        schedulePreview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        schedulePreview.textColor = .secondaryLabelColor
        schedulePreview.maximumNumberOfLines = 5
        add(schedulePreview,to:left)
        updateSchedulePreview()
        staleRecovery.state = .on; add(staleRecovery,to:left)
        add(heading("04  一键托管"),to:left)
        add(NSTextField(wrappingLabelWithString:"自动连接浏览器 → 登录检查 → 商品准备 → 定时加购 → 进入结账。需要登录时会提示，完成后自动继续。最终付款由你决定。"),to:left)
        countdown.font = .monospacedDigitSystemFont(ofSize:30,weight:.semibold)
        state.font = .systemFont(ofSize:17,weight:.medium); state.textColor = .systemBlue
        armButton = button("一键托管",#selector(arm)); armButton.bezelStyle = .rounded; armButton.contentTintColor = .systemBlue
        resumeButton = button("查看浏览器",#selector(showManagedBrowser)); resumeButton.isEnabled = false
        resumeButton.isHidden = true
        stopButton = button("停止",#selector(cancel)); stopButton.isEnabled = false
        add(row([armButton,resumeButton,stopButton]),to:left)
        add(row([button("查看专用浏览器",#selector(showManagedBrowser)),button("查看任务录制",#selector(openLogs))]),to:left)
        accountExtrasButton = button("辅助操作与演练 ▾",#selector(toggleAccountExtras)); add(accountExtrasButton,to:left)
        add(button("离线流程演练",#selector(startDemo)),to:accountExtras)
        add(accountExtras,to:left); accountExtras.isHidden = true
        editControls = [source,name,presets,release,prepare,quiet,duration,autoSubmit,maxTotal,accountConfirmed,staleRecovery,managedBrowserButton,accountCheckButton,pickupCity,pickupStore,pickupAutoSelect,locatePickupButton,autoCompleteCheckout,paymentMethod,contactSurname,contactGivenName,contactEmail,contactPhone,contactIDLastFour,confirmPickupName,rememberContactIDLastFour,defaultInvoiceType,invoiceProfileEditor,personalInvoiceHeader,companyInvoiceName,companyInvoiceTaxID,companyHasNoTaxID,vatInvoiceCompanyName,vatInvoiceTaxID,vatInvoiceBankName,vatInvoiceBankAccount,vatTermsAuthorization,saveCheckoutProfileButton,clearCheckoutProfileButton]
        let right = NSStackView(); right.orientation = .vertical; right.spacing = 0; rightStack = right
        outer.addArrangedSubview(right); right.heightAnchor.constraint(equalTo:outer.heightAnchor).isActive = true
        right.widthAnchor.constraint(equalTo:outer.widthAnchor,constant:-410).isActive = true
        let dashboard = FlippedStack(); dashboard.orientation = .vertical; dashboard.alignment = .leading; dashboard.spacing = 16
        dashboard.edgeInsets = NSEdgeInsets(top:24,left:24,bottom:24,right:24)
        add(dashboard,to:right); dashboard.heightAnchor.constraint(equalToConstant:240).isActive = true
        add(heading("任务进度"),to:dashboard)
        add(countdown,to:dashboard); add(state,to:dashboard); add(session,to:dashboard)
        let hint = NSTextField(wrappingLabelWithString:"首次准备在托管后立即开始。请保持电脑开机、联网；程序可自动创建待付款订单，实际付款由你决定。下方保留本次运行记录。")
        hint.textColor = .secondaryLabelColor; add(hint,to:dashboard)
        let browserPanel = NSStackView(); browserPanel.orientation = .vertical; browserPanel.spacing = 0; rightBrowserStack = browserPanel
        add(browserPanel,to:right)
        let bar = row([button("返回",#selector(back)),button("刷新",#selector(reload)),pageURL]); bar.edgeInsets = NSEdgeInsets(top:10,left:12,bottom:10,right:12)
        add(bar,to:browserPanel); add(web,to:browserPanel); web.heightAnchor.constraint(greaterThanOrEqualToConstant:250).isActive = true
        let logs = NSScrollView(); logs.hasVerticalScroller = true; logs.documentView = logView; logScroll = logs
        logView.isEditable = false; logView.font = .monospacedSystemFont(ofSize:11,weight:.regular); logView.isVerticallyResizable = true; logView.autoresizingMask = [.width]
        add(logs,to:right); logHeightConstraint = logs.heightAnchor.constraint(equalToConstant:125); logHeightConstraint.isActive = true
        applyProductSectionLayout()
        updateWorkflowStatus()
    }
    @objc func toggleProductSection() {
        productSectionCollapsed.toggle()
        applyProductSectionLayout()
    }
    @objc func togglePickupSection() {
        pickupSectionCollapsed.toggle()
        applyPickupSectionLayout()
    }
    @objc func toggleAccountExtras() {
        accountExtras.isHidden.toggle()
        accountExtrasButton.title = accountExtras.isHidden ? "辅助操作与演练 ▾" : "收起辅助操作 ▴"
    }
    func applyProductSectionLayout() {
        let collapsed = productSectionCollapsed
        productDetails.isHidden = collapsed
        rightBrowserStack.isHidden = collapsed
        collapseProductButton.image = collapseIcon(collapsed)
        collapseProductButton.toolTip = collapsed ? "展开商品配置" : "收起商品配置"
        collapseProductButton.setAccessibilityLabel(collapsed ? "展开商品配置" : "收起商品配置")
        logHeightConstraint.isActive = false
        logHeightConstraint = collapsed
            ? logScroll.heightAnchor.constraint(equalTo: rightStack.heightAnchor, constant: -240)
            : logScroll.heightAnchor.constraint(equalToConstant: 125)
        logHeightConstraint.isActive = true
    }
    func applyPickupSectionLayout() {
        let selectedStore = pickupDirectory?.stores.first(where: { $0.storeNumber == pickupSettings.preferredStoreNumber && $0.city == pickupSettings.city })
        let collapsed = pickupSectionCollapsed
        pickupDetails.isHidden = collapsed
        pickupSummary.isHidden = !collapsed
        let storeSummary = selectedStore.map { "\($0.city) · Apple \($0.name)" } ?? "门店待设置"
        let contactReady = !checkoutProfile.surname.isEmpty && !checkoutProfile.givenName.isEmpty && !checkoutProfile.email.isEmpty && !checkoutProfile.phone.isEmpty && checkoutProfile.contactNameConfirmed
        let invoiceTitle = AppleInvoiceType(rawValue:pickupSettings.defaultInvoiceType)?.title ?? AppleInvoiceType.personal.title
        let paymentTitle = CheckoutPaymentMethod(rawValue:pickupSettings.paymentMethod)?.title ?? "待选择"
        pickupSummary.stringValue = "\(storeSummary)\n联系人：\(contactReady ? "已配置" : "待配置") · 默认发票：\(invoiceTitle)\n付款方式：\(paymentTitle)"
        collapsePickupButton.image = collapseIcon(collapsed)
        let collapseLabel = collapsed ? "展开取货与结账资料" : "收起取货与结账资料"
        collapsePickupButton.toolTip = collapseLabel
        collapsePickupButton.setAccessibilityLabel(collapseLabel)
        collapsePickupButton.isEnabled = true
    }
    func safariCompatibleUserAgent() -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6.2 Safari/605.1.15"
    }
    func log(_ message: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        logLines.append("[\(f.string(from:Date()))] \(message)"); if logLines.count > 400 { logLines.removeFirst() }
        logView.string = logLines.joined(separator:"\n"); logView.scrollToEndOfDocument(nil)
        try? store.write(logLines,"events.json")
    }
    func recordTask(_ name: String, _ details: [String: String] = [:]) {
        guard let taskRecording, let run else { return }
        do {
            try taskRecording.append(name, run: run, releaseUptime: monotonicTarget > 0 ? monotonicTarget : nil, details: details)
        } catch {
            taskRecording.close()
            self.taskRecording = nil
            log("任务录制写入失败，购买流程不受影响：\(error.localizedDescription)")
        }
    }
    func setAccountStatus(_ message: String) {
        guard session.stringValue != message else { return }
        session.stringValue = message
        log("[账号状态] \(message)")
    }
    func setWindowStatus(_ message: String) {
        guard browserWindowStatus.stringValue != message else { return }
        browserWindowStatus.stringValue = message
        log("[浏览器窗口] \(message)")
    }
    func setControlStatus(_ message: String) {
        guard browserControlStatus.stringValue != message else { return }
        browserControlStatus.stringValue = message
        log("[控制连接] \(message)")
    }
    func setBrowserStatus(_ message: String) {
        guard browserSession.stringValue != message else { return }
        browserSession.stringValue = message
        log("[浏览器状态] \(message)")
    }
    func alert(_ message: String) { let a = NSAlert(); a.messageText = "Apple Store Assistant"; a.informativeText = message; a.runModal() }
    func decoded<T: Decodable>(_ value: Any?, as type: T.Type) throws -> T {
        guard let value else { throw AppError("网页未返回数据") }
        return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))
    }
    func js(_ expression: String, in browser: WKWebView? = nil, completion: @escaping (Any?, Error?) -> Void) {
        (browser ?? web).evaluateJavaScript(bridge + "\n" + expression) { result, error in completion(result,error) }
    }
    func navigate(_ raw: String) { guard let url = URL(string:raw) else { return }; web.load(URLRequest(url:url)); pageURL.stringValue = "\(url.host ?? "")\(url.path)" }
    func mutable() -> Bool { if run != nil { alert("托管中已固定本次配置，请先停止再编辑。") ; return false }; return true }
    func refreshPickupControls() {
        guard let directory = pickupDirectory else { return }
        suppressPickupActions = true
        defer { suppressPickupActions = false }
        pickupCountry.removeAllItems()
        pickupCountry.addItem(withTitle: directory.countryName)
        let cities = Array(Set(directory.stores.map(\.city))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        pickupCity.removeAllItems()
        pickupCity.addItem(withTitle: "请选择城市")
        pickupCity.addItems(withTitles: cities)
        if let cityIndex = cities.firstIndex(of: pickupSettings.city) { pickupCity.selectItem(at: cityIndex + 1) }
        refreshPickupStores()
    }
    func refreshPickupStores() {
        guard let directory = pickupDirectory else { return }
        suppressPickupActions = true
        defer { suppressPickupActions = false }
        pickupStore.removeAllItems()
        pickupStore.addItem(withTitle: pickupSettings.city.isEmpty ? "请先选择城市" : "请选择首选门店")
        let stores = directory.stores.filter { $0.city == pickupSettings.city }
        for item in stores {
            pickupStore.addItem(withTitle: item.name)
            pickupStore.lastItem?.representedObject = item.storeNumber
        }
        if let index = stores.firstIndex(where: { $0.storeNumber == pickupSettings.preferredStoreNumber }) {
            pickupStore.selectItem(at: index + 1)
            pickupAddress.stringValue = stores[index].address
        } else {
            pickupSettings.preferredStoreNumber = ""
            pickupAddress.stringValue = pickupSettings.city.isEmpty ? "请选择取货城市和首选门店。" : "请选择一家首选门店。"
        }
        pickupStore.isEnabled = !stores.isEmpty
    }
    func refreshCheckoutProfileControls() {
        suppressPickupActions = true
        defer { suppressPickupActions = false }
        contactSurname.stringValue = checkoutProfile.surname
        contactGivenName.stringValue = checkoutProfile.givenName
        contactEmail.stringValue = checkoutProfile.email
        contactPhone.stringValue = checkoutProfile.phone
        contactIDLastFour.stringValue = checkoutProfile.nationalIDLastFour
        confirmPickupName.state = checkoutProfile.contactNameConfirmed ? .on : .off
        rememberContactIDLastFour.state = checkoutProfile.rememberNationalIDLastFour ? .on : .off
        personalInvoiceHeader.stringValue = checkoutProfile.personalInvoiceHeader
        companyInvoiceName.stringValue = checkoutProfile.companyName
        companyInvoiceTaxID.stringValue = checkoutProfile.companyTaxpayerID
        companyHasNoTaxID.state = checkoutProfile.companyHasNoTaxpayerID ? .on : .off
        vatInvoiceCompanyName.stringValue = checkoutProfile.vatCompanyName
        vatInvoiceTaxID.stringValue = checkoutProfile.vatTaxpayerID
        vatInvoiceBankName.stringValue = checkoutProfile.vatBankName
        vatInvoiceBankAccount.stringValue = checkoutProfile.vatBankAccount
        vatTermsAuthorization.state = checkoutProfile.vatTermsAuthorized ? .on : .off
        autoCompleteCheckout.state = pickupSettings.autoCompleteCheckout ? .on : .off
        if let method = CheckoutPaymentMethod(rawValue:pickupSettings.paymentMethod),
           let index = paymentMethod.itemArray.firstIndex(where: { ($0.representedObject as? String) == method.rawValue }) {
            paymentMethod.selectItem(at:index)
        } else {
            paymentMethod.selectItem(at:0)
        }
        let invoiceTypes = AppleInvoiceType.allCases
        let defaultIndex = invoiceTypes.firstIndex(where: { $0.rawValue == pickupSettings.defaultInvoiceType }) ?? 0
        pickupSettings.defaultInvoiceType = invoiceTypes[defaultIndex].rawValue
        defaultInvoiceType.selectItem(at: defaultIndex)
        editingInvoiceType = invoiceTypes.indices.contains(invoiceProfileEditor.selectedSegment)
            ? invoiceTypes[invoiceProfileEditor.selectedSegment] : .personal
        updateInvoiceProfileEditorVisibility()
        companyInvoiceTaxID.isEnabled = !checkoutProfile.companyHasNoTaxpayerID
        rememberContactIDLastFour.toolTip = "仅将身份证件号码后四位保存在 macOS 钥匙串；关闭此项后不会跨次保存。"
        if checkoutProfileLoadError != nil {
            checkoutProfileStatus.stringValue = "钥匙串读取失败；自动填写个人资料已暂停"
        } else if checkoutProfileHasContent(checkoutProfile) {
            checkoutProfileStatus.stringValue = "资料保存在本机 macOS 钥匙串；不会写入任务记录"
        } else {
            checkoutProfileStatus.stringValue = "联系人与发票资料尚未保存到本机钥匙串"
        }
        applyPickupSectionLayout()
    }
    func checkoutProfileHasContent(_ profile: SecureCheckoutProfile) -> Bool {
        !profile.surname.isEmpty || !profile.givenName.isEmpty || !profile.email.isEmpty || !profile.phone.isEmpty ||
        !profile.nationalIDLastFour.isEmpty || profile.contactNameConfirmed || !profile.personalInvoiceHeader.isEmpty || !profile.companyName.isEmpty ||
        !profile.companyTaxpayerID.isEmpty || !profile.vatCompanyName.isEmpty || !profile.vatTaxpayerID.isEmpty ||
        !profile.vatBankName.isEmpty || !profile.vatBankAccount.isEmpty
    }
    func collectCheckoutProfileFromControls() -> SecureCheckoutProfile {
        var result = checkoutProfile
        result.surname = contactSurname.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.givenName = contactGivenName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.email = contactEmail.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.phone = contactPhone.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.nationalIDLastFour = contactIDLastFour.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        result.contactNameConfirmed = confirmPickupName.state == .on
        result.rememberNationalIDLastFour = rememberContactIDLastFour.state == .on
        result.personalInvoiceHeader = personalInvoiceHeader.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.companyName = companyInvoiceName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.companyTaxpayerID = companyInvoiceTaxID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.companyHasNoTaxpayerID = companyHasNoTaxID.state == .on
        result.vatCompanyName = vatInvoiceCompanyName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.vatTaxpayerID = vatInvoiceTaxID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.vatBankName = vatInvoiceBankName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.vatBankAccount = vatInvoiceBankAccount.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.vatTermsAuthorized = vatTermsAuthorization.state == .on
        return result
    }
    func checkoutProfileIsDirty() -> Bool {
        collectCheckoutProfileFromControls() != checkoutProfile
    }
    func updateInvoiceProfileEditorVisibility() {
        personalInvoiceFields.isHidden = editingInvoiceType != .personal
        companyInvoiceFields.isHidden = editingInvoiceType != .company
        vatInvoiceFields.isHidden = editingInvoiceType != .vatSpecial
    }
    @objc func changeInvoiceProfileEditor() {
        guard !suppressPickupActions else { return }
        let types = AppleInvoiceType.allCases
        guard types.indices.contains(invoiceProfileEditor.selectedSegment) else { return }
        editingInvoiceType = types[invoiceProfileEditor.selectedSegment]
        updateInvoiceProfileEditorVisibility()
    }
    @objc func changeDefaultInvoiceType() {
        guard !suppressPickupActions, mutable() else { return }
        let types = AppleInvoiceType.allCases
        guard types.indices.contains(defaultInvoiceType.indexOfSelectedItem) else { return }
        let previous = pickupSettings.defaultInvoiceType
        pickupSettings.defaultInvoiceType = types[defaultInvoiceType.indexOfSelectedItem].rawValue
        do { try persistPickupSettings(); applyPickupSectionLayout() }
        catch {
            pickupSettings.defaultInvoiceType = previous
            refreshCheckoutProfileControls()
            alert("保存默认发票类型失败：\(error.localizedDescription)")
        }
    }
    @objc func changeCheckoutPaymentMethod() {
        guard !suppressPickupActions, mutable() else { return }
        let previous = pickupSettings.paymentMethod
        pickupSettings.paymentMethod = paymentMethod.selectedItem?.representedObject as? String ?? ""
        do {
            try persistPickupSettings()
            applyPickupSectionLayout()
            if let method = CheckoutPaymentMethod(rawValue:pickupSettings.paymentMethod) {
                log("已保存默认付款方式：\(method.title)")
            }
        } catch {
            pickupSettings.paymentMethod = previous
            refreshCheckoutProfileControls()
            alert("保存付款方式失败：\(error.localizedDescription)")
        }
    }
    @objc func toggleAutoCompleteCheckout() {
        guard !suppressPickupActions, mutable() else { return }
        let previous = pickupSettings.autoCompleteCheckout
        pickupSettings.autoCompleteCheckout = autoCompleteCheckout.state == .on
        do { try persistPickupSettings() }
        catch {
            pickupSettings.autoCompleteCheckout = previous
            autoCompleteCheckout.state = previous ? .on : .off
            alert("保存结账自动继续设置失败：\(error.localizedDescription)")
        }
    }
    @objc func toggleCompanyHasNoTaxID() {
        guard !suppressPickupActions else { return }
        companyInvoiceTaxID.isEnabled = companyHasNoTaxID.state != .on
    }
    @objc func toggleVATTermsAuthorization() {
        guard !suppressPickupActions else { return }
        checkoutProfileStatus.stringValue = vatTermsAuthorization.state == .on
            ? "专票条款授权尚未保存；请阅读条款并保存资料后生效"
            : "专票条款自动勾选授权尚未保存"
    }
    @objc func openInvoiceTerms() {
        guard let url = URL(string:"https://www.apple.com.cn/shop/help/invoice") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc func saveCheckoutProfile() {
        guard mutable() else { return }
        let profile = collectCheckoutProfileFromControls()
        if !profile.nationalIDLastFour.isEmpty,
           profile.nationalIDLastFour.range(of:"^[0-9]{3}[0-9X]$",options:.regularExpression) == nil {
            alert("身份证件号码这里只保存后四位，请输入 3 个数字加 1 个数字或 X。")
            return
        }
        let profileForKeychain: SecureCheckoutProfile
        if profile.rememberNationalIDLastFour {
            profileForKeychain = profile
        } else {
            var safe = profile
            safe.nationalIDLastFour = ""
            safe.rememberNationalIDLastFour = false
            profileForKeychain = safe
        }
        do {
            try checkoutProfileKeychain.save(profileForKeychain)
            checkoutProfile = profile
            checkoutProfileLoadError = nil
            checkoutProfileStatus.stringValue = profile.rememberNationalIDLastFour
                ? "资料已保存到本机钥匙串；身份证后四位也已保存"
                : "资料已保存到本机钥匙串；身份证后四位仅保留在当前会话"
            log("联系人与发票预设已保存到本机钥匙串；敏感资料未写入任务记录")
            applyPickupSectionLayout()
        } catch {
            checkoutProfileStatus.stringValue = "钥匙串保存失败；资料未写入普通文件"
            alert(error.localizedDescription)
        }
    }
    @objc func clearCheckoutProfile() {
        guard mutable() else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "清除本机保存的联系人与发票资料？"
        confirmation.informativeText = "资料会从 macOS 钥匙串删除。取货门店和发票类型偏好不会清除。"
        confirmation.addButton(withTitle:"清除资料")
        confirmation.addButton(withTitle:"取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        do {
            try checkoutProfileKeychain.delete()
            checkoutProfile = SecureCheckoutProfile()
            checkoutProfileLoadError = nil
            refreshCheckoutProfileControls()
            log("已清除本机钥匙串中的联系人与发票资料")
        } catch { alert(error.localizedDescription) }
    }
    func persistPickupSettings() throws {
        try store.write(pickupSettings, "pickup-settings.json")
    }
    @objc func selectPickupCity() {
        guard !suppressPickupActions, mutable() else { return }
        let selected = pickupCity.indexOfSelectedItem > 0 ? pickupCity.titleOfSelectedItem ?? "" : ""
        guard selected != pickupSettings.city else { return }
        pickupSettings.city = selected
        pickupSettings.preferredStoreNumber = ""
        refreshPickupStores()
        pickupSectionCollapsed = false
        applyPickupSectionLayout()
        do { try persistPickupSettings() }
        catch { alert("保存取货设置失败：\(error.localizedDescription)") }
    }
    @objc func selectPickupStore() {
        guard !suppressPickupActions, mutable() else { return }
        guard let storeNumber = pickupStore.selectedItem?.representedObject as? String,
              let item = pickupDirectory?.stores.first(where: { $0.storeNumber == storeNumber }) else { return }
        pickupSettings.countryCode = pickupDirectory?.countryCode ?? "zh_CN"
        pickupSettings.city = item.city
        pickupSettings.preferredStoreNumber = item.storeNumber
        pickupAddress.stringValue = item.address
        do {
            try persistPickupSettings()
            let contactReady = !checkoutProfile.surname.isEmpty && !checkoutProfile.givenName.isEmpty &&
                !checkoutProfile.email.isEmpty && !checkoutProfile.phone.isEmpty && checkoutProfile.contactNameConfirmed
            pickupSectionCollapsed = contactReady
            applyPickupSectionLayout()
            log("已保存并确认取货地址：\(item.city) · Apple \(item.name)")
        }
        catch { alert("保存取货设置失败：\(error.localizedDescription)") }
    }
    @objc func togglePickupAutoSelect() {
        guard !suppressPickupActions, mutable() else { return }
        let previous = pickupSettings.autoSelectPreferredStore
        pickupSettings.autoSelectPreferredStore = pickupAutoSelect.state == .on
        do {
            try persistPickupSettings()
            log(pickupSettings.autoSelectPreferredStore ? "已开启结账时自动选择首选门店" : "已关闭结账时自动选择首选门店")
            applyPickupSectionLayout()
        } catch {
            pickupSettings.autoSelectPreferredStore = previous
            pickupAutoSelect.state = previous ? .on : .off
            alert("保存取货设置失败：\(error.localizedDescription)")
        }
    }
    @objc func locatePreferredPickupStore() {
        guard mutable(), manualBrowserOperations == 0 else { return }
        guard let item = pickupDirectory?.stores.first(where: { $0.storeNumber == pickupSettings.preferredStoreNumber && $0.city == pickupSettings.city }) else {
            alert("请先选择并保存城市和首选门店。")
            return
        }
        guard let browser, browser.isConnected else {
            alert("请先连接专用浏览器，并在 Apple 结账页打开取货门店列表。")
            return
        }
        let argsData = try? JSONSerialization.data(withJSONObject: [item.city, item.name])
        guard let argsData, let args = String(data: argsData, encoding: .utf8) else {
            alert("无法准备门店定位信息。")
            return
        }
        let expression = """
        (() => {
          const [city,name] = \(args);
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const norm = s => String(s || '').replace(/[\\u200b-\\u200f\\u2060]/g, '').replace(/\\s+/g, ' ').trim();
          const text = e => norm((e.innerText || '') + ' ' + (e.getAttribute('aria-label') || ''));
          if (!/^(www|secure\\d*\\.www)\\.apple\\.com\\.cn$/i.test(location.hostname) || !/^\\/shop\\/checkout(?:\\/|$)/i.test(location.pathname))
            return {state:'wrong_page'};
          const nodes = [...document.querySelectorAll('label,[role="radio"],button,input[type="radio"],[data-autom]')].filter(visible);
          let matches = nodes.filter(e => text(e).includes(norm(name)));
          const inCity = matches.filter(e => text(e).includes(norm(city)));
          if (inCity.length) matches = inCity;
          if (!matches.length) return {state:'not_found'};
          matches.sort((a,b) => text(a).length - text(b).length);
          const target = matches[0];
          const radio = target.matches('input[type="radio"]') ? target : target.querySelector('input[type="radio"]');
          const disabled = !!(target.disabled || target.getAttribute('aria-disabled') === 'true' || radio?.disabled || radio?.getAttribute('aria-disabled') === 'true');
          target.scrollIntoView({behavior:'smooth',block:'center'});
          const outline = target.style.outline;
          const shadow = target.style.boxShadow;
          target.style.outline = '3px solid #0071e3';
          target.style.boxShadow = '0 0 0 5px rgba(0,113,227,.18)';
          setTimeout(() => { target.style.outline = outline; target.style.boxShadow = shadow; }, 3500);
          return {state:'located',available:!disabled,label:text(target)};
        })()
        """
        manualBrowserOperations += 1
        locatePickupButton.isEnabled = false
        Task { @MainActor [weak self, weak browser] in
            guard let self, let browser else { return }
            defer { self.manualBrowserOperations -= 1; self.locatePickupButton.isEnabled = true }
            do {
                let result = try await browser.evaluate(expression) as? [String: Any] ?? [:]
                switch result["state"] as? String {
                case "located":
                    let available = result["available"] as? Bool == true
                    let message = available
                        ? "已滚动并高亮 Apple \(item.city) · \(item.name)。请核对门店后自行点击选择。"
                        : "已定位 Apple \(item.city) · \(item.name)，但页面当前显示此店不可取货。"
                    self.log(message)
                    self.alert(message)
                case "wrong_page":
                    self.alert("专用浏览器当前不在 Apple 结账页。请打开结账页并选择“我要取货”后重试。")
                default:
                    self.alert("在当前门店列表中找不到 Apple \(item.city) · \(item.name)。请确认已选择“我要取货”、搜索区域正确且门店列表已加载。")
                }
            } catch {
                self.alert("门店定位失败：\(error.localizedDescription)")
            }
        }
    }
    @objc func openProduct() { guard mutable() else { return }; guard officialProductURL(source.stringValue) else { alert("请输入不带查询参数的 Apple 官方 /shop/ 购买页链接"); return }; navigate(source.stringValue) }
    @objc func readCatalog() {
        guard mutable() else { return }
        js("StoreAssistant.catalog()") { [weak self] value,error in
            guard let s = self else { return }
            do { if let error { throw error }; let c: Catalog = try s.decoded(value,as:Catalog.self)
                if let invalid = c.variants.first(where: { !officialProductURL($0.url) }) {
                    s.log("目录链接校验失败：\(invalid.partNumber) → \(invalid.url)")
                    throw AppError("目录非法官网链接：\(invalid.partNumber) → \(invalid.url)")
                }
                // Keep an existing plan ID while loading its catalog. The
                // user can update it with “保存计划” or copy it with “另存为”.
                // The popup itself is cleared because the catalog is now an
                // in-progress edit, not an applied saved plan.
                s.catalog = c; s.variant = nil; s.latestActions = []; s.autoSubmit.state = .off; s.source.stringValue = c.source; if s.plan == nil { s.name.stringValue = c.title }; s.renderOptions(c); s.updateSteps()
                s.clearPresetSelection()
                s.workflowPlanSelected = false; s.workflowProductLocked = false; s.workflowCompleted = false; s.updateWorkflowStatus()
                s.log("已读取官方目录：\(c.title)，\(c.variants.count) 个变体；请选择完整规格")
            } catch { s.alert(error.localizedDescription) }
        }
    }
    func renderOptions(_ c: Catalog) {
        specs.arrangedSubviews.forEach { specs.removeArrangedSubview($0); $0.removeFromSuperview() }; options = []
        for group in c.groups {
            let pop = NSPopUpButton(); pop.addItem(withTitle:"请选择"); pop.addItems(withTitles:group.options.map(\.label)); pop.target = self; pop.action = #selector(selectOptions)
            options.append((group,pop)); add(row([NSTextField(labelWithString:group.title),pop]),to:specs)
        }
        updatePreview()
    }
    @objc func selectOptions() {
        guard run == nil, let c = catalog else { return }
        var picks: [String:String] = [:]
        for (g,p) in options where p.indexOfSelectedItem > 0 { picks[g.key] = g.options[p.indexOfSelectedItem-1].value }
        // Keep the selected plan ID while editing its configuration.  The
        // explicit "另存为" action is the only path that creates a copy.
        variant = c.resolve(picks); latestActions = []; autoSubmit.state = .off; maxTotal.doubleValue = variant?.price ?? 0; updateSteps()
        updatePreview()
        workflowProductLocked = false; workflowCompleted = false; updateWorkflowStatus()
        if let v = variant { navigate(v.url) }
    }
    func updatePreview() {
        if let v = variant {
            preview.stringValue = "\(v.label)\n\(v.partNumber) · 数量 1\n\(v.price > 0 ? String(format:"参考价 ¥ %.2f",v.price) : "价格以官网为准")\(v.comingSoon ? " · 尚未开售" : "")"
            if maxTotal.doubleValue == 0 { maxTotal.doubleValue = v.price }
        } else { preview.stringValue = "请选择全部规格；仅唯一有效组合可保存与托管。" }
    }
    func clearPresetSelection() {
        suppressPresetAction = true
        presets.selectItem(at: 0)
        suppressPresetAction = false
    }
    func variantPath(_ raw: String) -> String? {
        guard let url = URL(string: raw), url.host == "www.apple.com.cn" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts.last?.lowercased() == "a",
              parts[parts.count - 2].range(of: "^[a-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return "/" + parts[parts.count - 2].lowercased() + "/a"
    }
    func ensurePageMatchesVariant(_ v: Variant) throws {
        guard let current = web.url?.absoluteString,
              let currentPath = variantPath(current),
              let expectedPath = variantPath(v.url),
              currentPath != expectedPath else { return }
        throw AppError("左侧方案是 \(v.label)（\(v.partNumber)），但右侧官网页面仍是 \(currentPath)。请先点击「读取当前商品」，确认预览中的型号和链接后再保存。")
    }
    @objc func readCurrent() {
        guard mutable() else { return }
        js("StoreAssistant.current()") { [weak self] value,error in
            guard let s = self else { return }
            struct Current: Decodable { let source:String; let title:String; let variant:Variant }
            do { if let error { throw error }; let c:Current = try s.decoded(value,as:Current.self)
                guard officialProductURL(c.variant.url) else { throw AppError("商品链接不是官方购买页") }
                s.catalog = nil; s.plan = nil; s.latestActions = []; s.autoSubmit.state = .off; s.variant = c.variant; s.source.stringValue = c.source; s.name.stringValue = c.title; s.updateSteps()
                s.clearPresetSelection()
                s.workflowPlanSelected = false; s.workflowProductLocked = false; s.workflowCompleted = false; s.updateWorkflowStatus()
                s.specs.arrangedSubviews.forEach { s.specs.removeArrangedSubview($0); $0.removeFromSuperview() }; s.options = []
                s.updatePreview(); s.log("已读取当前选定商品：\(c.variant.partNumber)")
            } catch { s.alert(error.localizedDescription) }
        }
    }
    func makeProductPlan() throws -> ProductPlan {
        guard let v = variant else { throw AppError("请先选择完整商品规格或读取当前商品") }
        var p = plan ?? ProductPlan(name:name.stringValue,source:source.stringValue,variant:v,catalogHash:catalog?.hash ?? "page-capture")
        p.name = name.stringValue; p.source = source.stringValue; p.variant = v; if let hash = catalog?.hash { p.catalogHash = hash }
        try p.validate(); return p
    }
    func makePlan() throws -> Plan {
        if checkoutProfileIsDirty() {
            throw AppError("取货联系人或发票资料有未保存的修改，请先保存到 macOS 钥匙串。")
        }
        guard pickupSettings.countryCode == "zh_CN",
              pickupDirectory?.stores.contains(where: { $0.storeNumber == pickupSettings.preferredStoreNumber && $0.city == pickupSettings.city }) == true else {
            throw AppError("请先在“取货设置”中选择城市和首选门店，再开始托管。")
        }
        var p = try makeProductPlan().executionPlan(releaseAt: release.dateValue)
        p.prepareSeconds = prepare.doubleValue; p.quietSeconds = quiet.doubleValue; p.executionSeconds = duration.doubleValue
        p.autoSubmit = false; p.maxTotal = maxTotal.doubleValue
        p.actions = defaultActions(); p.recoverStalePage = staleRecovery.state == .on
        try p.validate(now:Date()); return p
    }
    @objc func updateSchedulePreview() {
        let values = [prepare, quiet, duration].map { Double($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let preparation = values[0], let silence = values[1], let execution = values[2],
              preparation.isFinite, silence.isFinite, execution.isFinite,
              preparation >= silence, silence >= 0, preparation <= 86400,
              execution >= 5, execution <= 300 else {
            schedulePreview.stringValue = "时间轴：请输入有效秒数（准备 ≥ 静默，执行窗口 5–300 秒）"
            schedulePreview.textColor = .systemOrange
            return
        }
        let times = managedScheduleTimes(releaseAt: release.dateValue, prepareSeconds: preparation, quietSeconds: silence, executionSeconds: execution)
        let formatter = DateFormatter()
        formatter.timeZone = release.timeZone ?? .current
        formatter.dateFormat = "yyyy/M/d HH:mm:ss"
        let prefix = release.dateValue <= Date() ? "所选触发时间已过，请重新设定。\n" : ""
        schedulePreview.stringValue = prefix + [
            "准备复核  \(formatter.string(from: times.preparationStarts))",
            "静默开始  \(formatter.string(from: times.quietStarts))",
            "执行开始  \(formatter.string(from: times.executionStarts))",
            "执行截止  \(formatter.string(from: times.executionEnds))"
        ].joined(separator: "\n")
        schedulePreview.textColor = prefix.isEmpty ? .secondaryLabelColor : .systemOrange
    }
    func controlTextDidChange(_ obj: Notification) { updateSchedulePreview() }
    func controlTextDidEndEditing(_ obj: Notification) { updateSchedulePreview() }
    func persist(_ p: ProductPlan) throws {
        var next = saved
        if let i = next.plans.firstIndex(where:{$0.id == p.id}) { next.plans[i] = p } else { next.plans.append(p) }
        next.selectedID = p.id; try store.write(next,"plans.json"); saved = next; plan = p; refreshPresets()
        workflowPlanSelected = true; workflowCompleted = false; updateWorkflowStatus()
    }
    @objc func savePlan() { guard mutable() else { return }; do { let p = try makeProductPlan(); try persist(p); log("计划已保存：\(p.name) · \(p.variant.label) · \(p.variant.partNumber)") } catch { alert(error.localizedDescription) } }
    @objc func saveAs() { guard mutable() else { return }; do { var p = try makeProductPlan(); p.id = UUID().uuidString; try persist(p); log("已另存新计划：\(p.name) · \(p.variant.label) · \(p.variant.partNumber)") } catch { alert(error.localizedDescription) } }
    func presetTitle(_ p: ProductPlan) -> String { "\(p.name) · \(p.variant.label) · \(p.variant.partNumber)" }
    func refreshPresets() {
        suppressPresetAction = true
        defer { suppressPresetAction = false }
        presets.removeAllItems()
        presets.addItem(withTitle:"选择已保存的计划")
        for p in saved.plans {
            presets.addItem(withTitle: presetTitle(p))
            // The title is for display only. The stable plan ID is the
            // identity used when the user selects or deletes an item.
            presets.menu?.items.last?.representedObject = p.id
        }
        if let i = saved.plans.firstIndex(where:{$0.id == saved.selectedID}) { presets.selectItem(at:i+1) }
    }
    @objc func selectPreset() {
        guard !suppressPresetAction,
              presets.indexOfSelectedItem > 0,
              mutable(),
              let id = presets.selectedItem?.representedObject as? String,
              let p = saved.plans.first(where: { $0.id == id }) else { return }
        apply(p)
        log("已选择计划：\(p.name) · \(p.variant.label) · \(p.variant.partNumber)")
    }
    @objc func deletePlan() {
        guard mutable(), presets.indexOfSelectedItem > 0 else {
            alert("请先在下拉框中选择要删除的商品配置。")
            return
        }
        guard let id = presets.selectedItem?.representedObject as? String,
              let index = saved.plans.firstIndex(where: { $0.id == id }) else {
            alert("没有找到要删除的商品配置，请刷新 App 后重试。")
            return
        }
        let target = saved.plans[index]
        let confirmation = NSAlert()
        confirmation.messageText = "删除商品配置？"
        confirmation.informativeText = "将删除本 App 保存的「\(target.name)」配置，不会删除 Apple 购物袋内容，也不会影响账号。"
        confirmation.addButton(withTitle: "删除")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            var next = saved
            next.plans.remove(at: index)
            next.selectedID = next.plans.first?.id
            try store.write(next, "plans.json")
            saved = next
            refreshPresets()
            if let replacement = next.plans.first {
                apply(replacement)
            } else {
                plan = nil; catalog = nil; variant = nil; latestActions = []
                specs.arrangedSubviews.forEach { specs.removeArrangedSubview($0); $0.removeFromSuperview() }
                options = []; autoSubmit.state = .off; maxTotal.doubleValue = 0; accountConfirmed.state = .off; readyConfirmed = false
                workflowPlanSelected = false; workflowProductLocked = false; workflowCompleted = false; updateWorkflowStatus()
                name.stringValue = "我的购买计划"
                updatePreview(); updateSteps()
            }
            log("已删除商品配置：\(target.name) · \(target.variant.partNumber)")
        } catch {
            alert("删除失败：\(error.localizedDescription)")
        }
    }
    func apply(_ p: ProductPlan) {
        plan = p; catalog = nil; variant = p.variant; latestActions = defaultActions(); source.stringValue = p.source; name.stringValue = p.name
        autoSubmit.state = .off
        updateSchedulePreview()
        specs.arrangedSubviews.forEach { specs.removeArrangedSubview($0); $0.removeFromSuperview() }; options = []
        accountConfirmed.state = .off; readyConfirmed = false; workflowPlanSelected = true; workflowProductLocked = false; workflowCompleted = false; updatePreview(); updateSteps(); updateWorkflowStatus()
    }
    @objc func exportPlan() {
        guard mutable() else { return }
        do { let p = try makeProductPlan(); let panel = NSSavePanel(); panel.nameFieldStringValue = "购买计划.json"
            if panel.runModal() == .OK, let url = panel.url { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]; e.dateEncodingStrategy = .iso8601; try e.encode(p).write(to:url,options:.atomic) }
        } catch { alert(error.localizedDescription) }
    }
    @objc func importPlan() {
        guard mutable() else { return }; let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; var p = try d.decode(ProductPlan.self,from:Data(contentsOf:url)); p.id = UUID().uuidString
                try p.validate()
                apply(p); log("商品配置已导入；托管时间使用当前界面设置。")
            } catch { alert(error.localizedDescription) }
        }
    }
    func accountFactsScript() -> String {
        """
        (() => {
          const visible = e => !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const text = (document.body?.innerText || '').replace(/\\s+/g, ' ').trim();
          const controls = [...document.querySelectorAll('a,button,[role=button]')]
            .filter(visible)
            .map(e => (e.innerText || e.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim())
            .filter(Boolean);
          const loggedIn = controls.some(v => /^(退出登录|退出账户|退出|Sign Out|Account Settings)$/i.test(v))
            || [...document.querySelectorAll('[data-autom*="signout" i],[data-autom*="account-name" i],[aria-label*="退出" i]')].some(visible);
          const loginRequired = /\\/shop\\/(signin|login)(\\/|$)/i.test(location.pathname)
            || [...document.querySelectorAll('input[type=password]')].some(visible)
            || controls.some(v => /^(登录|登入|Sign In|Log In)$/i.test(v));
          const challenge = /验证你的身份|验证您的身份|输入验证码|安全验证|verify your identity/i.test(text);
          return {loggedIn, loginRequired, challenge, href: location.href, title: document.title};
        })()
        """
    }
    func setManagedBrowserVisual(_ title: String, color: NSColor) {
        managedBrowserButton?.title = title
        managedBrowserButton?.contentTintColor = color
    }
    func applyManagedAccountFacts(_ facts: [String: Any]) {
        guard run == nil else { return }
        let loggedIn = facts["loggedIn"] as? Bool == true
        let loginRequired = facts["loginRequired"] as? Bool == true
        let challenge = facts["challenge"] as? Bool == true
        let href = facts["href"] as? String ?? ""
        let accountContext = href.contains("/shop/account/") || href.contains("/shop/signin") || href.contains("/shop/login")

        if loggedIn {
            workflowAccountReady = true
            setManagedBrowserVisual("专用浏览器已连接", color: .systemGreen)
            setAccountStatus("账号：已登录 · 自动监控中")
        } else if challenge {
            workflowAccountReady = false
            setManagedBrowserVisual("等待完成验证", color: .systemOrange)
            setAccountStatus("账号：需要完成 Apple 身份验证")
        } else if loginRequired {
            workflowAccountReady = false
            setManagedBrowserVisual("等待账号登录", color: .systemOrange)
            setAccountStatus("账号：等待在专用浏览器完成登录")
        } else if accountContext {
            setManagedBrowserVisual("账号检查中…", color: .systemOrange)
            setAccountStatus(workflowAccountReady ? "账号：已登录 · 自动监控中" : "账号：正在识别登录状态…")
        } else if workflowAccountReady {
            // Do not navigate away from the product page just to inspect the
            // account. Keep the last confirmed session while the browser is
            // doing product work.
            setManagedBrowserVisual("专用浏览器已连接", color: .systemGreen)
            setAccountStatus("账号：已登录 · 当前页面不影响会话监控")
        } else {
            setManagedBrowserVisual("等待打开账号页", color: .systemOrange)
            setAccountStatus("账号：当前页面无法确认登录，请在专用浏览器打开账号页")
        }
        accountCheckButton?.isEnabled = true
        updateWorkflowStatus()
    }
    func startManagedAccountMonitor() {
        managedAccountMonitor?.cancel()
        managedAccountMonitor = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let browser = self.browser, browser.isConnected else {
                    self.setManagedBrowserVisual("浏览器连接断开", color: .systemRed)
                    self.workflowAccountReady = false
                    self.setWindowStatus("浏览器窗口：此前已打开，当前无法核验")
                    let reason = browser?.lastDisconnectReason ?? "原因未记录"
                    self.setControlStatus("控制连接：已断开 · \(reason)")
                    self.setBrowserStatus("浏览器：控制连接已断开 · \(reason)")
                    self.setAccountStatus("账号：控制连接已断开，暂无法确认登录")
                    self.updateWorkflowStatus()
                    return
                }
                do {
                    let facts = try await browser.evaluate(self.accountFactsScript()) as? [String: Any] ?? [:]
                    self.applyManagedAccountFacts(facts)
                } catch is CancellationError {
                    return
                } catch {
                    self.setManagedBrowserVisual("账号检查失败", color: .systemRed)
                    self.workflowAccountReady = false
                    self.updateWorkflowStatus()
                    self.setAccountStatus("账号：自动检查失败，暂无法确认登录 · \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    @objc func startManagedBrowser() {
        guard run == nil, manualBrowserOperations == 0 else { return }
        manualBrowserOperations += 1
        managedBrowserButton.isEnabled = false
        setManagedBrowserVisual("连接专用浏览器…", color: .systemOrange)
        accountCheckButton.isEnabled = false
        setWindowStatus("浏览器窗口：正在启动或接管…")
        setControlStatus("控制连接：正在建立…")
        setAccountStatus("账号：浏览器启动后自动检查")
        setBrowserStatus("浏览器：正在查找已有连接或启动专用 Edge/Chrome…")
        managedBrowserStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.manualBrowserOperations -= 1
                self.managedBrowserStartTask = nil
            }
            do {
                let accountURL = URL(string: "https://www.apple.com.cn/shop/account/home")!
                let alreadyConnected = self.browser?.isConnected == true
                let initialInfo = try await self.ensureManagedBrowser(initialURL: accountURL)
                let info = try await self.browser?.ensureManagedAccountPage(accountURL) ?? initialInfo
                try? await self.browser?.bringToFront()
                if !alreadyConnected { self.workflowAccountReady = false }
                self.managedBrowserButton.isEnabled = true
                self.accountCheckButton.isEnabled = true
                self.setManagedBrowserVisual(self.workflowAccountReady ? "专用浏览器已连接" : "等待账号登录", color: self.workflowAccountReady ? .systemGreen : .systemOrange)
                let accountPage = isManagedAccountPage(info.url)
                self.setWindowStatus("浏览器窗口：已打开 · \(info.browserName)")
                self.setControlStatus("控制连接：正常 · 端口 \(info.port)")
                self.setBrowserStatus("浏览器：已连接 · \(accountPage ? "账号页面已打开" : "当前页面不是账号页") · \(info.browserName) · 端口 \(info.port)")
                self.setAccountStatus(self.workflowAccountReady ? "账号：已登录 · 自动监控中" : "账号：自动检查中\(accountPage ? "，请在专用浏览器完成登录" : "；当前页面尚未确认登录")")
                self.startManagedAccountMonitor()
                let mode = self.browser?.attachedToExisting == true ? "已接管已有实例" : "已启动新实例"
                self.log("专用浏览器已连接：\(info.browserName)，\(mode)，\(accountPage ? "账号页面已打开" : "当前页面不是账号准备页")；账号状态开始自动检查")
            } catch is CancellationError {
                return
            } catch {
                self.managedBrowserButton.isEnabled = true
                self.accountCheckButton.isEnabled = true
                self.setWindowStatus("浏览器窗口：未确认，可能仍开着")
                self.setControlStatus("控制连接：建立失败 · \(error.localizedDescription)")
                self.setManagedBrowserVisual("连接失败，点击重试", color: .systemRed)
                self.setBrowserStatus("浏览器：启动/连接失败 · \(error.localizedDescription)")
                self.setAccountStatus("账号：控制连接未建立，暂无法确认登录")
            }
        }
    }
    @objc func openManagedProduct() {
        guard run == nil, manualBrowserOperations == 0 else { return }
        guard let variant, let url = URL(string: variant.url), officialProductURL(variant.url) else {
            alert("请先读取官方商品规格并选择完整配置，再打开专用商品页。")
            return
        }
        setBrowserStatus("浏览器：正在打开已锁定商品页…")
        manualBrowserOperations += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.manualBrowserOperations -= 1 }
            do {
                if let browser = self.browser, browser.isConnected {
                    try await browser.navigate(url)
                } else {
                    _ = try await self.ensureManagedBrowser(initialURL: url)
                }
                try await self.browser?.waitForPage(url)
                let facts = try await self.browser?.prepareProductOptions()
                guard facts?["noTradeIn"] as? Bool == true, facts?["noAppleCare"] as? Bool == true else {
                    throw BrowserControllerError.protocolError(facts?["message"] as? String ?? "商品页尚未准备完成")
                }
                self.workflowProductLocked = true; self.updateWorkflowStatus()
                let available = facts?["addAvailable"] as? Bool == true
                self.setBrowserStatus("浏览器：商品页与选项已准备 · \(available ? "可加入购物袋" : "等待开售")")
                self.log("专用浏览器已准备商品页：\(variant.partNumber)；已确认\(PurchaseDefaults.noTradeInLabel)、\(PurchaseDefaults.noAppleCareLabel)；\(available ? "可加购" : "加购按钮尚不可用")")
            } catch {
                self.setBrowserStatus("浏览器：商品页打开失败 · \(error.localizedDescription)")
            }
        }
    }
    @objc func prepareManagedProduct() {
        guard run == nil, manualBrowserOperations == 0 else { return }
        guard let variant else {
            alert("请先从已保存计划或官方规格中选择完整商品配置。")
            return
        }
        guard let browser, browser.isConnected else {
            setBrowserStatus("浏览器：请先启动专用浏览器")
            return
        }
        setBrowserStatus("浏览器：正在选择不折抵和不加 AppleCare…")
        manualBrowserOperations += 1
        Task { @MainActor [weak self, weak browser] in
            guard let self, let browser else { return }
            defer { self.manualBrowserOperations -= 1 }
            do {
                let facts = try await browser.prepareProductOptions()
                guard facts["noTradeIn"] as? Bool == true, facts["noAppleCare"] as? Bool == true else { throw BrowserControllerError.protocolError(facts["message"] as? String ?? "商品页尚未准备完成") }
                self.workflowProductLocked = true; self.updateWorkflowStatus()
                self.setBrowserStatus("浏览器：商品选项已准备 · \(facts["addAvailable"] as? Bool == true ? "可加入购物袋" : "等待开售")")
                self.log("已准备专用商品页：\(variant.partNumber)；\(PurchaseDefaults.noTradeInLabel)、\(PurchaseDefaults.noAppleCareLabel)，未点击加袋")
            } catch {
                self.setBrowserStatus("浏览器：商品页准备失败 · \(error.localizedDescription)")
            }
        }
    }
    @objc func addManagedToBag() {
        guard run == nil else { return }
        guard let variant else {
            alert("请先选择完整商品配置。")
            return
        }
        guard let browser, browser.isConnected else {
            setBrowserStatus("浏览器：请先启动专用浏览器")
            return
        }
        setBrowserStatus("浏览器：正在准备并加入购物袋…")
        Task { @MainActor [weak self, weak browser] in
            guard let self, let browser else { return }
            do {
                let facts = try await browser.prepareProductPage()
                guard facts["state"] as? String == "ready" else { throw BrowserControllerError.protocolError(facts["message"] as? String ?? "商品页尚未准备完成") }
                let result = try await browser.click(selector: PurchaseDefaults.addToBagSelector)
                guard result["state"] as? String == "clicked" else { throw BrowserControllerError.protocolError(result["message"] as? String ?? "加入购物袋操作结果不明确") }
                self.workflowProductLocked = true; self.updateWorkflowStatus()
                self.setBrowserStatus("浏览器：已发出加入购物袋操作，请检查页面结果")
                self.log("已向专用浏览器发出加入购物袋操作：\(variant.partNumber)；未执行结账或支付")
            } catch {
                self.setBrowserStatus("浏览器：加入购物袋失败 · \(error.localizedDescription)")
            }
        }
    }
    @objc func checkManagedBrowser() {
        guard run == nil else { return }
        guard let browser else {
            setBrowserStatus("浏览器：未启动")
            return
        }
        Task { @MainActor [weak self, weak browser] in
            guard let self, let browser else { return }
            do {
                let href = try await browser.evaluate("location.href") as? String ?? "<未知页面>"
                self.setBrowserStatus(browser.isConnected ? "浏览器：连接正常 · \(href)" : "浏览器：连接已断开")
            } catch {
                self.setBrowserStatus("浏览器：连接检查失败 · \(error.localizedDescription)")
            }
        }
    }
    @objc func checkManagedAccount() {
        guard run == nil else { alert("托管执行中，请先停止后再检查账号。"); return }
        guard let browser, browser.isConnected else {
            workflowAccountReady = false; updateWorkflowStatus()
            setAccountStatus("账号：专用浏览器未连接，请先启动并登录")
            setBrowserStatus("浏览器：请先启动专用浏览器")
            return
        }
        setAccountStatus("账号：正在重新检查…")
        accountCheckButton.isEnabled = false
        Task { @MainActor [weak self, weak browser] in
            guard let self, let browser else { return }
            do {
                let facts = try await browser.evaluate(self.accountFactsScript()) as? [String: Any] ?? [:]
                self.applyManagedAccountFacts(facts)
                self.startManagedAccountMonitor()
            } catch {
                self.accountCheckButton.isEnabled = true
                self.workflowAccountReady = false
                self.updateWorkflowStatus()
                self.setAccountStatus("账号：专用浏览器会话检查失败 · \(error.localizedDescription)")
            }
        }
    }
    @objc func openManagedBag() {
        guard run == nil, manualBrowserOperations == 0 else { return }
        guard let browser, browser.isConnected else {
            setBrowserStatus("浏览器：请先启动专用浏览器")
            return
        }
        setBrowserStatus("浏览器：正在打开专用购物袋…")
        manualBrowserOperations += 1
        let bagURL = URL(string: "https://www.apple.com.cn/shop/bag")!
        Task { @MainActor [weak self, weak browser] in
            guard let self, let browser else { return }
            defer { self.manualBrowserOperations -= 1 }
            do {
                try await browser.navigate(bagURL)
                self.setBrowserStatus("浏览器：专用购物袋已打开")
                self.log("已在专用浏览器打开购物袋；未执行结账或支付")
            } catch {
                self.setBrowserStatus("浏览器：打开专用购物袋失败 · \(error.localizedDescription)")
            }
        }
    }
    func ensureManagedBrowser(initialURL: URL? = nil, attachExisting: Bool = true) async throws -> ManagedBrowserInfo {
        if let browser, browser.isConnected, let info = browser.info { return info }
        let controller = browser ?? BrowserController()
        controller.onDiagnostic = { [weak self] message in self?.log("[专用浏览器接管] \(message)") }
        browser = controller
        return try await controller.start(initialURL: initialURL, attachExisting: attachExisting)
    }
    func runBrowserSelfTest() async {
        let iterations = 1000
        do {
            setBrowserStatus("浏览器：正在运行本地控制压力测试（不访问 Apple）…")
            log("浏览器自测：开始启动专用浏览器")
            let html = """
            <!doctype html><meta charset="utf-8"><title>Apple Store Assistant Browser Self Test</title>
            <button id="fire" onclick="window.__asaClickCount=(window.__asaClickCount||0)+1">测试按钮</button>
            <input id="noTradeIn" data-autom="choose-noTradeIn" name="tradeupinline" value="noTradeIn" type="radio">
            <button id="addToBag" data-autom="add-to-cart" name="add-to-cart" disabled>加入购物袋</button>
            <span id="result">0</span>
            <script>
              window.__asaClickCount=0;
              document.getElementById('noTradeIn').addEventListener('click', () => {
                const care = document.createElement('input');
                care.type='radio'; care.name='applecare-options'; care.setAttribute('data-autom','noapplecare');
                document.body.appendChild(care);
                document.getElementById('addToBag').disabled=false;
              });
            </script>
            """
            let encoded = Data(html.utf8).base64EncodedString()
            let testURL = URL(string: "data:text/html;base64,\(encoded)")!
            let info = try await ensureManagedBrowser(initialURL: testURL, attachExisting: false)
            log("浏览器自测：已连接 \(info.browserName):\(info.port)，目标页面已锁定")
            try await browser?.waitForPage(testURL, maxWaitSeconds: 5)
            var ready: String?
            for _ in 0..<50 {
                ready = try await browser?.evaluate("document.readyState") as? String
                if ready == "complete" { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let currentURL = (try? await browser?.evaluate("location.href")) as? String ?? "<未知>"
            log("浏览器自测：页面 ready=\(ready ?? "<空>")，URL=\(currentURL)")
            guard ready == "complete" else { throw BrowserControllerError.protocolError("本地测试页没有完成加载：ready=\(ready ?? "<空>")，url=\(currentURL)") }

            let prepared = try await browser?.prepareProductPage(maxWaitSeconds: 2)
            guard prepared?["state"] as? String == "ready",
                  prepared?["noTradeIn"] as? Bool == true,
                  prepared?["noAppleCare"] as? Bool == true,
                  prepared?["addAvailable"] as? Bool == true else {
                throw BrowserControllerError.protocolError("依赖选项回归测试失败：\(prepared ?? [:])")
            }
            log("浏览器自测：已验证先选不折抵，再等待并选择 AppleCare，加入购物袋按钮已可用")

            var latencies: [Double] = []; latencies.reserveCapacity(iterations)
            var passed = true
            for index in 0..<iterations {
                let target = ProcessInfo.processInfo.systemUptime + 0.006
                while ProcessInfo.processInfo.systemUptime < target - 0.002 {
                    try await Task.sleep(nanoseconds: 500_000)
                }
                while ProcessInfo.processInfo.systemUptime < target { await Task.yield() }
                let issued = ProcessInfo.processInfo.systemUptime
                let result = try await browser?.click(selector: "#fire")
                let finished = ProcessInfo.processInfo.systemUptime
                latencies.append((finished - issued) * 1000)
                if result?["state"] as? String != "clicked" { passed = false; break }
                if index == 0 || (index + 1) % 100 == 0 { log("浏览器自测：已完成 \(index + 1)/\(iterations) 次点击") }
            }
            let count = (try await browser?.evaluate("window.__asaClickCount || 0") as? NSNumber)?.intValue ?? -1
            let sorted = latencies.sorted()
            let result = BrowserSelfTestResult(
                iterations: iterations,
                passed: passed && count == iterations,
                p50MS: quantile(sorted, 0.50),
                p95MS: quantile(sorted, 0.95),
                p99MS: quantile(sorted, 0.99),
                maxMS: sorted.last ?? 0,
                finalCount: count,
                browser: info.browserName,
                port: info.port
            )
            try store.write(result, "browser-self-test.json")
            setBrowserStatus(String(format: "浏览器测试：%@ · 1000 次 · P50 %.1fms · P95 %.1fms · P99 %.1fms · 计数 %d", result.passed ? "通过" : "失败", result.p50MS, result.p95MS, result.p99MS, result.finalCount))
            log("浏览器本地控制测试：\(result.passed ? "通过" : "失败")，\(result.iterations) 次，P50=\(String(format: "%.1f", result.p50MS))ms，P95=\(String(format: "%.1f", result.p95MS))ms，P99=\(String(format: "%.1f", result.p99MS))ms，最终点击计数=\(result.finalCount)")
        } catch {
            setBrowserStatus("浏览器测试：失败 · \(error.localizedDescription)")
            log("浏览器本地控制测试失败：\(error.localizedDescription)")
        }
        if CommandLine.arguments.contains("--browser-self-test") {
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }
    func quantile(_ values: [Double], _ probability: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, max(0, Int(Double(values.count - 1) * probability)))
        return values[index]
    }
    @objc func openAccount() {
        if accountWindow == nil {
            let w = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            w.title = "Apple 账号 · App 内官方页面"; w.isReleasedWhenClosed = false; w.delegate = self

            let host = NSView(frame: w.contentRect(forFrameRect: w.frame).insetBy(dx: 0, dy: 0))
            host.autoresizingMask = [.width, .height]

            let overlay = NSStackView()
            overlay.orientation = .vertical; overlay.alignment = .centerX; overlay.spacing = 10
            overlay.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
            overlay.layer?.cornerRadius = 10
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small
            spinner.isIndeterminate = true; spinner.startAnimation(nil)
            let status = NSTextField(wrappingLabelWithString: "正在加载 Apple 官方账号页…")
            status.alignment = .center; status.maximumNumberOfLines = 3
            let retry = NSButton(title: "重新开始登录", target: self, action: #selector(retryAccount))
            retry.isHidden = true
            overlay.addArrangedSubview(spinner); overlay.addArrangedSubview(status); overlay.addArrangedSubview(retry)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                overlay.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                overlay.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
                overlay.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -24)
            ])
            accountHost = host; accountOverlay = overlay; accountSpinner = spinner; accountStatus = status; accountRetry = retry
            w.contentView = host; accountWindow = w
        }
        mountAccountWeb()
        accountWindow?.center(); accountWindow?.makeKeyAndOrderFront(nil)
        if accountWeb.url == nil || accountWeb.url?.scheme == "about" {
            loadAccountPage(URL(string:"https://www.apple.com.cn/shop/account/home")!)
        } else if accountWeb.isLoading {
            showAccountOverlay("Apple 官方账号页仍在加载…", retry: false)
        } else {
            accountOverlay?.isHidden = true
        }
    }
    func mountAccountWeb() {
        guard !accountMode, let host = accountHost else { return }
        rightBrowserStack?.removeArrangedSubview(web)
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(web)
        accountWebConstraints = [
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ]
        NSLayoutConstraint.activate(accountWebConstraints)
        accountMode = true
    }
    func unmountAccountWeb() {
        guard accountMode else { return }
        NSLayoutConstraint.deactivate(accountWebConstraints); accountWebConstraints = []
        web.removeFromSuperview()
        rightBrowserStack?.insertArrangedSubview(web, at: 1)
        accountMode = false
        pageURL.stringValue = "\(web.url?.host ?? "欢迎")\(web.url?.path ?? "")"
    }
    func loadAccountPage(_ url: URL) {
        accountLoadTimer?.invalidate()
        accountHealthTimer?.invalidate()
        accountHealthStarted = Date()
        showAccountOverlay("正在加载 Apple 官方账号页…", retry: false)
        accountWeb.load(URLRequest(url: url))
    }
    @objc func retryAccount() {
        let url = URL(string:"https://www.apple.com.cn/shop/account/home")!
        log("用户请求重新开始 Apple 账号登录")
        loadAccountPage(url)
    }
    func showAccountOverlay(_ message: String, retry: Bool) {
        accountStatus?.stringValue = message; accountRetry?.isHidden = !retry
        accountSpinner?.isHidden = retry; if retry { accountSpinner?.stopAnimation(nil) } else { accountSpinner?.startAnimation(nil) }
        accountOverlay?.isHidden = false
    }
    func safeURL(_ url: URL?) -> String {
        guard let url else { return "<无 URL>" }
        return "\(url.host ?? "")\(url.path.isEmpty ? "/" : url.path)"
    }
    func isAccountWeb(_ webView: WKWebView) -> Bool { accountMode && webView === web }
    func browserName(_ webView: WKWebView) -> String { isAccountWeb(webView) ? "账号页" : "购买页" }
    func logNavigation(_ event: String, webView: WKWebView, error: Error? = nil) {
        let suffix = error.map { "，错误码 \((($0 as NSError).code))：\($0.localizedDescription)" } ?? ""
        log("[\(browserName(webView))] \(event)：\(safeURL(webView.url))\(suffix)")
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "asaAccountNetwork", let body = message.body as? [String: Any] else { return }
        let kind = body["kind"] as? String ?? "request"
        let rawURL = body["url"] as? String ?? "<unknown>"
        let status = body["status"] as? Int ?? 0
        log("[账号网络] \(kind) \(safeURL(URL(string: rawURL))) 状态 \(status)")
        let path = URL(string: rawURL)?.path.lowercased() ?? ""
        let authenticationEndpoint = path.contains("/signin/") || path.contains("/login/") || path.contains("/authx")
        if status == 541 && authenticationEndpoint {
            showAccountOverlay("Apple 认证服务已完成，但 Apple Store 会话接收失败（541）。\n请重新开始登录；若仍失败，App 会保留诊断记录。", retry: true)
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                let names = cookies.filter { $0.domain.contains("apple.com") }.map(\.name).sorted().joined(separator: ",")
                Task { @MainActor in self?.log("[账号网络] 541 时 Apple Cookie 名称：\(names.isEmpty ? "<无>" : names)") }
            }
        } else if status == 541 {
            log("[账号网络] 541 属于业务接口，不按登录失败处理：\(safeURL(URL(string: rawURL)))")
        }
    }
    func isAllowedAppleHost(_ host: String, for webView: WKWebView) -> Bool {
        let h = host.lowercased()
        if h == "apple.com" || h.hasSuffix(".apple.com") || h == "apple.com.cn" || h.hasSuffix(".apple.com.cn") { return true }
        // Apple's account sign-in page may load its first-party auth UI from this
        // CDN domain. It is allowed only in the in-app account WebView.
        return isAccountWeb(webView) && (h == "cdn-apple.com" || h.hasSuffix(".cdn-apple.com"))
    }
    func monitorAccountPage() {
        guard accountWeb.url?.host?.hasSuffix("apple.com.cn") == true else { return }
        let script = """
        (() => {
          const visible = e => !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const password = [...document.querySelectorAll('input[type="password"]')].some(visible);
          const progress = [...document.querySelectorAll('[role="progressbar"],progress,[aria-busy="true"]')].some(visible);
          const text = (document.body?.innerText || '').replace(/\\s+/g, ' ').trim();
          return { password, progress, textLength: text.length, ready: document.readyState };
        })()
        """
        accountWeb.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                guard let self, error == nil, let facts = value as? [String: Any] else { return }
                let hasPassword = facts["password"] as? Bool == true
                let hasProgress = facts["progress"] as? Bool == true
                if hasPassword {
                    self.accountHealthStarted = Date()
                    self.accountOverlay?.isHidden = true
                    return
                }
                guard hasProgress, Date().timeIntervalSince(self.accountHealthStarted) >= 30 else { return }
                self.log("[账号页] 页面健康检查：无密码表单且进度指示器持续存在，页面可能卡在认证回调")
                self.showAccountOverlay("Apple 登录回调超过 30 秒未完成。\n请重新开始登录；若 Apple 要求验证码或 Touch ID，请在官方页面完成。", retry: true)
                self.accountHealthTimer?.invalidate(); self.accountHealthTimer = nil
            }
        }
    }
    @objc func checkAccount() {
        checkManagedAccount()
    }
    @objc func confirmAccount() {
        readyConfirmed = accountConfirmed.state == .on
        updateWorkflowStatus()
        if readyConfirmed { setAccountStatus("账号：用户已确认专用浏览器登录与付款准备（非银行授权验证）") }
    }
    @objc func openBag() { openManagedBag() }
    @objc func back() { if run == nil { web.goBack() } }
    @objc func reload() { if run == nil { web.reload() } }
    @objc func readActions() {
        guard mutable() else { return }
        js("StoreAssistant.choices()") { [weak self] value,error in
            guard let s = self else { return }; guard error == nil, let rows = value as? [[String:Any]] else { s.alert("无法读取页面按钮"); return }
            s.actionChoices.removeAllItems()
            for r in rows { if let label = r["label"] as? String { s.actionChoices.addItem(withTitle:label); s.actionChoices.lastItem?.representedObject = r } }
            s.log("读取了 \(rows.count) 个可见按钮。采集只保存按钮定位，不会点击。")
        }
    }
    @objc func toggleAdvanced() { advanced.isHidden.toggle() }
    func record(_ kind: String) {
        guard mutable(), let d = actionChoices.selectedItem?.representedObject as? [String:String] else { return }
        let a = Action(kind:kind,selector:d["selector"] ?? "",label:d["label"] ?? "",host:d["host"] ?? "",path:d["path"] ?? "")
        let submitWords = "提交|下单|付款|支付|place.*order|pay|complete.*purchase"
        if kind == "continue", a.label.range(of:submitWords,options:[.regularExpression,.caseInsensitive]) != nil { alert("这是提交或支付按钮，请使用「设为最终提交」。"); return }
        if latestActions.isEmpty { latestActions = defaultActions() }
        latestActions.removeAll(where:{$0.kind == "submit"}); latestActions.append(a); updateSteps(); log("已采集步骤：\(a.label)，未点击")
    }
    @objc func addContinue() { record("continue") }
    @objc func addSubmit() { record("submit") }
    @objc func resetActions() { guard mutable() else { return }; latestActions = defaultActions(); updateSteps() }
    func updateSteps() { let actions = latestActions.isEmpty ? defaultActions() : latestActions; stepsLabel.stringValue = actions.enumerated().map { "\($0.offset+1). \($0.element.label)" }.joined(separator:" → ") }
    @objc func arm() {
        guard run == nil else { return }
        if CommandLine.arguments.contains("--preview") { startDemo(); return }
        do {
            let p = try makePlan()
            guard manualBrowserOperations == 0 else { throw AppError("辅助操作正在完成，请稍后点击托管") }
            if pickupSettings.autoCompleteCheckout && CheckoutPaymentMethod(rawValue:pickupSettings.paymentMethod) == nil {
                throw AppError("请先在“取货与结账资料 → 付款与下单”中选择支付宝或微信支付。")
            }
            if var old = try store.read("run.json", as: RunRecord.self), old.pendingAction != nil || !old.attempted.isEmpty,
               !["handoff", "complete", "reviewed"].contains(old.state) {
                let warning = NSAlert()
                warning.messageText = "上一任务的购买结果尚未确认"
                warning.informativeText = "请先在官网核对购物袋和订单。只有确认不会重复购买后，才开始新任务。"
                warning.addButton(withTitle:"先检查官网")
                warning.addButton(withTitle:"我已核对，开始新任务")
                guard warning.runModal() == .alertSecondButtonReturn else { showManagedBrowser(); return }
                old.state = "reviewed"; try store.write(old,"run.json")
            }
            try persist(ProductPlan(p))
            run = RunRecord(plan:p, pickupSettings:pickupSettings); workflowCompleted = false; updateWorkflowStatus(); try checkpoint(); generation = UUID(); isDemo = false; begin(p)
        } catch { run = nil; alert(error.localizedDescription) }
    }
    func begin(_ p: Plan) {
        busy = false; monotonicTarget = ProcessInfo.processInfo.systemUptime + p.releaseAt.timeIntervalSinceNow
        if let activeRun = run {
            do {
                taskRecording = try TaskRecording(root: store.root, run: activeRun)
                recordTask("armed", ["mode": isDemo ? "demo" : "managed", "prepareSeconds": String(p.prepareSeconds), "quietSeconds": String(p.quietSeconds), "executionSeconds": String(p.executionSeconds)])
            } catch {
                taskRecording = nil
                log("任务录制未启动，购买流程不受影响：\(error.localizedDescription)")
            }
        }
        setEditing(false); stopButton.isEnabled = true; resumeButton.isEnabled = false
        updateWorkflowStatus()
        activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"等待用户安排的 Apple 购买任务")
        log("已托管：\(p.name) · \(p.variant.partNumber)，\(p.releaseAt.formatted())；固定数量 1")
        timer?.invalidate(); timer = Timer(timeInterval:0.1,target:self,selector:#selector(tick),userInfo:nil,repeats:true); RunLoop.main.add(timer!,forMode:.common)
        startAutomation(p)
    }
    func checkpoint() throws { if var r = run { r.updatedAt = Date(); try store.write(r,isDemo ? "demo-run.json" : "run.json"); run = r } }
    func startAutomation(_ p: Plan) {
        managedAccountMonitor?.cancel(); managedAccountMonitor = nil
        automationTask?.cancel()
        workflowAccountReady = false; workflowProductLocked = false; workflowCompleted = false
        automationPhase = .connecting
        let token = generation
        let driver: any AutomationBrowser
        if isDemo { driver = DemoAutomationBrowser() }
        else {
            let controller = browser ?? BrowserController()
            controller.onDiagnostic = { [weak self] message in self?.log("[浏览器] \(message)") }
            browser = controller
            driver = DedicatedAutomationBrowser(controller: controller, plan: p)
        }
        let engine = ManagedAutomation(browser: driver, plan: p, target: monotonicTarget,
            persist: { [weak self] checkpoint in
                guard let self, self.generation == token, self.run != nil else { throw CancellationError() }
                self.run?.automationPhase = checkpoint.phase.rawValue
                self.run?.pendingAction = checkpoint.pending
                self.run?.attempted = checkpoint.pending == nil ? [] : [checkpoint.pending == "checkout" ? 2 : 1]
                try self.checkpoint()
            }, event: { [weak self] phase, message, details in
                guard let self, self.generation == token, self.run != nil else { return }
                self.automationPhase = phase
                self.run?.automationPhase = phase.rawValue
                self.state.stringValue = message
                self.state.textColor = phase == .attention || phase == .expired ? .systemOrange : .systemBlue
                if phase == .login { self.workflowAccountReady = false; self.session.stringValue = message }
                if details["account"] == "ready" { self.workflowAccountReady = true; self.session.stringValue = "账号：登录已确认；配送和付款信息在官网结账时核对" }
                if phase == .preparing { self.workflowProductLocked = false }
                if details["product"] == "locked" { self.workflowProductLocked = true }
                if details["event"] == "product_observed", details["purchaseIssued"] == "false" {
                    self.workflowProductLocked = details["configurationReady"] == "true"
                }
                if [.purchasing, .verifyingBag, .checkingOut, .awaitingCheckout].contains(phase) {
                    if self.run?.firedAt == nil {
                        self.run?.firedAt = Date()
                        self.run?.triggerDelayMS = max(0,(ProcessInfo.processInfo.systemUptime - self.monotonicTarget)*1000)
                    }
                    self.run?.state = "executing"
                    self.run?.step = phase == .checkingOut || phase == .awaitingCheckout ? 2 : 1
                }
                self.recordTask(details["event"] ?? ("automation_" + phase.rawValue), details)
                if details["event"] != "product_observed" { self.log(message) }
                self.updateWorkflowStatus()
            })
        automation = engine
        updateWorkflowStatus()
        automationTask = Task { @MainActor [weak self] in
            let result = await engine.run()
            guard let self, self.generation == token, self.run != nil else { return }
            if result == .handoff {
                self.automation = nil
                self.timer?.invalidate()
                self.timer = nil
            }
            var message = self.state.stringValue
            var completionState = result == .handoff ? "handoff" : (result == .cancelled ? "cancelled" : (result == .expired ? "expired" : "manual"))
            if result == .handoff, let pickup = self.run?.pickupSettings {
                message = await self.completeCheckoutAtHandoff(pickup)
                completionState = self.checkoutHandoffRunState
            }
            guard self.generation == token, self.run != nil else { return }
            self.finish(message, state: completionState)
            NSSound.beep()
            if result == .handoff { self.showManagedBrowser() }
        }
    }

    func completeCheckoutAtHandoff(_ settings: PickupSettings) async -> String {
        checkoutHandoffRunState = "manual"
        guard let browser, browser.isConnected else {
            return "已到 Apple 结账页，但专用浏览器连接已断开；请在官网手动核对取货联系人和发票。"
        }
        var pickupMessage = ""
        if settings.autoSelectPreferredStore {
            pickupMessage = await autoSelectPickupAtHandoff(settings)
            guard pickupMessage.hasPrefix("已选择首选门店并进入取货联系人页面") ||
                  pickupMessage.hasPrefix("已回退选择第一个可取货门店") ||
                  pickupMessage == "已到取货联系人页面。" else {
                return pickupMessage
            }
        }
        guard settings.autoCompleteCheckout else {
            checkoutHandoffRunState = "handoff"
            return pickupMessage.isEmpty ? "已到结账页；自动填写和继续已关闭，请在官网选择门店并填写资料。" : pickupMessage
        }
        guard checkoutProfileLoadError == nil else {
            return "已到取货联系人页，但 macOS 钥匙串资料不可用；程序没有读取普通文件中的替代资料。请手动填写。"
        }
        guard !checkoutProfileIsDirty() else {
            return "结账预设有未保存修改；程序没有填写或继续。请先保存到钥匙串，再开始托管。"
        }
        let profile = checkoutProfile
        guard profile.contactNameConfirmed else {
            return "未确认取货姓名与购买人及证件一致；程序没有自动填写。请在取货联系人卡片确认后保存。"
        }
        guard !profile.surname.isEmpty, !profile.givenName.isEmpty,
              !profile.email.isEmpty, !profile.phone.isEmpty else {
            return "取货联系人资料不完整；需要姓、名、邮箱和手机。"
        }
        guard profile.email.range(of:"^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$",options:.regularExpression) != nil else {
            return "联系人邮箱格式不正确；程序没有填写或继续。"
        }
        guard let invoiceType = AppleInvoiceType(rawValue:settings.defaultInvoiceType) else {
            return "默认发票类型无效；程序没有填写或继续。"
        }
        switch invoiceType {
        case .personal:
            break
        case .company:
            guard !profile.companyName.isEmpty,
                  profile.companyHasNoTaxpayerID || !profile.companyTaxpayerID.isEmpty else {
                return "公司/其他发票预设不完整；请填写公司名称和税号，或明确勾选“我司无纳税人识别号”。"
            }
        case .vatSpecial:
            guard !profile.vatCompanyName.isEmpty, !profile.vatTaxpayerID.isEmpty, !profile.vatBankAccount.isEmpty else {
                return "增值税专用发票预设不完整；请填写公司名称、纳税人识别号和银行账号。"
            }
            guard profile.vatTermsAuthorized else {
                return "尚未授权自动勾选专票条款；请先阅读 Apple 发票条款，并在发票预设卡片中明确授权。"
            }
        }
        let payloadObject: [String: Any] = [
            "invoiceType": invoiceType.rawValue,
            "surname": profile.surname,
            "givenName": profile.givenName,
            "email": profile.email,
            "phone": profile.phone,
            "idLastFour": profile.nationalIDLastFour,
            "personalHeader": profile.personalInvoiceHeader,
            "companyName": profile.companyName,
            "companyTaxpayerID": profile.companyTaxpayerID,
            "companyHasNoTaxpayerID": profile.companyHasNoTaxpayerID,
            "vatCompanyName": profile.vatCompanyName,
            "vatTaxpayerID": profile.vatTaxpayerID,
            "vatBankName": profile.vatBankName,
            "vatBankAccount": profile.vatBankAccount,
            "vatTermsAuthorized": profile.vatTermsAuthorized
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject:payloadObject),
              let payload = String(data:encoded,encoding:.utf8) else {
            return "无法准备结账资料；未改动 Apple 页面。"
        }
        state.stringValue = "正在填写取货联系人与发票资料…"
        let expression = """
        (() => {
          const p = \(payload);
          const norm = value => String(value || '').replace(/[\\u200b-\\u200f\\u2060]/g,'').replace(/\\s+/g,' ').trim();
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const step = new URL(location.href).searchParams.get('_s') || '';
          if (!/^(www|secure\\d*\\.www)\\.apple\\.com\\.cn$/i.test(location.hostname) || !/^\\/shop\\/checkout(?:\\/|$)/i.test(location.pathname))
            return {state:'wrong_page'};
          if (/billing|payment|review|orderreview/i.test(step)) return {state:'payment_ready'};
          const allFields = [...document.querySelectorAll('input')];
          const contactNames = ['lastName','firstName','emailAddress','fullDaytimePhone'];
          const contactLabels = {lastName:'姓氏',firstName:'名字',emailAddress:'邮箱',fullDaytimePhone:'手机号'};
          const contactFields = contactNames.map(name => allFields.filter(e => e.name === name && visible(e)));
          const missingContactFields = contactNames.filter((name,index) => contactFields[index].length === 0)
            .map(name => contactLabels[name] || name);
          if (missingContactFields.length) return {state:'contact_waiting',step,missingFields:missingContactFields};
          if (contactFields.some(matches => matches.length !== 1)) return {state:'field_ambiguous'};
          const radioLabel = p.invoiceType === 'personal' ? '电子发票 - 个人' :
            p.invoiceType === 'company' ? '电子发票 - 公司/其他' : '电子发票 - 增值税专用发票';
          const radios = allFields.filter(e => e.type === 'radio' && visible(e));
          const matchingRadios = radios.filter(e => norm([...(e.labels || [])].map(label => label.innerText).join(' ')) === radioLabel);
          if (matchingRadios.length !== 1) return {state:matchingRadios.length ? 'field_ambiguous' : 'invoice_option_missing'};
          const radio = matchingRadios[0];
          if (radio.disabled || radio.getAttribute('aria-disabled') === 'true') return {state:'invoice_option_disabled'};
          if (!radio.checked) {
            if (window.__asaInvoiceSelectionAttempted === p.invoiceType) return {state:'invoice_selection_waiting'};
            window.__asaInvoiceSelectionAttempted = p.invoiceType;
            (radio.labels?.[0] || radio).click();
            return {state:'invoice_type_selected'};
          }
          const field = name => {
            const matches = allFields.filter(e => e.name === name && visible(e));
            return matches.length === 1 ? matches[0] : null;
          };
          const setField = (name,value,required=true) => {
            const e = field(name);
            if (!e) return 'missing';
            if (e.disabled || e.readOnly) return 'disabled';
            if (!value) return required ? 'empty' : 'ok';
            if (norm(e.value) !== norm(value)) {
              const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.set;
              if (setter) setter.call(e,value); else e.value = value;
              e.dispatchEvent(new Event('input',{bubbles:true}));
              e.dispatchEvent(new Event('change',{bubbles:true}));
              e.dispatchEvent(new Event('blur',{bubbles:true}));
            }
            return norm(e.value) === norm(value) && e.checkValidity() ? 'ok' : 'invalid';
          };
          const setCheck = (matches,desired) => {
            const visibleMatches = matches.filter(visible);
            if (!visibleMatches.length) return 'missing';
            if (visibleMatches.length !== 1) return 'ambiguous';
            const e=visibleMatches[0];
            if (!!e.checked !== !!desired) {
              e.click();
              if (!!e.checked !== !!desired) {
                e.checked=!!desired;
                e.dispatchEvent(new Event('input',{bubbles:true}));
                e.dispatchEvent(new Event('change',{bubbles:true}));
              }
            }
            return !!e.checked === !!desired ? 'ok' : 'invalid';
          };
          for (const [name,value] of [['lastName',p.surname],['firstName',p.givenName],['emailAddress',p.email],['fullDaytimePhone',p.phone]]) {
            const result=setField(name,value,true);
            if (result !== 'ok') return {state:'contact_field_'+result,field:name};
          }
          const idFields = allFields.filter(e => e.name === 'nationalIdSelf' && visible(e));
          if (idFields.length > 1) return {state:'field_ambiguous'};
          if (idFields.length === 1) {
            const idField = idFields[0];
            if (p.idLastFour) {
              const result = setField('nationalIdSelf',p.idLastFour,true);
              if (result !== 'ok') return {state:'contact_field_'+result,field:'nationalIdSelf'};
            } else if (idField.required || idField.getAttribute('aria-required') === 'true') {
              return {state:'contact_field_empty',field:'nationalIdSelf'};
            }
          }
          const invoiceResult = (() => {
            if (p.invoiceType === 'personal') {
              const title=field('invoiceHeader');
              if (p.personalHeader && !title) return 'loading';
              if (title && p.personalHeader) return setField('invoiceHeader',p.personalHeader,false);
              return 'ok';
            }
            if (p.invoiceType === 'company') {
              const nameResult=setField('companyName',p.companyName,true);
              if (nameResult === 'missing') return 'loading';
              if (nameResult !== 'ok') return nameResult;
              const noTax=allFields.filter(e => e.type==='checkbox' && (e.name==='noTaxIdCheck' || norm([...(e.labels||[])].map(label=>label.innerText).join(' ')).includes('我司无纳税人识别号')));
              if (p.companyHasNoTaxpayerID) {
                if (!field('taxPayerId') && noTax.filter(visible).length===0) return 'loading';
                const noTaxResult=setCheck(noTax,true);
                if (noTaxResult!=='ok') return 'no_tax_checkbox_'+noTaxResult;
                const tax=field('taxPayerId');
                if (tax) {
                  if (!tax.disabled && !tax.readOnly && tax.value) {
                    const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.set;
                    if (setter) setter.call(tax,''); else tax.value='';
                    tax.dispatchEvent(new Event('input',{bubbles:true}));
                    tax.dispatchEvent(new Event('change',{bubbles:true}));
                    if (norm(tax.value)) return 'invalid';
                  }
                }
                return 'ok';
              }
              const taxResult=setField('taxPayerId',p.companyTaxpayerID,true);
              if (taxResult==='missing') return 'loading';
              if (taxResult!=='ok') return taxResult;
              if (noTax.filter(visible).length) {
                const noTaxResult=setCheck(noTax,false);
                if (noTaxResult!=='ok') return 'no_tax_checkbox_'+noTaxResult;
              }
              return 'ok';
            }
            const nameResult=setField('companyName',p.vatCompanyName,true);
            if (nameResult==='missing') return 'loading';
            if (nameResult!=='ok') return nameResult;
            const taxResult=setField('taxPayerId',p.vatTaxpayerID,true);
            if (taxResult==='missing') return 'loading';
            if (taxResult!=='ok') return taxResult;
            const bankName=field('bankAccountName');
            const bankAccount=field('bankAccountNumber');
            if (p.vatBankName && !bankName) return 'loading';
            if (p.vatBankAccount && !bankAccount) return 'loading';
            if (p.vatBankName && setField('bankAccountName',p.vatBankName,false)!=='ok') return 'invalid';
            if (setField('bankAccountNumber',p.vatBankAccount,true)!=='ok') return 'invalid';
            const terms=allFields.filter(e => e.type==='checkbox' && /acceptTermsCheck/.test(e.id));
            if (!p.vatTermsAuthorized) return 'terms_authorization_required';
            const termsResult=setCheck(terms,true);
            if (termsResult!=='ok') return 'terms_checkbox_'+termsResult;
            return 'ok';
          })();
          if (invoiceResult==='loading') return {state:'invoice_fields_loading'};
          if (invoiceResult==='terms_authorization_required') return {state:'terms_authorization_required'};
          if (invoiceResult!=='ok') return {state:'invoice_field_'+invoiceResult};
          const buttons=[...document.querySelectorAll('button,[role="button"],input[type="submit"]')].filter(visible);
          const continues=buttons.filter(e => norm(e.innerText || e.value || e.getAttribute('aria-label'))==='继续选择付款方式');
          if (continues.length===0) return {state:'continue_button_missing',step};
          if (continues.length>1) return {state:'continue_button_ambiguous',step};
          const next=continues[0];
          if (next.disabled || next.getAttribute('aria-disabled')==='true') return {state:'continue_disabled',step};
          if (window.__asaCheckoutContinueAttempted) return {state:'continue_pending'};
          window.__asaCheckoutContinueAttempted=true;
          next.click();
          return {state:'continue_clicked'};
        })()
        """
        let waitForCheckoutChangeExpression = """
        (() => new Promise(resolve => {
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const norm = value => String(value || '').replace(/[\\u200b-\\u200f\\u2060]/g,'').replace(/\\s+/g,' ').trim();
          const ready = () => {
            const hostOk = /^(www|secure\\d*\\.www)\\.apple\\.com\\.cn$/i.test(location.hostname);
            if (!hostOk || !/^\\/shop\\/checkout(?:\\/|$)/i.test(location.pathname)) return true;
            const step = new URL(location.href).searchParams.get('_s') || '';
            if (/^Billing-init$/i.test(step)) return true;
            const buttons = [...document.querySelectorAll('button,[role="button"],input[type="submit"]')].filter(visible)
              .filter(e => norm(e.innerText || e.value || e.getAttribute('aria-label')) === '继续选择付款方式');
            if (buttons.length > 1) return true;
            if (window.__asaCheckoutContinueAttempted) return false;
            return buttons.length === 1 && !buttons[0].disabled && buttons[0].getAttribute('aria-disabled') !== 'true';
          };
          let settled = false;
          let observer;
          const finish = () => {
            if (settled) return;
            settled = true;
            observer?.disconnect();
            clearTimeout(timer);
            resolve(true);
          };
          const timer = setTimeout(finish, 250);
          observer = new MutationObserver(() => { if (ready()) finish(); });
          observer.observe(document.documentElement || document, {subtree:true,childList:true,attributes:true,characterData:true,attributeFilter:['disabled','aria-disabled','class','href']});
          if (ready()) finish();
        }))()
        """
        // Keep the checkout handoff alive across asynchronous Apple page
        // transitions. This checkpoint prevents a restart from silently
        // treating an in-flight checkout as a fresh purchase opportunity.
        run?.state = "checkout_transition_pending"
        run?.automationPhase = "checkout_transition"
        run?.pendingAction = "checkout_transition"
        try? checkpoint()
        recordTask("checkout_transition_monitor_started")
        let observationStarted = Date()
        var lastWaitNotice: Date?
        var lastReconnectNotice: Date?
        var reconnectFailures = 0
        var consecutiveReadFailures = 0
        var continueWasIssued = false
        while !Task.isCancelled {
            if !browser.isConnected {
                state.stringValue = "专用浏览器连接中断，正在重新连接并保留当前结账状态…"
                do {
                    try await browser.reconnectToTarget()
                    reconnectFailures = 0
                    consecutiveReadFailures = 0
                    lastReconnectNotice = nil
                    log("已重新连接原专用 Edge 页面，正在核对当前结账阶段；不会重复点击")
                } catch {
                    reconnectFailures += 1
                    let now = Date()
                    if lastReconnectNotice == nil || now.timeIntervalSince(lastReconnectNotice!) >= 15 {
                        log("专用 Edge 暂不可读取，继续尝试连接原页面；结账任务仍保留：\(error.localizedDescription)")
                        lastReconnectNotice = now
                    }
                    let exponent = min(reconnectFailures, 4)
                    let delay = min(5.0, 0.25 * pow(2.0, Double(exponent)))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
            }
            do {
                try Task.checkCancellation()
                let facts = try await browser.evaluate(expression) as? [String: Any] ?? [:]
                consecutiveReadFailures = 0
                let observed = facts["state"] as? String ?? "unknown"
                if observed == "contact_waiting", Date().timeIntervalSince(observationStarted) >= 30 {
                    let step = facts["step"] as? String ?? "未知结账步骤"
                    let missingFields = facts["missingFields"] as? [String] ?? []
                    let missingLabel = missingFields.isEmpty ? "联系人字段状态无法确认" : "缺少字段：\(missingFields.joined(separator:", "))"
                    let message = "Apple 联系人页在 30 秒内未出现必需字段（\(step)，\(missingLabel)）；程序已停止自动填写，请检查专用浏览器。"
                    state.stringValue = message
                    log(message)
                    run?.state = "checkout_transition_pending"
                    run?.automationPhase = "checkout_transition"
                    run?.pendingAction = "checkout_transition"
                    try? checkpoint()
                    recordTask("checkout_contact_fields_missing", ["pageStep":step,"missingFields":missingFields.joined(separator:",")])
                    return message
                }
                let waitingStates: Set<String> = ["invoice_type_selected", "invoice_selection_waiting", "invoice_fields_loading", "contact_waiting", "continue_clicked", "continue_pending", "continue_button_missing", "continue_disabled"]
                if waitingStates.contains(observed), Date().timeIntervalSince(observationStarted) >= 10 {
                    let now = Date()
                    if lastWaitNotice == nil || now.timeIntervalSince(lastWaitNotice!) >= 15 {
                        let step = facts["step"] as? String ?? "未知结账步骤"
                        let missingFields = facts["missingFields"] as? [String] ?? []
                        let missingLabel = missingFields.isEmpty ? observed : "\(observed)，缺少字段：\(missingFields.joined(separator:", "))"
                        let message = "Apple 结账页仍在加载（\(step)，\(missingLabel)）；程序继续观察，不会重复点击"
                        state.stringValue = message
                        log(message)
                        run?.state = "checkout_transition_pending"
                        run?.automationPhase = "checkout_transition"
                        run?.pendingAction = "checkout_transition"
                        try? checkpoint()
                        recordTask("checkout_transition_still_waiting", ["pageStep":step,"pageState":observed])
                        lastWaitNotice = now
                    }
                }
                switch observed {
                case "payment_ready":
                    let pickupSummary = pickupMessage.hasPrefix("已回退选择第一个可取货门店") || pickupMessage.hasPrefix("已选择首选门店并进入取货联系人页面")
                        ? "\(pickupMessage)；" : ""
                    guard let method = CheckoutPaymentMethod(rawValue:settings.paymentMethod) else {
                        return "\(pickupSummary)联系人和发票资料已填写，已到付款方式页；尚未设置支付宝或微信支付，程序没有选择付款方式或提交订单。"
                    }
                    state.stringValue = "正在选择\(method.title)，核对订单…"
                    let flow = CheckoutOrderFlow(
                        browser: browser,
                        paymentMethod: method,
                        expectedPrice: run?.plan.variant.price ?? 0,
                        priceLimit: run?.plan.maxTotal ?? 0,
                        prepareSubmission: { [weak self] in
                            guard let self else { throw AppError("购买助手已关闭；未提交订单") }
                            try self.preparePendingOrderSubmission()
                        },
                        progress: { [weak self] message in
                            guard let self else { return }
                            self.state.stringValue = message
                            self.log(message)
                        }
                    )
                    let outcome = await flow.run()
                    if let order = outcome.order {
                        run?.state = "complete"
                        run?.pendingAction = nil
                        run?.attempted = []
                        run?.orderNumber = order.orderNumber
                        run?.orderCreatedAt = order.createdAt
                        run?.paymentDeadline = order.paymentDeadline
                        checkoutHandoffRunState = "complete"
                        try? checkpoint()
                        recordTask("pending_payment_order_created")
                    } else {
                        if outcome.preparedSubmission && !outcome.submissionMayHaveBeenIssued {
                            clearUnissuedPendingOrderSubmission()
                        }
                        checkoutHandoffRunState = "manual"
                    }
                    return "\(pickupSummary)\(outcome.message)"
                case "invoice_type_selected", "invoice_selection_waiting", "invoice_fields_loading", "contact_waiting":
                    try await Task.sleep(nanoseconds:250_000_000)
                case "contact_field_empty", "contact_field_invalid", "invoice_field_empty", "invoice_field_invalid":
                    return "Apple 结账页拒绝了一个必填资料字段；程序未继续。请在专用浏览器检查字段后再处理。"
                case "terms_authorization_required":
                    return "专票条款没有启用自动勾选授权；程序停在联系人/发票页，没有继续。"
                case "invoice_option_missing", "invoice_option_disabled":
                    return "本次订单无法使用预设的发票类型；程序没有改选其他类型或继续。请在官网选择适用选项。"
                case "continue_button_missing", "continue_disabled", "continue_clicked", "continue_pending":
                    if observed == "continue_clicked" || observed == "continue_pending" { continueWasIssued = true }
                    _ = try await browser.evaluate(waitForCheckoutChangeExpression)
                case "continue_button_ambiguous":
                    return "联系人与发票资料已处理，但 Apple 页面出现多个“继续选择付款方式”按钮；程序没有点击，请在专用浏览器核对。"
                case "field_ambiguous", "invoice_field_missing", "invoice_field_disabled", "invoice_field_no_tax_checkbox_missing", "invoice_field_no_tax_checkbox_ambiguous", "invoice_field_no_tax_checkbox_invalid", "invoice_field_terms_checkbox_missing", "invoice_field_terms_checkbox_ambiguous", "invoice_field_terms_checkbox_invalid":
                    return "Apple 结账表单与已识别结构不一致；程序停止自动填写，请在官网手动核对。"
                case "wrong_page":
                    return "结账页面已变化；程序没有在新页面继续填写，请在专用浏览器核对。"
                default:
                    _ = try await browser.evaluate(waitForCheckoutChangeExpression)
                }
            } catch is CancellationError {
                return "结账页面监控已停止；已发出的官网操作不会重复执行。"
            } catch {
                consecutiveReadFailures += 1
                if !browser.isConnected {
                    continue
                }
                if consecutiveReadFailures < 3 {
                    do {
                        try await browser.reconnectToTarget()
                        reconnectFailures = 0
                        continue
                    } catch {
                        let now = Date()
                        if lastReconnectNotice == nil || now.timeIntervalSince(lastReconnectNotice!) >= 15 {
                            state.stringValue = "专用 Edge 暂时无法读取；结账任务仍保留，程序会继续重试连接"
                            log("结账页读取失败，重新连接原专用 Edge 尚未成功；不重复点击")
                            lastReconnectNotice = now
                        }
                        try? await Task.sleep(nanoseconds:500_000_000)
                        continue
                    }
                }
                return continueWasIssued
                    ? "已发出一次继续到付款方式的操作，但专用 Edge 连续读取失败；程序保留结账页面且不会重复点击，请检查专用浏览器。"
                    : "专用 Edge 连续读取结账页面失败；程序没有重复点击，请检查专用浏览器。"
            }
        }
        return "结账页面监控已停止；已发出的官网操作不会重复执行。"
    }

    func preparePendingOrderSubmission() throws {
        guard var record = run else { throw AppError("本次任务记录已结束；未点击下单") }
        guard record.pendingAction != "order_submit" else { throw AppError("下单结果仍待核验；不会重复点击") }
        record.state = "order_submit_pending"
        record.pendingAction = "order_submit"
        record.attempted = [3]
        record.automationPhase = "submitting_order"
        record.updatedAt = Date()
        try store.write(record, "run.json")
        run = record
        recordTask("order_submission_prepared")
        log("Review 信息已核对；已保存提交前记录，准备只点击一次“立即下单”")
    }

    func clearUnissuedPendingOrderSubmission() {
        guard var record = run, record.pendingAction == "order_submit" else { return }
        record.pendingAction = nil
        record.attempted = []
        record.state = "manual"
        record.updatedAt = Date()
        run = record
        try? store.write(record, "run.json")
    }

    func autoSelectPickupAtHandoff(_ settings: PickupSettings) async -> String {
        let pickupFlowStarted = ProcessInfo.processInfo.systemUptime
        guard settings.countryCode == "zh_CN",
              let store = pickupDirectory?.stores.first(where: { $0.storeNumber == settings.preferredStoreNumber && $0.city == settings.city }) else {
            return "已到 Apple 结账页，但首选取货门店资料无效；请在官网手动选择门店。"
        }
        guard let browser, browser.isConnected else {
            return "已到 Apple 结账页，但专用浏览器连接已断开；请手动检查并选择取货门店。"
        }
        let pickupFlowToken = UUID().uuidString
        guard let payloadData = try? JSONSerialization.data(withJSONObject: [store.city, store.name, store.storeNumber, pickupFlowToken]),
              let payload = String(data: payloadData, encoding: .utf8) else {
            return "已到 Apple 结账页，但无法准备首选门店信息；请手动选择。"
        }
        let expression = """
        (() => {
          const [city,name,storeNumber,flowToken] = \(payload);
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const norm = s => String(s || '').replace(/[\\u200b-\\u200f\\u2060]/g, '').replace(/\\s+/g, ' ').trim();
          const text = e => norm((e?.innerText || '') + ' ' + (e?.getAttribute?.('aria-label') || ''));
          const findContinueButtons = () => [...document.querySelectorAll('button,a,[role="button"],input[type="submit"]')]
            .filter(e => norm(e.getAttribute('aria-label')).includes('继续填写取货详情') ||
              norm(e.value).includes('继续填写取货详情') || norm(e.textContent).includes('继续填写取货详情'))
            .filter(visible)
            .filter(e => norm(e.innerText || e.value || e.getAttribute('aria-label')) === '继续填写取货详情');
          const continueButtonActionable = button => !!button && !button.disabled &&
            button.getAttribute('aria-disabled') !== 'true' && getComputedStyle(button).pointerEvents !== 'none';
          if (!/^(www|secure\\d*\\.www)\\.apple\\.com\\.cn$/i.test(location.hostname) || !/^\\/shop\\/checkout(?:\\/|$)/i.test(location.pathname))
            return {state:'wrong_page'};
          if (window.__asaPickupFlowToken !== flowToken) {
            window.__asaPickupContinueObserver?.disconnect();
            clearTimeout(window.__asaPickupContinueObserverTimer);
            window.__asaPickupContinueObserverActive = false;
            window.__asaPickupFlowToken = flowToken;
            window.__asaPickupModeAttempted = false;
            window.__asaPickupStoreAttempted = null;
            window.__asaPickupStoreSelectionActionKey = null;
            window.__asaPickupContactContinueAttempted = null;
            window.__asaPickupContactContinueResult = null;
            window.__asaPickupTargetStoreCard = null;
            window.__asaPickupTargetStoreKey = null;
            window.__asaPickupStoreFallback = false;
            window.__asaPickupStoreLabel = '';
            window.__asaPickupStoreChoiceClickedAt = null;
            window.__asaPickupStoreSelectionObservedAt = null;
            window.__asaPickupFlowStartedAt = performance.now();
            window.__asaPickupContinueObserverInstalledAt = null;
            window.__asaPickupContactContinueResultReported = false;
          }
          const step = new URL(location.href).searchParams.get('_s') || '';
          const pendingContinueResult = window.__asaPickupContactContinueResult;
          if (pendingContinueResult?.flowToken === flowToken && window.__asaPickupContactContinueResultReported !== true) {
            window.__asaPickupContactContinueResultReported = true;
            return pendingContinueResult;
          }
          // The continue result records a past click. Keep checking the live
          // route and contact fields after that click; Apple may update this
          // same document with a client-side navigation.
          const hasContactFields = () => ['lastName','firstName','emailAddress','fullDaytimePhone'].every(name =>
            [...document.querySelectorAll(`input[name="${name}"]`)].some(visible));
          if (/^PickupContact(?:-|$)/i.test(step))
            return {state:hasContactFields() ? 'contact_ready' : 'contact_loading',fallback:window.__asaPickupStoreFallback === true,storeLabel:window.__asaPickupStoreLabel || ''};
          const clickContinueOnce = (button,attemptKey,fallback,storeLabel,detectionSource='snapshot',reportImmediately=true) => {
            const continueKey = attemptKey + ':contact:' + flowToken;
            if (window.__asaPickupContactContinueAttempted === continueKey)
              return {state:'waiting_contact',fallback,storeLabel,step};
            const readyDetectedAt = performance.now();
            const storeChoiceClickedAt = window.__asaPickupStoreChoiceClickedAt;
            const storeSelectedAt = window.__asaPickupStoreSelectionObservedAt;
            const checkoutReadiness = window.__asaCheckoutContinueReadiness;
            const checkoutMonitorReadyToClickMS = checkoutReadiness?.timeOrigin === performance.timeOrigin && checkoutReadiness.step === step
              ? Math.max(0,readyDetectedAt-checkoutReadiness.readyAt) : null;
            window.__asaPickupContactContinueAttempted = continueKey;
            const result = {
              state:'contact_continue_clicked',fallback,storeLabel,flowToken,step,
              selectionEvidence:'store_selected_and_continue_enabled',
              storeClickToButtonReadyMS:Number.isFinite(storeChoiceClickedAt) ? Math.max(0,readyDetectedAt-storeChoiceClickedAt) : null,
              storeSelectedToButtonReadyMS:Number.isFinite(storeSelectedAt) ? Math.max(0,readyDetectedAt-storeSelectedAt) : null,
              flowStartedToButtonReadyMS:Number.isFinite(window.__asaPickupFlowStartedAt) ? Math.max(0,readyDetectedAt-window.__asaPickupFlowStartedAt) : null,
              monitorStartedToButtonReadyMS:Number.isFinite(window.__asaPickupContinueObserverInstalledAt) ? Math.max(0,readyDetectedAt-window.__asaPickupContinueObserverInstalledAt) : null,
              buttonReadyDetectionSource:detectionSource,
              checkoutMonitorReadyToClickMS,
              checkoutMonitorReadyDetectionSource:checkoutReadiness?.source || null,
              buttonReadyDetectedToClickMS:0
            };
            window.__asaPickupContactContinueResult = result;
            window.__asaPickupContactContinueResultReported = reportImmediately;
            result.buttonReadyDetectedToClickMS = Math.max(0,performance.now()-readyDetectedAt);
            button.click();
            return result;
          };
          // Once the pickup-details action has been issued, only observe the
          // route and contact fields; do not rescan the entire store list.
          if (window.__asaPickupContactContinueAttempted) return {state:'waiting_contact',fallback:window.__asaPickupStoreFallback === true,storeLabel:window.__asaPickupStoreLabel || ''};
          const choiceRoot = e => e.closest('label,[role="radio"],button') || e;
          const radioFor = e => {
            const root = choiceRoot(e);
            return e.matches('input[type="radio"]') ? e : (root.querySelector('input[type="radio"]') || root.control || e.querySelector('input[type="radio"]') || null);
          };
          const selectedInCard = card => {
            if (!card?.isConnected) return false;
            const control = choiceRoot(card);
            const radio = radioFor(card);
            if (radio) return radio.checked || radio.getAttribute('aria-checked') === 'true';
            for (const node of new Set([card,control].filter(Boolean))) {
              if (['aria-checked','aria-selected','aria-pressed'].some(key => node.getAttribute(key) === 'true')) return true;
              const className = typeof node.className === 'string' ? node.className : (node.getAttribute('class') || '');
              if (/(?:^|[\\s_-])(selected|active|checked|is-selected|is-active)(?:$|[\\s_-])/i.test(className)) return true;
            }
            return false;
          };
          const installContinueObserver = (attemptKey,fallback,storeLabel) => {
            const continueKey = attemptKey + ':contact:' + flowToken;
            const commitIfReady = (detectionSource='mutation_observer',reportImmediately=false) => {
              if (window.__asaPickupFlowToken !== flowToken || window.__asaPickupStoreSelectionActionKey !== attemptKey ||
                  window.__asaPickupContactContinueAttempted === continueKey) return false;
              const targetCard = window.__asaPickupTargetStoreCard;
              if (!targetCard?.isConnected || !selectedInCard(targetCard)) return false;
              if (window.__asaPickupStoreSelectionObservedAt == null)
                window.__asaPickupStoreSelectionObservedAt = performance.now();
              const currentStep = new URL(location.href).searchParams.get('_s') || '';
              if (/^PickupContact(?:-|$)/i.test(currentStep) || (!/^Fulfillment(?:-|$)/i.test(currentStep) && hasContactFields())) {
                window.__asaPickupContinueObserver?.disconnect();
                window.__asaPickupContinueObserverActive = false;
                clearTimeout(window.__asaPickupContinueObserverTimer);
                return false;
              }
              const buttons = findContinueButtons();
              if (buttons.length !== 1) return false;
              const next = buttons[0];
              if (!continueButtonActionable(next)) return false;
              window.__asaPickupContinueObserver?.disconnect();
              window.__asaPickupContinueObserverActive = false;
              clearTimeout(window.__asaPickupContinueObserverTimer);
              return clickContinueOnce(next,attemptKey,fallback,storeLabel,detectionSource,reportImmediately).state === 'contact_continue_clicked';
            };
            if (window.__asaPickupContinueObserverKey === continueKey && window.__asaPickupContinueObserverActive)
              return commitIfReady('poll_recheck',true);
            window.__asaPickupContinueObserver?.disconnect();
            clearTimeout(window.__asaPickupContinueObserverTimer);
            const observer = new MutationObserver(() => { commitIfReady(); });
            window.__asaPickupContinueObserver = observer;
            window.__asaPickupContinueObserverKey = continueKey;
            window.__asaPickupContinueObserverActive = true;
            window.__asaPickupContinueObserverInstalledAt = performance.now();
            observer.observe(document.documentElement || document,{subtree:true,childList:true,attributes:true,attributeFilter:['disabled','aria-disabled','aria-busy','aria-label','aria-hidden','class','hidden','style','aria-checked','aria-selected','aria-pressed']});
            window.__asaPickupContinueObserverTimer = setTimeout(() => {
              observer.disconnect();
              if (window.__asaPickupContinueObserver === observer) window.__asaPickupContinueObserverActive = false;
            },25000);
            return commitIfReady('observer_initial_check',true);
          };
          // A configured store may already be selected when Fulfillment-init
          // appears. Install the CTA observer immediately, before scanning
          // every pickup option and store card.
          const fastSelectedStoreRadios = [...document.querySelectorAll('input[type="radio"][name="store-locator-result"]:checked')].filter(visible);
          if (fastSelectedStoreRadios.length === 1) {
            const radio = fastSelectedStoreRadios[0];
            const fastControlSelector = 'label,[role="radio"],button,[role="listitem"],li,article,[data-autom]';
            const card = [...(radio.labels || [])].find(visible) || radio.closest(fastControlSelector) || radio;
            const cardVisibleText = String(card.innerText || '');
            const lines = cardVisibleText.split(/\\n+/).map(norm).filter(Boolean);
            const appleLine = lines.find(value => /^Apple(?:\\s|$)/i.test(value)) || lines.find(value => /Apple/i.test(value)) || '';
            const storeLabel = appleLine.replace(/^\\d+\\s*/,'')
              .replace(/\\s+(?:目前不可取货|暂不可取货|不可取货|今天|明天|可取货|店内取货|pickup|delivery)(?:\\s.*)?$/i,'').trim();
            const cardText = norm(cardVisibleText + ' ' + (card.getAttribute('aria-label') || ''));
            const unavailable = /(?:当前|目前|暂时)?不可取货|unavailable|sold\\s*out/i;
            const storeAvailable = cardText.length >= 4 && cardText.length <= 480 && /Apple/i.test(cardText) && /可取货|pickup/i.test(cardText) && !unavailable.test(cardText);
            const disabled = !!(card.disabled || card.getAttribute('aria-disabled') === 'true' || radio.disabled || radio.getAttribute('aria-disabled') === 'true');
            const shortName = norm(name).startsWith(norm(city)) ? norm(name).slice(norm(city).length).trim() : norm(name);
            const preferredLabel = /^Apple(?:\\s|$)/i.test(shortName) ? shortName : norm('Apple ' + shortName);
            const preferredNames = new Set([norm(name),norm(preferredLabel)].filter(Boolean));
            if (preferredNames.has(norm(storeLabel)) && storeAvailable && !disabled) {
              const attemptKey = `preferred:${storeNumber}`;
              window.__asaPickupTargetStoreCard = card;
              window.__asaPickupTargetStoreKey = attemptKey;
              window.__asaPickupStoreSelectionActionKey = attemptKey;
              window.__asaPickupStoreFallback = false;
              window.__asaPickupStoreLabel = storeLabel;
              if (window.__asaPickupStoreSelectionObservedAt == null)
                window.__asaPickupStoreSelectionObservedAt = performance.now();
              if (installContinueObserver(attemptKey,false,storeLabel))
                return window.__asaPickupContactContinueResult;
              return {
                state:'contact_continue_monitoring',fallback:false,storeLabel,step,
                buttonMonitorActive:window.__asaPickupContinueObserverActive === true,
                monitorStartedToNowMS:Number.isFinite(window.__asaPickupContinueObserverInstalledAt)
                  ? Math.max(0,performance.now()-window.__asaPickupContinueObserverInstalledAt) : null
              };
            }
          }
          const controls = [...document.querySelectorAll('label,[role="radio"],button,input[type="radio"]')].filter(visible);
          const pickup = controls.filter(e => /我要取货|店内取货|pickup/i.test(text(e))).sort((a,b) => text(a).length - text(b).length)[0];
          if (!pickup) return {state:'pickup_option_missing'};
          const pickupRadio = radioFor(pickup);
          const pickupSelected = pickupRadio ? pickupRadio.checked : pickup.getAttribute('aria-checked') === 'true';
          const pickupDisabled = !!(pickup.disabled || pickup.getAttribute('aria-disabled') === 'true' || pickupRadio?.disabled || pickupRadio?.getAttribute('aria-disabled') === 'true');
          if (!pickupSelected) {
            if (pickupDisabled) return {state:'pickup_unavailable'};
            if (window.__asaPickupModeAttempted) return {state:'waiting_pickup'};
            window.__asaPickupModeAttempted = true;
            (pickupRadio?.labels?.[0] || pickup).click();
            return {state:'pickup_clicked'};
          }
          const cachedTarget = window.__asaPickupTargetStoreCard;
          const cachedKey = window.__asaPickupTargetStoreKey;
          if (cachedTarget?.isConnected && cachedKey) {
            const fallback = window.__asaPickupStoreFallback === true;
            const storeLabel = window.__asaPickupStoreLabel || '首个可取货门店';
            const storeClickIssued = window.__asaPickupStoreSelectionActionKey === cachedKey;
            const buttons = findContinueButtons();
            if (buttons.length > 1) return {state:'contact_continue_ambiguous',fallback,storeLabel};
            const next = buttons[0] || null;
            if (!selectedInCard(cachedTarget)) {
              if (storeClickIssued) installContinueObserver(cachedKey,fallback,storeLabel);
              return {state:'waiting_store',fallback,storeLabel};
            }
            if (window.__asaPickupStoreSelectionObservedAt == null)
              window.__asaPickupStoreSelectionObservedAt = performance.now();
            if (!next) {
              installContinueObserver(cachedKey,fallback,storeLabel);
              return {state:'contact_continue_missing',fallback,storeLabel};
            }
            if (!continueButtonActionable(next)) {
              installContinueObserver(cachedKey,fallback,storeLabel);
              return {state:'contact_continue_disabled',fallback,storeLabel};
            }
            return clickContinueOnce(next,cachedKey,fallback,storeLabel);
          }
          const unavailable = /(?:当前|目前|暂时)?不可取货|unavailable|sold\\s*out/i;
          const storeCardText = e => {
            const value = text(e);
            return value.length >= 4 && value.length <= 480 && /Apple/i.test(value) && /可取货|pickup/i.test(value);
          };
          const availableStoreCard = e => {
            return storeCardText(e) && !unavailable.test(text(e));
          };
          const controlSelector = 'label,[role="radio"],button,[role="listitem"],li,article,[data-autom]';
          const cardRoot = e => {
            for (let node = e, depth = 0; node && depth < 8; node = node.parentElement, depth++) {
              if (!availableStoreCard(node)) continue;
              if (node.matches(controlSelector) || node.querySelector('input[type="radio"]')) return node;
            }
            return e;
          };
          const disabledCard = card => {
            const radio = radioFor(card);
            return !!(card.disabled || card.getAttribute('aria-disabled') === 'true' || radio?.disabled || radio?.getAttribute('aria-disabled') === 'true');
          };
          const shortName = norm(name).startsWith(norm(city)) ? norm(name).slice(norm(city).length).trim() : norm(name);
          const preferredLabel = /^Apple(?:\\s|$)/i.test(shortName) ? shortName : norm('Apple ' + shortName);
          const cardStoreName = card => {
            const cardVisibleText = String(card.innerText || '');
            const lines = cardVisibleText.split(/\\n+/).map(norm).filter(Boolean);
            const line = lines.find(value => /^Apple(?:\\s|$)/i.test(value)) || lines.find(value => /Apple/i.test(value)) || '';
            return line.replace(/^\\d+\\s*/,'')
              .replace(/\\s+(?:目前不可取货|暂不可取货|不可取货|今天|明天|可取货|店内取货|pickup|delivery)(?:\\s.*)?$/i,'')
              .trim();
          };
          const preferredNames = new Set([norm(name),norm(preferredLabel)].filter(Boolean));
          const continueForSelectedStore = (target,fallback,storeLabel,attemptKey) => {
            window.__asaPickupTargetStoreCard = target;
            window.__asaPickupTargetStoreKey = attemptKey;
            window.__asaPickupStoreSelectionActionKey = attemptKey;
            window.__asaPickupStoreFallback = fallback;
            window.__asaPickupStoreLabel = storeLabel;
            if (!selectedInCard(target)) return {state:'waiting_store',fallback,storeLabel};
            if (window.__asaPickupStoreSelectionObservedAt == null)
              window.__asaPickupStoreSelectionObservedAt = performance.now();
            const buttons = findContinueButtons();
            if (buttons.length > 1) return {state:'contact_continue_ambiguous',fallback,storeLabel};
            const next = buttons[0] || null;
            if (!next) {
              installContinueObserver(attemptKey,fallback,storeLabel);
              return {state:'contact_continue_missing',fallback,storeLabel};
            }
            if (!continueButtonActionable(next)) {
              installContinueObserver(attemptKey,fallback,storeLabel);
              return {state:'contact_continue_disabled',fallback,storeLabel};
            }
            return clickContinueOnce(next,attemptKey,fallback,storeLabel);
          };

          // Apple often preselects the configured store. Check that one
          // selected radio first and skip the expensive full-DOM card scan.
          const selectedStoreRadios = [...document.querySelectorAll('input[type="radio"][name="store-locator-result"]:checked')].filter(visible);
          if (selectedStoreRadios.length === 1) {
            const radio = selectedStoreRadios[0];
            const target = [...(radio.labels || [])].find(visible) || radio.closest(controlSelector) || radio;
            const storeLabel = cardStoreName(target);
            if (preferredNames.has(norm(storeLabel)) && availableStoreCard(target) && !disabledCard(target))
              return continueForSelectedStore(target,false,storeLabel,`preferred:${storeNumber}`);
          }

          const visibleStoreRows = [...document.querySelectorAll(`${controlSelector},div`)].filter(visible).filter(storeCardText);
          const rawCards = visibleStoreRows.filter(availableStoreCard);
          const uniqueCards = new Map();
          for (const card of rawCards.map(cardRoot)) {
            const control = radioFor(card) || choiceRoot(card);
            if (!uniqueCards.has(control)) uniqueCards.set(control,card);
          }
          const cards = [...uniqueCards.values()].filter(visible).filter(availableStoreCard).filter(card => !disabledCard(card));
          cards.sort((a,b) => a === b ? 0 : (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
          if (!cards.length) return {state:visibleStoreRows.length ? 'no_available_store' : 'store_list_loading'};
          const preferredMatches = cards.filter(card => preferredNames.has(norm(cardStoreName(card))));
          if (preferredMatches.length > 1) return {state:'preferred_store_ambiguous'};
          const preferred = preferredMatches[0] || null;
          const target = preferred || cards[0];
          const fallback = !preferred;
          const title = card => {
            return (cardStoreName(card) || '首个可取货门店').slice(0,100);
          };
          const storeLabel = title(target);
          const radio = radioFor(target);
          const chosenStoreIsSelected = selectedInCard(target);
          if (chosenStoreIsSelected && window.__asaPickupStoreSelectionObservedAt == null)
            window.__asaPickupStoreSelectionObservedAt = performance.now();
          const attemptKey = fallback ? `fallback:${storeLabel}` : `preferred:${storeNumber}`;
          const storeClickIssued = window.__asaPickupStoreSelectionActionKey === attemptKey;
          window.__asaPickupTargetStoreCard = target;
          window.__asaPickupTargetStoreKey = attemptKey;
          if (!chosenStoreIsSelected) {
            if (storeClickIssued) {
              if (installContinueObserver(attemptKey,fallback,storeLabel))
                return window.__asaPickupContactContinueResult;
              return {state:'waiting_store',fallback,storeLabel};
            }
            window.__asaPickupStoreAttempted = attemptKey;
            window.__asaPickupStoreSelectionActionKey = attemptKey;
            window.__asaPickupStoreFallback = fallback;
            window.__asaPickupStoreLabel = storeLabel;
            window.__asaPickupStoreChoiceClickedAt = performance.now();
            (radio?.labels?.[0] || choiceRoot(target)).click();
            if (installContinueObserver(attemptKey,fallback,storeLabel))
              return window.__asaPickupContactContinueResult;
            return {state:fallback ? 'fallback_store_clicked' : 'preferred_store_clicked',fallback,storeLabel};
          }
          return continueForSelectedStore(target,fallback,storeLabel,attemptKey);
        })()
        """
        state.stringValue = "已到结账页，正在匹配取货门店…"
        var fallbackStoreLabel = ""
        var preferredStoreLabel = ""
        var fallbackWasLogged = false
        var contactContinueWasDisabled = false
        var contactContinueDisabledStoreLabel = ""
        var contactContinueDisabledWasLogged = false
        var pickupContinueMonitorStartedWasLogged = false
        var storeSelectionClickedAt: TimeInterval?
        var pickupDetailsContinueClickedAt: TimeInterval?
        func contactReachedMessage(_ facts: [String: Any]) -> String? {
            guard let observed = facts["state"] as? String,
                  observed == "contact_ready" || observed == "contact_loading" else { return nil }
            let label = facts["storeLabel"] as? String ?? "首个可取货门店"
            let fallback = facts["fallback"] as? Bool == true
            let contactFieldsReady = observed == "contact_ready"
            if fallback || fallbackWasLogged {
                let chosenLabel = label.isEmpty ? fallbackStoreLabel : label
                return contactFieldsReady
                    ? "已回退选择第一个可取货门店 \(chosenLabel)，并进入取货联系人页面。"
                    : "已回退选择第一个可取货门店 \(chosenLabel)，已进入取货联系人步骤，页面字段仍在加载。"
            }
            let chosenLabel = label.isEmpty ? preferredStoreLabel : label
            if !chosenLabel.isEmpty && chosenLabel != "首个可取货门店" {
                return contactFieldsReady
                    ? "已选择首选门店并进入取货联系人页面：\(chosenLabel)"
                    : "已选择首选门店并进入取货联系人页面：\(chosenLabel)（页面字段仍在加载）"
            }
            return contactFieldsReady ? "已到取货联系人页面。" : "已进入取货联系人步骤，页面字段仍在加载。"
        }
        func waitForContactPageAfterContinue() async -> String {
            let waitStarted = ProcessInfo.processInfo.systemUptime
            let deadline = waitStarted + 30
            var reconnectNoticeLogged = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                if Task.isCancelled {
                    return "已点击“继续填写取货详情”，页面监控已停止；程序没有重复点击。"
                }
                if !browser.isConnected {
                    do {
                        try await browser.reconnectToTarget()
                        reconnectNoticeLogged = false
                    } catch {
                        if !reconnectNoticeLogged {
                            log("“继续填写取货详情”已点击，正在重新连接专用浏览器并确认联系人页；不会重复点击")
                            reconnectNoticeLogged = true
                        }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        continue
                    }
                }
                do {
                    let facts = try await browser.evaluate(expression) as? [String: Any] ?? [:]
                    if let reached = contactReachedMessage(facts) {
                        let stage = facts["state"] as? String == "contact_ready" ? "联系人表单就绪" : "联系人步骤出现但字段仍在加载"
                        logManagedDuration("继续填写取货详情后\(stage)", started: waitStarted)
                        return reached
                    }
                    if facts["state"] as? String == "wrong_page" {
                        return "已点击“继续填写取货详情”，但页面已离开 Apple 结账流程；程序没有重复点击，请检查专用浏览器。"
                    }
                } catch is CancellationError {
                    return "已点击“继续填写取货详情”，页面监控已停止；程序没有重复点击。"
                } catch {
                    if !reconnectNoticeLogged {
                        log("“继续填写取货详情”已点击，暂时无法读取页面状态；正在恢复专用浏览器连接，不会重复点击")
                        reconnectNoticeLogged = true
                    }
                    if !browser.isConnected {
                        try? await browser.reconnectToTarget()
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if browser.isConnected,
               let facts = try? await browser.evaluate(expression) as? [String: Any],
               let reached = contactReachedMessage(facts) {
                let stage = facts["state"] as? String == "contact_ready" ? "联系人表单就绪" : "联系人步骤出现但字段仍在加载"
                logManagedDuration("继续填写取货详情后\(stage)", started: waitStarted)
                return reached
            }
            return "已点击“继续填写取货详情”，但 Apple 在 30 秒内未确认进入取货联系人页面；程序没有重复点击或继续填写。请检查专用浏览器页面。"
        }
        for _ in 0..<80 {
            do {
                let facts = try await browser.evaluate(expression) as? [String: Any] ?? [:]
                if let reached = contactReachedMessage(facts) {
                    if let clickedAt = pickupDetailsContinueClickedAt {
                        let stage = facts["state"] as? String == "contact_ready" ? "联系人表单就绪" : "联系人步骤出现但字段仍在加载"
                        logManagedDuration("继续填写取货详情后\(stage)", started: clickedAt)
                    }
                    return reached
                }
                let label = facts["storeLabel"] as? String ?? "首个可取货门店"
                let fallback = facts["fallback"] as? Bool == true
                if facts["buttonMonitorActive"] as? Bool == true && !pickupContinueMonitorStartedWasLogged {
                    let pageStep = facts["step"] as? String ?? "Fulfillment-init"
                    log("已确认首选门店已选中；已启动 \(pageStep)“继续填写取货详情”按钮可点击监控，Apple 一启用就触发一次")
                    var monitorDetails = ["pageStep":pageStep,"storeLabel":label,"monitor":"MutationObserver"]
                    if let elapsed = facts["monitorStartedToNowMS"] as? Double {
                        monitorDetails["monitorStartedToFirstStatusMS"] = String(format:"%.1f", elapsed)
                    }
                    recordTask("pickup_continue_button_monitor_started", monitorDetails)
                    pickupContinueMonitorStartedWasLogged = true
                }
                switch facts["state"] as? String {
                case "contact_ready", "contact_loading":
                    break
                case "pickup_option_missing", "pickup_unavailable":
                    return "Apple 结账页当前没有可用的“我要取货”选项；程序未修改配送地址，请手动检查页面。"
                case "store_list_loading":
                    try await Task.sleep(nanoseconds: 250_000_000)
                case "preferred_store_ambiguous":
                    return "Apple 结账页出现多个与首选门店名称完全匹配的选项；程序没有选择或继续，请手动核对门店。"
                case "fallback_store_clicked":
                    fallbackStoreLabel = label
                    storeSelectionClickedAt = ProcessInfo.processInfo.systemUptime
                    if !fallbackWasLogged {
                        log("首选门店未匹配，已尝试选择第一个可取货门店：\(label)")
                        fallbackWasLogged = true
                    }
                    state.stringValue = "首选门店未匹配，正在选择第一个可取货门店并继续…"
                    try await Task.sleep(nanoseconds: 100_000_000)
                case "preferred_store_clicked":
                    preferredStoreLabel = label
                    storeSelectionClickedAt = ProcessInfo.processInfo.systemUptime
                    log("已点击首选取货门店：\(label)；正在等待 Apple 确认选择")
                    try await Task.sleep(nanoseconds: 100_000_000)
                case "waiting_store":
                    if fallback { fallbackStoreLabel = label }
                    try await Task.sleep(nanoseconds: 100_000_000)
                case "pickup_clicked":
                    if fallback { fallbackStoreLabel = label }
                    try await Task.sleep(nanoseconds: 50_000_000)
                case "waiting_pickup", "waiting_contact", "contact_continue_missing":
                    if fallback { fallbackStoreLabel = label }
                    try await Task.sleep(nanoseconds: 100_000_000)
                case "contact_continue_monitoring":
                    preferredStoreLabel = label
                    state.stringValue = "已确认首选门店，正在监控继续按钮；按钮启用后立即触发…"
                    try await Task.sleep(nanoseconds: 100_000_000)
                case "contact_continue_clicked":
                    pickupDetailsContinueClickedAt = ProcessInfo.processInfo.systemUptime
                    let pageStep = facts["step"] as? String ?? "未知结账步骤"
                    let buttonReadyDelayMS = facts["buttonReadyDetectedToClickMS"] as? Double
                    let storeClickToReadyMS = facts["storeClickToButtonReadyMS"] as? Double
                    let storeSelectedToReadyMS = facts["storeSelectedToButtonReadyMS"] as? Double
                    let flowStartedToReadyMS = facts["flowStartedToButtonReadyMS"] as? Double
                    let monitorStartedToReadyMS = facts["monitorStartedToButtonReadyMS"] as? Double
                    let checkoutMonitorReadyToClickMS = facts["checkoutMonitorReadyToClickMS"] as? Double
                    let checkoutMonitorReadyDetectionSource = facts["checkoutMonitorReadyDetectionSource"] as? String ?? "unknown"
                    let detectionSource = facts["buttonReadyDetectionSource"] as? String ?? "unknown"
                    if fallback {
                        fallbackStoreLabel = label
                        if !fallbackWasLogged {
                            log("已确认回退门店已选中；\(pageStep) 的唯一“继续填写取货详情”按钮可用，立即点击：\(label)")
                            fallbackWasLogged = true
                        }
                    } else {
                        preferredStoreLabel = label
                        log("已确认首选门店已选中；\(pageStep) 的唯一“继续填写取货详情”按钮可用，立即点击：\(label)")
                    }
                    var readinessDetails = ["pageStep":pageStep,"storeLabel":label]
                    readinessDetails["buttonReadyDetectionSource"] = detectionSource
                    readinessDetails["checkoutMonitorReadyDetectionSource"] = checkoutMonitorReadyDetectionSource
                    if let flowStartedToReadyMS {
                        readinessDetails["flowStartedToButtonReadyMS"] = String(format:"%.1f", flowStartedToReadyMS)
                    }
                    if let monitorStartedToReadyMS {
                        readinessDetails["monitorStartedToButtonReadyMS"] = String(format:"%.1f", monitorStartedToReadyMS)
                        log(String(format:"[执行耗时] 按钮监控启动至可用：%.1f ms；识别方式：%@", monitorStartedToReadyMS, detectionSource))
                    }
                    if let storeClickToReadyMS {
                        readinessDetails["storeClickToButtonReadyMS"] = String(format:"%.1f", storeClickToReadyMS)
                    }
                    if let storeSelectedToReadyMS {
                        readinessDetails["storeSelectedToButtonReadyMS"] = String(format:"%.1f", storeSelectedToReadyMS)
                    }
                    if let buttonReadyDelayMS {
                        readinessDetails["buttonReadyDetectedToClickMS"] = String(format:"%.1f", buttonReadyDelayMS)
                        log(String(format:"[执行耗时] 按钮可用至触发点击：%.1f ms", buttonReadyDelayMS))
                    }
                    if let checkoutMonitorReadyToClickMS {
                        readinessDetails["checkoutMonitorReadyToClickMS"] = String(format:"%.1f", checkoutMonitorReadyToClickMS)
                        log(String(format:"[执行耗时] Fulfillment 页面前置监控确认可用至触发点击：%.1f ms；识别方式：%@", checkoutMonitorReadyToClickMS, checkoutMonitorReadyDetectionSource))
                    } else {
                        readinessDetails["checkoutMonitorReadyToClickMS"] = "unavailable"
                    }
                    recordTask("pickup_continue_button_ready_clicked", readinessDetails)
                    if let storeClickToReadyMS {
                        log(String(format:"[执行耗时] 门店点击至继续按钮可用：%.1f ms", storeClickToReadyMS))
                    } else if let storeSelectedToReadyMS {
                        log(String(format:"[执行耗时] 门店选中至继续按钮可用：%.1f ms", storeSelectedToReadyMS))
                    }
                    if let storeSelectionClickedAt {
                        logManagedDuration("门店选择触发至继续按钮点击", started: storeSelectionClickedAt)
                    } else {
                        logManagedDuration("取货页检查启动至继续按钮点击", started: pickupFlowStarted)
                    }
                    state.stringValue = "已点击继续填写取货详情，正在确认联系人页面…"
                    return await waitForContactPageAfterContinue()
                case "contact_continue_ambiguous":
                    return "已选中取货门店，但 Apple 页面出现多个“继续填写取货详情”按钮；程序没有点击，请手动核对。"
                case "contact_continue_disabled":
                    contactContinueWasDisabled = true
                    contactContinueDisabledStoreLabel = label
                    state.stringValue = "已选中取货门店，正在等待 Apple 加载取货联系人页…"
                    if !contactContinueDisabledWasLogged {
                        log("已选中门店 \(label)，但“继续填写取货详情”仍不可用；等待 Apple 页面更新")
                        contactContinueDisabledWasLogged = true
                    }
                    try await Task.sleep(nanoseconds:250_000_000)
                case "wrong_page":
                    return "结账页面已变化；程序未操作门店或继续按钮，请在专用浏览器核对。"
                case "no_available_store":
                    return "Apple 当前没有显示可取货门店；程序没有修改地点或继续结账。"
                default:
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch {
                return "取货门店自动选择未能确认：\(error.localizedDescription)。程序没有继续结账。"
            }
        }
        if let facts = try? await browser.evaluate(expression) as? [String: Any],
           let reached = contactReachedMessage(facts) {
            return reached
        }
        if contactContinueWasDisabled {
            let selectedStore = contactContinueDisabledStoreLabel.isEmpty ? "所选门店" : contactContinueDisabledStoreLabel
            return "已选中取货门店 \(selectedStore)，但继续按钮仍不可用且页面未确认进入取货联系人步骤；程序没有重复点击。请检查专用浏览器页面。"
        }
        if !fallbackStoreLabel.isEmpty {
            return "已尝试选择第一个可取货门店 \(fallbackStoreLabel)，但未能确认 Apple 已选中并进入联系人页；程序没有重复点击或继续。"
        }
        return "Apple 当前没有确认首选取货门店并显示“继续填写取货详情”；程序没有修改地点或继续结账。"
    }

    @objc func showManagedBrowser() {
        guard let browser, browser.isConnected else { return }
        Task { @MainActor in
            try? await browser.bringToFront()
            _ = browser.activateManagedBrowserWindow()
        }
    }
    func logManagedDuration(_ stage: String, started: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        log(String(format: "[执行耗时] %@：%.1f ms；相对开售时间 %+.1f ms", stage, (now - started) * 1000, (now - monotonicTarget) * 1000))
    }
    func setEditing(_ enabled: Bool) { editControls.forEach{$0.isEnabled = enabled}; options.forEach{$0.1.isEnabled = enabled}; armButton.isEnabled = enabled }
    @objc func tick() {
        guard automation != nil, let r = run else { return }
        let remaining = monotonicTarget - ProcessInfo.processInfo.systemUptime
        if remaining + r.plan.executionSeconds <= 0 {
            let message: String
            switch r.pendingAction {
            case "add": message = "执行窗口已结束；加购结果未确认，请检查购物袋。程序不会重复加购"
            case "checkout": message = "执行窗口已结束；结账结果未确认，请检查官网页面。程序不会重复点击"
            case "continue": message = "执行窗口已结束；继续购买步骤结果未确认，请检查官网页面。程序不会重复点击"
            case .some: message = "执行窗口已结束；购买动作结果未确认，请检查官网页面。程序不会重复执行该动作"
            case .none: message = "执行窗口已结束，请检查官网当前状态"
            }
            finish(message, state:r.pendingAction == nil ? "expired" : "manual")
            NSSound.beep(); return
        }
        if abs(r.plan.releaseAt.timeIntervalSinceNow - remaining) > 2 {
            finish("系统时间发生变化或电脑从睡眠恢复，请重新核对抢购时间", state: "manual")
            return
        }
        countdown.stringValue = remaining > 0
            ? String(format:"距抢购 %02d:%02d:%02d",Int(remaining)/3600,Int(remaining)%3600/60,Int(remaining)%60)
            : String(format:"执行窗口剩余 %.0f 秒",max(0,r.plan.executionSeconds + remaining))
    }
    @objc func cancel() {
        guard run != nil else { return }
        if run?.pendingAction == "order_submit" {
            state.stringValue = "下单结果正在核验；为防止重复下单，核验结束前不能停止。"
            log("下单结果正在核验；暂不取消或重复提交")
            return
        }
        finish("已停止；已发出的官网操作不会被撤回，请核对购物袋或订单",state:"cancelled")
    }
    func finish(_ message: String, state value: String) {
        let previouslyDisplayed = state.stringValue
        let wasDemo = isDemo
        let unresolvedOrderSubmission = run?.pendingAction == "order_submit" && value != "complete"
        let persistedRunState = unresolvedOrderSubmission ? "order_confirmation_pending" : value
        automationTask?.cancel(); automationTask = nil; automation = nil
        if wasDemo {
            completedDemo = value == "handoff"
            try? store.write(["passed":completedDemo,"productionEngine":true],"demo-result.json")
        }
        run?.state = persistedRunState; recordTask("finished", ["result": persistedRunState]); try? checkpoint(); run = nil; taskRecording?.close(); taskRecording = nil; generation = UUID(); busy = false; timer?.invalidate(); timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        countdown.stringValue = wasDemo && completedDemo ? "演练完成" : (value == "complete" ? "抢购成功 · 订单待付款" : (value == "handoff" ? "等待你核对结账页面" : (value == "cancelled" ? "已停止" : "需要检查官网状态")))
        let display = wasDemo && completedDemo ? "离线演练通过：正式流程协调器完成模拟加购和结账；未访问 Apple" : message
        setEditing(true); stopButton.isEnabled = false; resumeButton.isEnabled = false; state.stringValue = display; state.textColor = value == "manual" || value == "expired" ? .systemOrange : .systemBlue
        if previouslyDisplayed != display { log(display) }
        workflowCompleted = value == "complete" || (wasDemo && completedDemo)
        updateWorkflowStatus()
        isDemo = false
        if wasDemo && CommandLine.arguments.contains("--self-test") { NSApp.terminate(nil) }
    }
    @objc func openLogs() { NSWorkspace.shared.open(store.root) }
    @objc func startDemo() {
        guard run == nil else { return }; isDemo = true; completedDemo = false; generation = UUID()
        let v = Variant(partNumber:"DEMO001/A",family:"demo",selections:[:],label:"演示商品（不访问 Apple）",url:"https://www.apple.com.cn/shop/product/demo001/a",price:100,comingSoon:false)
        var p = Plan(name:"离线演示",source:v.url,variant:v,catalogHash:"demo",releaseAt:Date().addingTimeInterval(3))
        p.prepareSeconds = 3; p.quietSeconds = 1; p.executionSeconds = 15
        workflowPlanSelected = true; workflowProductLocked = true; workflowCompleted = false; updateWorkflowStatus()
        run = RunRecord(plan:p); begin(p)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        logNavigation("开始导航", webView: webView)
        if isAccountWeb(webView) {
            accountLoadTimer?.invalidate()
            showAccountOverlay("正在等待 Apple 官方页面响应…", retry: false)
            accountLoadTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self, weak webView] _ in
                Task { @MainActor in
                    guard let self, let webView, webView.isLoading else { return }
                    self.logNavigation("加载超过 30 秒", webView: webView)
                    self.showAccountOverlay("Apple 官方账号页超过 30 秒未完成加载。\n可先查看当前页面；若页面无响应，再重新加载。", retry: true)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logNavigation("已提交页面", webView: webView)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logNavigation("加载完成", webView: webView)
        if isAccountWeb(webView) {
            accountLoadTimer?.invalidate(); accountLoadTimer = nil
            accountHealthStarted = Date()
            accountHealthTimer?.invalidate()
            accountHealthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.monitorAccountPage() }
            }
            accountOverlay?.isHidden = true
        }
        if webView === web { pageURL.stringValue = isDemo ? "离线演示 · 使用正式执行引擎" : "\(webView.url?.host ?? "欢迎")\(webView.url?.path ?? "")" }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        logNavigation("初始加载失败", webView: webView, error: error)
        if isAccountWeb(webView) { accountLoadTimer?.invalidate(); accountLoadTimer = nil; showAccountOverlay("Apple 官方账号页加载失败：\((error as NSError).localizedDescription)", retry: true) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        logNavigation("页面加载失败", webView: webView, error: error)
        if isAccountWeb(webView) { accountLoadTimer?.invalidate(); accountLoadTimer = nil; showAccountOverlay("Apple 官方账号页加载失败：\((error as NSError).localizedDescription)", retry: true) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logNavigation("WebKit 页面进程已终止", webView: webView)
        if isAccountWeb(webView) {
            accountLoadTimer?.invalidate(); accountLoadTimer = nil
            showAccountOverlay("Apple 官方页面进程已终止。请重新加载当前页面。", retry: true)
        } else if run != nil && isDemo {
            log("诊断页面进程已终止")
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if isDemo && action.navigationType == .linkActivated { decisionHandler(.cancel); return }
        if url.scheme == "about" { decisionHandler(.allow); return }
        // Only main-frame navigation is scoped; Apple's login iframes/resources
        // are handled by WebKit without reading their credentials.
        if action.targetFrame?.isMainFrame != false {
            let h = url.host ?? ""
            if url.scheme != "https" || !isAllowedAppleHost(h, for: webView) {
                log("[\(browserName(webView))] 拦截非官方主框架跳转：\(url.scheme ?? "")://\(safeURL(url))")
                decisionHandler(.cancel)
                log("诊断页面请求打开外部支付或验证页面")
                let a = NSAlert(); a.messageText = "在系统浏览器完成官方跳转？"; a.informativeText = h; a.addButton(withTitle:"打开"); a.addButton(withTitle:"取消")
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }; return
            }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil else { return nil }
        configuration.websiteDataStore = .default(); configuration.processPool = processPool
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        popup.navigationDelegate = self; popup.uiDelegate = self
        let popupWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        popupWindow.title = isAccountWeb(webView) ? "Apple 账号验证 · App 内官方页面" : "Apple 官方页面"
        popupWindow.contentView = popup; popupWindow.isReleasedWhenClosed = false
        popup.autoresizingMask = [.width, .height]
        popupWindows[ObjectIdentifier(popup)] = popupWindow
        popupWindow.center(); popupWindow.makeKeyAndOrderFront(nil)
        log("[\(browserName(webView))] 接管官方新窗口：\(safeURL(action.request.url))")
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) {
        if let window = popupWindows.removeValue(forKey: ObjectIdentifier(webView)) {
            window.close()
            log("[\(browserName(webView))] 官方新窗口已关闭")
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { alert(message); completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { let a = NSAlert(); a.messageText = message; a.addButton(withTitle:"确定"); a.addButton(withTitle:"取消"); completionHandler(a.runModal() == .alertFirstButtonReturn) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt.isEmpty ? "Apple 官方页面需要验证码" : prompt
        a.informativeText = "验证码只会提交给当前 Apple 官方页面，不会写入运行日志或本地文件。"
        let input = NSSecureTextField(string: defaultText ?? ""); input.placeholderString = "输入验证码"; input.frame.size = NSSize(width: 260, height: 24)
        a.accessoryView = input; a.addButton(withTitle: "提交"); a.addButton(withTitle: "取消")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? input.stringValue : nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === accountWindow {
            accountLoadTimer?.invalidate(); accountLoadTimer = nil
            accountHealthTimer?.invalidate(); accountHealthTimer = nil
            unmountAccountWeb()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, run != nil else { return true }
        return confirmStopForQuit()
    }
    func confirmStopForQuit() -> Bool {
        let warning = NSAlert(); warning.messageText = "托管任务正在运行"
        warning.informativeText = "关闭 App 会停止本次托管；专用浏览器会继续运行，以保留 Apple Store 登录会话。已经发出的官网操作不会撤回，请在专用浏览器核对当前页面。"
        warning.addButton(withTitle:"保持托管"); warning.addButton(withTitle:"停止并退出")
        guard warning.runModal() == .alertSecondButtonReturn else { return false }
        cancel(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let taskWasRunning = run != nil
        if taskWasRunning && !confirmStopForQuit() { return .terminateCancel }
        managedBrowserStartTask?.cancel()
        managedBrowserStartTask = nil
        managedAccountMonitor?.cancel()
        if browser?.stop(closeManagedBrowser: false) == false {
            setManagedBrowserVisual("断开控制失败", color: .systemRed)
            setBrowserStatus("浏览器：控制连接断开失败；App 保持打开，请稍后重试")
            alert("专用浏览器控制连接暂时无法断开，因此没有退出 App。请稍后重试。")
            return .terminateCancel
        }
        return .terminateNow
    }
    let welcomeHTML = """
    <html lang="zh"><meta charset="utf-8"><style>body{font:18px -apple-system;background:#f5f5f7;color:#1d1d1f;margin:12%;line-height:1.7}h1{font-size:42px;letter-spacing:-2px}small{color:#6e6e73}</style><small>APPLE STORE ASSISTANT</small><h1>你的商品。你的时间。</h1><p>专用 Edge 正在打开 Apple 账号页。当前版本会尝试触发 Edge 自带的已保存凭据填充；页面脚本会检查账号是否匹配、密码栏是否非空，然后至多提交一次登录。密码字符串不会作为脚本结果返回给 App 原生侧，也不会写入计划或日志；但 App 可通过本机调试接口控制专用浏览器，因此不能承诺技术上无法接触登录表单或凭据。当前界面没有关闭此自动尝试的开关；若你不接受，请暂勿使用真实 Apple 账号。若没有可用的已保存凭据，或 Apple 要求验证码/身份验证，请在该浏览器按官网提示完成。</p><p>正常退出 App 会关闭专用浏览器进程，并保留专用资料目录中的登录会话；连接启动失败时会保留窗口供检查。下次启动或 Apple 要求重新验证时，仍需按官网提示完成。</p><p>账号、商品与购买状态会显示在左侧。到达结账页后，请在专用浏览器核对信息并由你决定是否付款。</p><small>专用浏览器与日常浏览器资料隔离；无需额外开启 macOS 自动化或辅助功能权限。</small></html>
    """
    let demoHTML = """
    <html lang="zh"><meta charset="utf-8"><style>body{font:20px -apple-system;margin:12%;background:#f5f5f7}button{padding:14px 24px;border:0;border-radius:24px;background:#0071e3;color:white;font:16px -apple-system;margin-right:12px}</style><h1>离线购买演示</h1><p>使用正式执行引擎测试本地网页，不连接 Apple、不生成真实订单。</p><button id="add" onclick="this.hidden=true;document.getElementById('bag').hidden=false;document.getElementById('checkout').hidden=false;document.getElementById('result').textContent='购物袋：演示商品 × 1'">加入购物袋</button><div id="bag" data-autom="bag-item" hidden><a href="https://www.apple.com.cn/shop/product/demo001/a">DEMO001/A</a><select name="quantity"><option value="1">1</option></select></div><button id="checkout" hidden onclick="history.pushState({},'', '/shop/checkout');document.getElementById('result').textContent='订单确认页 · 演示完成，无真实订单'">结账</button><p id="result">等待预定时间…</p></html>
    """
}

@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = StoreApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
