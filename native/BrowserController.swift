import Foundation
import Darwin
import AppKit

private final class BrowserCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private func browserCommandLine(pid: Int32) -> String? {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/ps")
    probe.arguments = ["-p", String(pid), "-o", "command="]
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    guard (try? probe.run()) != nil else { return nil }
    let command = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    probe.waitUntilExit()
    return command
}

// Chromium keeps the PID of the process using this profile in SingletonLock.
func activeManagedBrowserProfilePID(_ profile: URL) -> Int32? {
    let lock = profile.appendingPathComponent("SingletonLock").path
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
          let suffix = destination.split(separator: "-").last,
          let pid = Int32(suffix), pid > 0 else { return nil }
    if Darwin.kill(pid, 0) == 0 || errno == EPERM { return pid }
    return nil
}

private func verifiedManagedBrowserProfilePID(_ profile: URL) -> Int32? {
    guard let pid = activeManagedBrowserProfilePID(profile),
          let command = browserCommandLine(pid: pid),
          command.contains("--user-data-dir=\(profile.path)") else { return nil }
    return pid
}

enum BrowserControllerError: LocalizedError {
    case noSupportedBrowser
    case launchFailed(String)
    case profileInUse(Int32)
    case devToolsUnavailable
    case noPageTarget
    case websocketUnavailable
    case protocolError(String)
    case targetMismatch(String)

    var errorDescription: String? {
        switch self {
        case .noSupportedBrowser: return "未找到 Microsoft Edge 或 Google Chrome"
        case .launchFailed(let value): return "专用浏览器启动失败：\(value)"
        case .profileInUse(let pid): return "专用浏览器进程 \(pid) 仍未退出，未重复启动。请手动退出专用浏览器后重试"
        case .devToolsUnavailable: return "浏览器远程控制接口未在规定时间内就绪"
        case .noPageTarget: return "专用浏览器没有可控制的页面"
        case .websocketUnavailable: return "无法连接专用浏览器控制通道"
        case .protocolError(let value): return "浏览器控制协议错误：\(value)"
        case .targetMismatch(let value): return "浏览器页面校验失败：\(value)"
        }
    }
}

struct ManagedBrowserInfo: Sendable {
    let browserName: String
    let port: Int
    let targetID: String
    let url: String
}

struct BrowserSelfTestResult: Codable {
    let iterations: Int
    let passed: Bool
    let p50MS: Double
    let p95MS: Double
    let p99MS: Double
    let maxMS: Double
    let finalCount: Int
    let browser: String
    let port: Int
}

@MainActor
final class BrowserController: NSObject {
    private struct Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
    }

    private var process: Process?
    private let isolatedProfileURL: URL?
    private let launchHeadless: Bool
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private(set) var info: ManagedBrowserInfo?
    private(set) var isConnected = false
    private(set) var lastDisconnectReason: String?
    private var browserName = ""
    private var browserPort = 0
    private var targetID = ""
    private var targetURL = ""
    private var savedLoginAttemptKey = ""
    private var savedLoginAttemptResult = ""
    private var lastAttachFailure: String?
    private(set) var attachedToExisting = false
    private(set) var hasOpenBagOrCheckoutPage = false
    var onDiagnostic: ((String) -> Void)?
    private var fixturePages: [String: String]?

    init(isolatedProfileURL: URL? = nil, launchHeadless: Bool = false) {
        self.isolatedProfileURL = isolatedProfileURL
        self.launchHeadless = launchHeadless
        super.init()
    }

    deinit {
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        if isolatedProfileURL != nil, let process, process.isRunning { process.terminate() }
    }

    func start(initialURL: URL? = nil, attachExisting: Bool = true) async throws -> ManagedBrowserInfo {
        if isConnected, let info { return info }
        stop()
        attachedToExisting = false
        lastAttachFailure = nil
        var startupSucceeded = false
        defer {
            if !startupSucceeded { _ = stop(closeManagedBrowser: isolatedProfileURL == nil) }
        }

        let browser = try findBrowser()
        browserName = browser.name
        let profile = try browserProfile()
        let profileOwner = verifiedManagedBrowserProfilePID(profile)
        if attachExisting, profileOwner != nil {
            if let existing = try await attachToExistingBrowser(initialURL: initialURL, diagnoseProbeFailure: true) {
                attachedToExisting = true
                startupSucceeded = true
                return existing
            }
            if let owner = verifiedManagedBrowserProfilePID(profile) {
                onDiagnostic?("专用浏览器无法接管，正在只重启专用实例（进程 \(owner)）")
                guard await terminateManagedBrowser(pid: owner, profile: profile, timeout: 5) else {
                    throw BrowserControllerError.profileInUse(owner)
                }
            }
        } else if let owner = profileOwner {
            throw BrowserControllerError.profileInUse(owner)
        }
        browserName = browser.name
        browserPort = try await reservePort()
        let process = Process()
        process.executableURL = browser.executable
        process.arguments = (launchHeadless ? ["--headless=new"] : []) + [
            "--remote-debugging-port=\(browserPort)",
            "--remote-allow-origins=http://127.0.0.1:\(browserPort)",
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            initialURL?.absoluteString ?? "about:blank"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw BrowserControllerError.launchFailed(error.localizedDescription)
        }
        self.process = process

        try await waitForDevTools()
        let version = try await httpJSON(path: "/json/version") as? [String: Any]
        let browserWebSocketURL = version?["webSocketDebuggerUrl"] as? String
        let value = try await connectToAvailablePage(initialURL: initialURL, browserWebSocketURL: browserWebSocketURL)
        startupSucceeded = true
        return value
    }

    private func attachToExistingBrowser(initialURL: URL?, diagnoseProbeFailure: Bool) async throws -> ManagedBrowserInfo? {
        var primaryProbeError: String?
        // Do not attach an unrelated Chrome merely because it has a debugging
        // port in our range. Resolve the port of the profile's actual owner.
        let profile = try browserProfile()
        guard let owner = verifiedManagedBrowserProfilePID(profile), let ownedPort = Self.debugPort(pid: owner, profile: profile) else { return nil }
        for port in [ownedPort] {
            browserPort = port
            let version: [String: Any]
            do {
                guard let value = try await httpJSON(path: "/json/version") as? [String: Any] else { continue }
                version = value
            } catch {
                if port == 9229 { primaryProbeError = error.localizedDescription }
                continue
            }
            guard let browser = version["Browser"] as? String,
                  browser.lowercased().contains("edg") || browser.lowercased().contains("chrome") else {
                continue
            }
            browserName = browser.lowercased().contains("edg") ? "Microsoft Edge" : "Google Chrome"
            do {
                let browserWebSocketURL = version["webSocketDebuggerUrl"] as? String
                let connected = try await connectToAvailablePage(initialURL: initialURL, browserWebSocketURL: browserWebSocketURL)
                lastAttachFailure = nil
                return connected
            } catch {
                let message = "端口 \(port) 已发现浏览器，但接管页面失败：\(error.localizedDescription)"
                if lastAttachFailure != message { onDiagnostic?(message) }
                lastAttachFailure = message
                stop()
            }
        }
        if diagnoseProbeFailure, let primaryProbeError {
            let message = "端口 9229 的控制接口暂不可用：\(primaryProbeError)"
            if lastAttachFailure != message { onDiagnostic?(message) }
            lastAttachFailure = message
        }
        return nil
    }

    private static func debugPort(pid: Int32, profile: URL) -> Int? {
        guard let command = browserCommandLine(pid: pid),
              command.contains("--user-data-dir=\(profile.path)"),
              let range = command.range(of:"--remote-debugging-port=[0-9]+",options:.regularExpression),
              let port = Int(command[range].split(separator:"=").last ?? ""), (9229...9249).contains(port) else { return nil }
        return port
    }

    private func connectToAvailablePage(initialURL: URL?, browserWebSocketURL: String? = nil) async throws -> ManagedBrowserInfo {
        let targets = try await listTargets()
        let pages = targets.filter { ($0["type"] as? String) == "page" }
        hasOpenBagOrCheckoutPage = pages.contains { page in
            guard let raw = page["url"] as? String, let url = URL(string: raw),
                  let host = url.host?.lowercased(), host == "apple.com.cn" || host.hasSuffix(".apple.com.cn") else { return false }
            return url.path.lowercased().hasPrefix("/shop/bag") || url.path.lowercased().hasPrefix("/shop/checkout")
        }
        var target: [String: Any]?
        if let initialURL {
            target = pages.first(where: { isManagedAccountPage($0["url"] as? String ?? "") })
            if target == nil, let blank = pages.first(where: { ($0["url"] as? String) == "about:blank" }), pages.count == 1 {
                target = blank
            }
            if target == nil {
                let version = try await httpJSON(path: "/json/version") as? [String: Any]
                let wsURL = browserWebSocketURL ?? version?["webSocketDebuggerUrl"] as? String
                guard let wsURL else { throw BrowserControllerError.websocketUnavailable }
                let createdTargetID = try await createPageTarget(url: initialURL, browserWebSocketURL: wsURL)
                target = try await waitForPageTarget(createdTargetID)
            }
        } else {
            target = pages.first(where: { page in
                guard let value = page["url"] as? String else { return false }
                return !value.hasPrefix("edge://") && !value.hasPrefix("chrome://") && !value.hasPrefix("devtools://")
            }) ?? pages.first
        }
        guard let target else {
            throw BrowserControllerError.noPageTarget
        }
        guard let wsURL = target["webSocketDebuggerUrl"] as? String,
              let url = target["url"] as? String,
              let id = target["id"] as? String else {
            throw BrowserControllerError.websocketUnavailable
        }
        targetID = id
        targetURL = url
        try await connectWebSocket(URL(string: wsURL))
        let result = try await command("Runtime.evaluate", [
            "expression": "location.href",
            "returnByValue": true,
            "awaitPromise": true
        ])
        let confirmedURL = stringResult(result) ?? targetURL
        targetURL = confirmedURL
        if let initialURL, targetURL == "about:blank" {
            _ = try await command("Page.enable")
            _ = try await command("Page.navigate", ["url": initialURL.absoluteString])
            targetURL = initialURL.absoluteString
        }
        isConnected = true
        let value = ManagedBrowserInfo(browserName: browserName, port: browserPort, targetID: targetID, url: targetURL)
        info = value
        return value
    }

    private func createPageTarget(url: URL, browserWebSocketURL: String) async throws -> String {
        let wasAttachedToExisting = attachedToExisting
        try await connectWebSocket(URL(string: browserWebSocketURL), enableRuntime: false)
        do {
            let response = try await command("Target.createTarget", ["url": url.absoluteString])
            guard let result = response["result"] as? [String: Any], let targetID = result["targetId"] as? String else {
                throw BrowserControllerError.noPageTarget
            }
            stop()
            attachedToExisting = wasAttachedToExisting
            return targetID
        } catch {
            stop()
            attachedToExisting = wasAttachedToExisting
            throw error
        }
    }

    func ensureManagedAccountPage(_ url: URL) async throws -> ManagedBrowserInfo {
        try requireConnection()
        let currentURL = try await evaluate("location.href") as? String ?? targetURL
        if isManagedAccountPage(currentURL), let info {
            targetURL = currentURL
            let updated = ManagedBrowserInfo(browserName: info.browserName, port: info.port, targetID: info.targetID, url: currentURL)
            self.info = updated
            return updated
        }
        let version = try await httpJSON(path: "/json/version") as? [String: Any]
        guard let browserWebSocketURL = version?["webSocketDebuggerUrl"] as? String else {
            throw BrowserControllerError.websocketUnavailable
        }
        let wasAttachedToExisting = attachedToExisting
        stop()
        attachedToExisting = wasAttachedToExisting
        let updated = try await connectToAvailablePage(initialURL: url, browserWebSocketURL: browserWebSocketURL)
        attachedToExisting = wasAttachedToExisting
        return updated
    }

    private func waitForPageTarget(_ targetID: String, timeout: TimeInterval = 8) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let target = try await listTargets().first(where: { $0["id"] as? String == targetID && ($0["type"] as? String) == "page" }) {
                return target
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserControllerError.noPageTarget
    }

    private func terminateManagedBrowser(pid: Int32, profile: URL, timeout: TimeInterval) async -> Bool {
        guard verifiedManagedBrowserProfilePID(profile) == pid else { return true }
        if let process, process.processIdentifier == pid, process.isRunning {
            process.terminate()
        } else {
            guard Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH else { return false }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if verifiedManagedBrowserProfilePID(profile) != pid { return true }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return false }
        }
        return verifiedManagedBrowserProfilePID(profile) != pid
    }

    @discardableResult
    func stop(closeManagedBrowser: Bool = false) -> Bool {
        let profile = try? browserProfile()
        let owner = profile.flatMap(verifiedManagedBrowserProfilePID)
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        pending.values.forEach { $0.continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
        isConnected = false
        lastDisconnectReason = nil
        attachedToExisting = false
        info = nil
        targetID = ""
        targetURL = ""
        if isolatedProfileURL != nil, let process, process.isRunning {
            process.terminate()
            self.process = nil
            return true
        }
        guard closeManagedBrowser, let profile else { return true }
        // The executable we launched can be a short-lived wrapper on some
        // Chromium builds. Only treat our Process handle as the profile owner
        // when its PID matches the verified SingletonLock owner.
        let processToClose = process.flatMap { candidate in
            candidate.isRunning && (owner == nil || candidate.processIdentifier == owner) ? candidate : nil
        }
        let pidToClose = owner ?? processToClose?.processIdentifier
        guard let pidToClose else { self.process = nil; return true }
        if let processToClose {
            processToClose.terminate()
        } else {
            guard verifiedManagedBrowserProfilePID(profile) == pidToClose else { self.process = nil; return true }
            if Darwin.kill(pidToClose, SIGTERM) != 0 && errno != ESRCH { return false }
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let profileOwner = verifiedManagedBrowserProfilePID(profile)
            let processStillRunning = processToClose?.isRunning == true
            if profileOwner != pidToClose && !processStillRunning {
                self.process = nil
                return true
            }
            usleep(100_000)
        }
        self.process = nil
        return verifiedManagedBrowserProfilePID(profile) != pidToClose && processToClose?.isRunning != true
    }

    func reconnectToTarget() async throws {
        guard !targetID.isEmpty else { throw BrowserControllerError.noPageTarget }
        let originalID = targetID
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        pending.values.forEach { $0.continuation.resume(throwing: CancellationError()) }
        pending.removeAll(); socket = nil; isConnected = false
        let pages = try await listTargets()
        guard let page = pages.first(where: { $0["id"] as? String == originalID }),
              let ws = page["webSocketDebuggerUrl"] as? String else { throw BrowserControllerError.noPageTarget }
        try await connectWebSocket(URL(string: ws))
        isConnected = true
    }

    func navigate(_ url: URL) async throws {
        try requireConnection()
        _ = try await command("Page.enable")
        _ = try await command("Page.navigate", ["url": url.absoluteString])
        noteObservedPageURL(url.absoluteString)
    }

    func noteObservedPageURL(_ rawURL: String) {
        targetURL = rawURL
        if let info {
            self.info = ManagedBrowserInfo(browserName: info.browserName, port: info.port, targetID: info.targetID, url: rawURL)
        }
        guard let url = URL(string: rawURL), let host = url.host?.lowercased(),
              host == "apple.com.cn" || host.hasSuffix(".apple.com.cn") else { return }
        let path = url.path.lowercased()
        if path.hasPrefix("/shop/bag") || path.hasPrefix("/shop/checkout") {
            hasOpenBagOrCheckoutPage = true
        }
    }

    func bringToFront() async throws {
        try requireConnection()
        _ = try await command("Page.bringToFront")
    }

    /// Activate only the browser process that owns the managed profile. Looking
    /// up an Edge/Chrome instance by bundle identifier can surface the user's
    /// regular browser instead of this dedicated checkout session.
    @discardableResult
    func activateManagedBrowserWindow() -> Bool {
        guard let profile = try? browserProfile(),
              let pid = verifiedManagedBrowserProfilePID(profile),
              let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated else { return false }
        return application.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }

    /// Ask the dedicated browser's own password manager to fill Apple's
    /// first-party sign-in form. The password never leaves the renderer and is
    /// never returned to Swift or written to logs. We submit only after the
    /// page itself confirms that the field became non-empty.
    func attemptSavedAppleLogin() async throws -> String {
        try requireConnection()
        let topURL = try await evaluate("location.href") as? String ?? ""
        guard let top = URL(string: topURL),
              top.scheme == "https",
              top.host == "www.apple.com.cn" || top.host?.range(of: #"^secure\d*\.www\.apple\.com\.cn$"#, options: .regularExpression) != nil,
              top.path.lowercased().hasPrefix("/shop/signin") || top.path.lowercased().hasPrefix("/shop/checkout") else {
            return "not_login_page"
        }

        _ = try await command("Page.enable")
        let treeResponse = try await command("Page.getFrameTree")
        guard let root = treeResponse["result"] as? [String: Any],
              let frameTree = root["frameTree"] as? [String: Any] else { return "waiting_for_auth_frame" }
        let frames = Self.frames(in: frameTree)
        guard let mainFrameID = frames.first(where: { ($0["parentId"] as? String) == nil })?["id"] as? String,
              let authFrame = frames.first(where: {
                  guard let raw = $0["url"] as? String, let url = URL(string: raw) else { return false }
                  return ($0["parentId"] as? String) == mainFrameID && url.host?.lowercased() == "idmsa.apple.com.cn" && url.path.lowercased().contains("/appleauth/auth/authorize/")
              }),
              let frameID = authFrame["id"] as? String,
              let loaderID = authFrame["loaderId"] as? String else { return "waiting_for_auth_frame" }

        let attemptKey = "\(top.host ?? "")\(top.path)|\(loaderID)"
        if savedLoginAttemptKey == attemptKey { return savedLoginAttemptResult.isEmpty ? "already_attempted" : savedLoginAttemptResult }

        let worldResponse = try await command("Page.createIsolatedWorld", ["frameId": frameID, "worldName": "AppleStoreAssistantLogin"])
        guard let world = worldResponse["result"] as? [String: Any],
              let contextID = world["executionContextId"] as? Int else { return "waiting_for_auth_frame" }

        let initial = try await evaluateInContext("""
        (() => {
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const body = (document.body?.innerText || '').replace(/\\s+/g, ' ');
          if (/验证码|安全验证|验证你的身份|验证您的身份|verify your identity/i.test(body)) return {state:'challenge'};
          if (window.__asaSavedAppleLoginSubmitted) return {state:'already_submitted'};
          const passwords = [...document.querySelectorAll('input[type="password"]')].filter(visible);
          const users = [...document.querySelectorAll('input')].filter(e => visible(e) && (e.autocomplete === 'username' || e.type === 'email' || /user|account|apple.?id/i.test(e.name || e.id)));
          if (passwords.length !== 1 || users.length !== 1 || !String(users[0].value || '').trim()) return {state:'form_not_ready'};
          window.__asaExpectedAppleLoginAccount = String(users[0].value || '').trim();
          const r = users[0].getBoundingClientRect();
          return {state:passwords[0].value ? 'password_filled' : 'password_empty', usernameX:r.left + r.width/2, usernameY:r.top + r.height/2};
        })()
        """, contextID: contextID) as? [String: Any] ?? [:]
        let initialState = initial["state"] as? String ?? "unknown"
        if initialState == "challenge" { return "challenge" }
        if initialState == "already_submitted" { return "already_submitted" }
        if initialState == "form_not_ready" || initialState == "unknown" { return "waiting_for_auth_form" }

        savedLoginAttemptKey = attemptKey
        if initialState == "password_empty" {
            let geometry = try await evaluate("""
            (() => {
              const frames = [...document.querySelectorAll('iframe')];
              const frame = frames.find(e => { try { return new URL(e.src, location.href).hostname.toLowerCase() === 'idmsa.apple.com.cn'; } catch { return false; } });
              if (!frame) return null;
              const r = frame.getBoundingClientRect();
              return {x:r.left + frame.clientLeft, y:r.top + frame.clientTop};
            })()
            """) as? [String: Any]
            guard let geometry,
                  let frameX = geometry["x"] as? Double,
                  let frameY = geometry["y"] as? Double,
                  let usernameX = initial["usernameX"] as? Double,
                  let usernameY = initial["usernameY"] as? Double else {
                savedLoginAttemptResult = "password_unavailable"
                onDiagnostic?("Apple 登录表单已加载，但专用 Edge 没有显示可用的已保存密码；未提交空密码")
                return savedLoginAttemptResult
            }

            // Cross-origin sign-in frames wait for an explicit credential
            // choice. Open Edge's saved-password suggestions from the username
            // field; focusing the password field alone may not show them.
            // First activate this exact tab and its verified profile owner.
            _ = try await command("Page.bringToFront")
            guard activateManagedBrowserWindow() else {
                savedLoginAttemptResult = "browser_activation_failed"
                onDiagnostic?("无法将专用浏览器登录页置前；未触发凭据或提交登录")
                return savedLoginAttemptResult
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            onDiagnostic?("专用浏览器登录页已置前，正在触发 Edge 已保存凭据")

            _ = try await evaluateInContext("""
            (() => {
              const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
              if (!window.__asaLoginKeyGuard) {
                window.__asaLoginKeyGuard = event => {
                  if (event.key === 'Enter') { event.preventDefault(); event.stopImmediatePropagation(); }
                };
                window.addEventListener('keydown', window.__asaLoginKeyGuard, true);
              }
              if (!window.__asaLoginSubmitGuard) {
                window.__asaLoginSubmitGuard = event => { event.preventDefault(); event.stopImmediatePropagation(); };
                document.addEventListener('submit', window.__asaLoginSubmitGuard, true);
              }
              window.clearTimeout(window.__asaLoginGuardTimer);
              window.__asaLoginGuardTimer = window.setTimeout(() => {
                if (window.__asaLoginKeyGuard) window.removeEventListener('keydown', window.__asaLoginKeyGuard, true);
                if (window.__asaLoginSubmitGuard) document.removeEventListener('submit', window.__asaLoginSubmitGuard, true);
                window.__asaLoginKeyGuard = null; window.__asaLoginSubmitGuard = null;
              }, 3000);
              const username = [...document.querySelectorAll('input')].find(e => visible(e) && (e.autocomplete === 'username' || e.type === 'email' || /user|account|apple.?id/i.test(e.name || e.id)));
              username?.focus();
              return true;
            })()
            """, contextID: contextID)
            let x = frameX + usernameX
            let y = frameY + usernameY
            do {
                _ = try await command("Input.dispatchMouseEvent", ["type":"mouseMoved", "x":x, "y":y])
                _ = try await command("Input.dispatchMouseEvent", ["type":"mousePressed", "x":x, "y":y, "button":"left", "clickCount":1])
                _ = try await command("Input.dispatchMouseEvent", ["type":"mouseReleased", "x":x, "y":y, "button":"left", "clickCount":1])
                try await Task.sleep(nanoseconds: 450_000_000)
                // Edge's native password popup consumes RawKeyDown events in
                // the browser process. A regular CDP keyDown falls through to
                // the page, where the Enter guard correctly blocks submission.
                // On macOS, nativeVirtualKeyCode is also required for Chromium
                // to create an NSEvent and route the key into browser chrome.
                _ = try await command("Input.dispatchKeyEvent", ["type":"rawKeyDown", "key":"ArrowDown", "code":"ArrowDown", "windowsVirtualKeyCode":40, "nativeVirtualKeyCode":125])
                _ = try await command("Input.dispatchKeyEvent", ["type":"keyUp", "key":"ArrowDown", "code":"ArrowDown", "windowsVirtualKeyCode":40, "nativeVirtualKeyCode":125])
                try await Task.sleep(nanoseconds: 250_000_000)
                _ = try await command("Input.dispatchKeyEvent", ["type":"rawKeyDown", "key":"Enter", "code":"Enter", "windowsVirtualKeyCode":13, "nativeVirtualKeyCode":36])
                _ = try await command("Input.dispatchKeyEvent", ["type":"keyUp", "key":"Enter", "code":"Enter", "windowsVirtualKeyCode":13, "nativeVirtualKeyCode":36])
            } catch {
                _ = try? await evaluateInContext("""
                (() => {
                  if (window.__asaLoginKeyGuard) window.removeEventListener('keydown', window.__asaLoginKeyGuard, true);
                  if (window.__asaLoginSubmitGuard) document.removeEventListener('submit', window.__asaLoginSubmitGuard, true);
                  window.__asaLoginKeyGuard = null; window.__asaLoginSubmitGuard = null;
                  return true;
                })()
                """, contextID: contextID)
                throw error
            }
        }

        let submission = try await evaluateInContext("""
        (() => {
          const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const cleanup = () => {
            if (window.__asaLoginKeyGuard) window.removeEventListener('keydown', window.__asaLoginKeyGuard, true);
            if (window.__asaLoginSubmitGuard) document.removeEventListener('submit', window.__asaLoginSubmitGuard, true);
            window.clearTimeout(window.__asaLoginGuardTimer);
            window.__asaLoginGuardTimer = null;
            window.__asaLoginKeyGuard = null;
            window.__asaLoginSubmitGuard = null;
          };
          const body = (document.body?.innerText || '').replace(/\\s+/g, ' ');
          if (/验证码|安全验证|验证你的身份|验证您的身份|verify your identity/i.test(body)) { cleanup(); return {state:'challenge'}; }
          const passwords = [...document.querySelectorAll('input[type="password"]')].filter(visible);
          const users = [...document.querySelectorAll('input')].filter(e => visible(e) && (e.autocomplete === 'username' || e.type === 'email' || /user|account|apple.?id/i.test(e.name || e.id)));
          if (passwords.length !== 1 || users.length !== 1 || !String(users[0].value || '').trim() || !String(passwords[0].value || '').length) { cleanup(); return {state:'password_unavailable'}; }
          const expectedAccount = String(window.__asaExpectedAppleLoginAccount || '').trim();
          if (!expectedAccount || String(users[0].value || '').trim().toLowerCase() !== expectedAccount.toLowerCase()) {
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
            if (setter) setter.call(passwords[0], ''); else passwords[0].value = '';
            passwords[0].dispatchEvent(new Event('input', {bubbles:true}));
            if (expectedAccount) {
              // Preserve the account Apple prefilled; never submit a different
              // account selected from the browser's password suggestions.
              if (setter) setter.call(users[0], expectedAccount); else users[0].value = expectedAccount;
              users[0].dispatchEvent(new Event('input', {bubbles:true}));
              users[0].dispatchEvent(new Event('change', {bubbles:true}));
              cleanup();
              return {state:'credential_mismatch'};
            }
            cleanup();
            return {state:'credential_mismatch'};
          }
          const buttons = [...document.querySelectorAll('button,input[type="submit"]')].filter(visible)
            .filter(e => /^(登录|sign in)$/i.test((e.innerText || e.value || e.getAttribute('aria-label') || '').replace(/\\s+/g,' ').trim()));
          if (buttons.length !== 1 || buttons[0].disabled || buttons[0].getAttribute('aria-disabled') === 'true') { cleanup(); return {state:'login_button_unavailable'}; }
          if (window.__asaSavedAppleLoginSubmitted) { cleanup(); return {state:'already_submitted'}; }
          window.__asaSavedAppleLoginSubmitted = true;
          cleanup();
          buttons[0].click();
          return {state:'submitted'};
        })()
        """, contextID: contextID) as? [String: Any] ?? [:]
        let result = submission["state"] as? String ?? "unknown"
        savedLoginAttemptResult = result
        switch result {
        case "submitted": onDiagnostic?("已通过专用 Edge 已保存凭据提交一次 Apple 登录，等待官网结果")
        case "password_unavailable": onDiagnostic?("Edge 未能自动填充已保存的 Apple 密码；未提交空密码或重复登录")
        case "credential_mismatch": onDiagnostic?("Edge 密码管理器返回的账号与 Apple 当前账号不一致；程序恢复原账号并未提交")
        case "challenge": onDiagnostic?("Apple 登录需要验证码或身份验证，程序已停下等待验证")
        case "login_button_unavailable": onDiagnostic?("Apple 登录表单结构未能安全确认，程序没有提交")
        default: break
        }
        return result
    }

    private static func frames(in node: [String: Any]) -> [[String: Any]] {
        var output: [[String: Any]] = []
        func collect(_ current: [String: Any]) {
            if let frame = current["frame"] as? [String: Any] { output.append(frame) }
            for child in current["childFrames"] as? [[String: Any]] ?? [] { collect(child) }
        }
        collect(node)
        return output
    }

    private func evaluateInContext(_ expression: String, contextID: Int) async throws -> Any? {
        let response = try await command("Runtime.evaluate", [
            "expression": expression,
            "contextId": contextID,
            "returnByValue": true,
            "awaitPromise": true
        ])
        guard let envelope = response["result"] as? [String: Any],
              let remote = envelope["result"] as? [String: Any] else { return nil }
        if let exception = envelope["exceptionDetails"] as? [String: Any] {
            throw BrowserControllerError.protocolError((exception["text"] as? String) ?? "Apple 登录页脚本执行失败")
        }
        return remote["value"] ?? remote["description"]
    }

    /// Test-only request interception: allowed solely for disposable profiles.
    /// Every page request is fulfilled locally, including unknown URLs (404).
    func installIsolatedFixtures(_ pages: [String: String]) async throws {
        guard isolatedProfileURL != nil else { throw AppError("本地样例只能在隔离测试浏览器中启用") }
        fixturePages = pages
        _ = try await command("Fetch.enable", ["patterns": [["urlPattern": "*", "requestStage": "Request"]]])
    }

    /// Wait until the dedicated page has replaced the previous document.
    /// Runtime.evaluate is otherwise fast enough to observe the old page just
    /// after Page.navigate, which could make a preparation check act on the
    /// wrong product.
    func waitForPage(_ url: URL, maxWaitSeconds: Double = 20) async throws {
        try requireConnection()
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            if let facts = try await evaluate("({href:location.href,ready:document.readyState})") as? [String: Any],
               let href = facts["href"] as? String,
               let current = URL(string: href),
               current.host == url.host,
               current.path == url.path,
               facts["ready"] as? String == "complete" {
                targetURL = href
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserControllerError.protocolError("商品页加载超时：\(url.path)")
    }

    /// One bounded refresh before the quiet interval. Verify a new document was
    /// committed; observing the old document at the same URL is not enough.
    func reloadExpectedProductPage(_ url: URL, maxWaitSeconds: Double = 20) async throws {
        try requireConnection()
        guard let before = try await evaluate("({href:location.href,origin:performance.timeOrigin})") as? [String: Any],
              let href = before["href"] as? String, let current = URL(string: href),
              current.host == url.host, current.path == url.path else {
            throw BrowserControllerError.targetMismatch("刷新前不在已锁定商品页")
        }
        let oldOrigin = before["origin"] as? Double ?? 0
        _ = try await command("Page.enable")
        _ = try await command("Page.reload")
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            if let facts = try? await evaluate("({href:location.href,ready:document.readyState,origin:performance.timeOrigin})") as? [String: Any],
               let loaded = URL(string: facts["href"] as? String ?? ""),
               loaded.host == url.host, loaded.path == url.path,
               facts["ready"] as? String == "complete",
               (facts["origin"] as? Double ?? 0) > oldOrigin {
                targetURL = loaded.absoluteString
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserControllerError.protocolError("刷新后商品页未在限定时间内完成加载")
    }

    /// Performs one non-blocking preparation check in the dedicated browser.
    /// It may select the two common choices, but never clicks Add to Bag.
    func inspectProductPreparation() async throws -> [String: Any] {
        try requireConnection()
        guard let value = try await evaluate(Self.productPreparationExpression()) as? [String: Any] else {
            throw BrowserControllerError.protocolError("商品页没有返回准备状态")
        }
        return value
    }

    /// Waits for Apple's product options to be present, explicitly selects the
    /// no-trade-in and no-AppleCare choices, and confirms that Add to Bag is
    /// enabled. This is deliberately separate from the final click.
    func prepareProductPage(maxWaitSeconds: Double = 20) async throws -> [String: Any] {
        try requireConnection()
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        var last: [String: Any] = [:]
        while Date() < deadline {
            let value = try await inspectProductPreparation()
            last = value
            if value["state"] as? String == "ready" { return value }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let message = last["message"] as? String ?? "商品页准备超时"
        throw BrowserControllerError.protocolError("商品页准备超时：\(message)")
    }

    /// Before release, confirmed choices are enough; Add to Bag may remain disabled.
    func prepareProductOptions(maxWaitSeconds: Double = 20) async throws -> [String: Any] {
        try requireConnection()
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        var last: [String: Any] = [:]
        while Date() < deadline {
            let value = try await inspectProductPreparation()
            last = value
            if value["noTradeIn"] as? Bool == true && value["noAppleCare"] as? Bool == true { return value }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw BrowserControllerError.protocolError("商品选项准备超时：\(last["message"] as? String ?? "页面未就绪")")
    }

    func clickCheckout() async throws -> [String: Any] {
        let expression = """
        (() => {
          const visible = e => !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const text = e => (e.innerText || e.getAttribute('aria-label') || e.value || '').replace(/\\s+/g, ' ').trim();
          const body = (document.body?.innerText || '').replace(/\\s+/g, ' ');
          if (/\\/shop\\/(signin|login)(\\/|$)/i.test(location.pathname) || [...document.querySelectorAll('input[type=password]')].some(visible)) return {state:'manual', message:'专用浏览器需要重新登录'};
          if (/验证你的身份|验证您的身份|输入验证码|安全验证|verify your identity/i.test(body)) return {state:'manual', message:'专用浏览器需要完成身份验证'};
          const candidates = [...document.querySelectorAll('button,a[role=button],[role=button]')]
            .filter(visible)
            .filter(e => /^(结账|结算|去结账|Check Out|Checkout)$/i.test(text(e)));
          if (!candidates.length) return {state:'waiting', message:'等待购物袋中的结账按钮可用'};
          if (candidates.length !== 1) return {state:'manual', message:'找到多个结账按钮，请人工确认'};
          const button = candidates[0];
          if (button.disabled || button.getAttribute('aria-disabled') === 'true') return {state:'waiting', message:'结账按钮暂不可用'};
          button.click();
          return {state:'clicked', message:'已点击结账，等待官方结账页', href:location.href};
        })()
        """
        guard let value = try await evaluate(expression) as? [String: Any] else {
            throw BrowserControllerError.protocolError("页面没有返回结账结果")
        }
        return value
    }

    static func productPreparationExpression() -> String {
        """
        (() => {
          const visible = e => !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const noTradeIn = document.querySelector('\(PurchaseDefaults.noTradeInSelector)');
          if (!noTradeIn) return {state:'waiting', message:'等待不折抵换购选项加载', href:location.href};
          if (noTradeIn.disabled) return {state:'waiting', message:'不折抵换购选项暂不可用', href:location.href};
          if (!noTradeIn.checked) { noTradeIn.click(); return {state:'changed', message:'已选择不折抵换购', href:location.href}; }
          const noAppleCare = document.querySelector('\(PurchaseDefaults.noAppleCareSelector)');
          if (!noAppleCare) return {state:'waiting', message:'已选择不折抵换购，等待 AppleCare 选项加载', href:location.href};
          if (noAppleCare.disabled) return {state:'waiting', message:'AppleCare 选项暂不可用', href:location.href};
          if (!noAppleCare.checked) { noAppleCare.click(); return {state:'changed', message:'已选择不加 AppleCare+ 服务计划', href:location.href}; }
          const addToBag = document.querySelector('\(PurchaseDefaults.addToBagSelector)');
          const continueButton = document.querySelector('button[data-autom="continueButton"]');
          const enabled = e => !!e && visible(e) && !e.disabled && e.getAttribute('aria-disabled') !== 'true';
          const addAvailable = enabled(addToBag);
          const continueAvailable = enabled(continueButton);
          const phase = addAvailable ? 'add' : (continueAvailable ? 'continue' : 'waiting');
          const message = phase === 'add' ? '配置已确认，可以加入购物袋' : (phase === 'continue' ? '配置已确认，可以继续购买流程' : '等待继续或加入购物袋按钮可用');
          return {state:phase === 'waiting' ? 'waiting' : 'ready', phase, message, noTradeIn:true, noAppleCare:true, addAvailable, addPresent:!!addToBag, addDisabled:!!addToBag && !!addToBag.disabled, continuePresent:!!continueButton, continueDisabled:!!continueButton && !!continueButton.disabled, href:location.href};
        })()
        """
    }

    /// The pre-order Continue control is a stage transition, not proof of Add
    /// to Bag. Select the action and click it in one renderer roundtrip.
    func clickProductAction(expectedURL: String) async throws -> [String: Any] {
        guard let value = try await evaluate(try Self.productActionExpression(expectedURL: expectedURL)) as? [String: Any] else {
            throw BrowserControllerError.protocolError("商品页没有返回点击结果")
        }
        return value
    }

    static func productActionExpression(expectedURL: String, actionID: String = "") throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: expectedURL, options: [.fragmentsAllowed])
        guard let expected = String(data: encoded, encoding: .utf8) else {
            throw BrowserControllerError.protocolError("无法编码目标商品页")
        }
        let nonce = String(data: try JSONSerialization.data(withJSONObject: actionID, options: [.fragmentsAllowed]), encoding: .utf8)!
        return """
        (() => {
          const target = new URL(\(expected));
          if (location.host !== target.host || location.pathname !== target.pathname)
            return {state:'mismatch',kind:'none'};
          const visible = e => !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const enabled = e => visible(e) && !e.disabled && e.getAttribute('aria-disabled') !== 'true';
          const add = document.querySelector('\(PurchaseDefaults.addToBagSelector)');
          const next = document.querySelector('button[data-autom="continueButton"]');
          const button = enabled(add) ? add : (enabled(next) ? next : null);
          if (!button) return {state:'disabled',kind:'none'};
          const kind = button === add ? 'add' : 'continue';
          const noTradeIn = document.querySelector('\(PurchaseDefaults.noTradeInSelector)');
          const noAppleCare = document.querySelector('\(PurchaseDefaults.noAppleCareSelector)');
          if ((noTradeIn && !noTradeIn.checked) || (noAppleCare && !noAppleCare.checked))
            return {state:'disabled',kind:'none',reason:'options_changed'};
          if (kind === 'continue' && (!noTradeIn || !noAppleCare))
            return {state:'disabled',kind:'none',reason:'options_missing'};
          // Only a NEW acknowledgement after this action may allow leaving
          // the page. A stale success banner must not cancel an in-flight add.
          if (typeof MutationObserver !== 'undefined') {
            window.__asaFeedbackObserver?.disconnect();
            window.__asaPurchaseFeedback = false;
            const matches = () => [...document.querySelectorAll('[role=dialog],[role=alert],[aria-live]')]
              .filter(e => visible(e) && /已加入购物袋|已添加到购物袋|Added to Bag/i.test(e.innerText || ''));
            const before = new Map(matches().map(e => [e,e.innerText]));
            window.__asaFeedbackObserver = new MutationObserver(() => {
              if(matches().some(e => !before.has(e) || before.get(e) !== e.innerText)) window.__asaPurchaseFeedback = true;
            });
            window.__asaFeedbackObserver.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true});
          }
          window.__asaIssuedAction = {id:\(nonce),kind};
          button.click();
          return {state:'clicked',kind};
        })()
        """
    }

    func waitForContinueProgress(expectedURL: URL, maxWaitSeconds: Double = 4) async throws -> String {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            let facts = try await evaluate("({href:location.href,ready:document.readyState,addReady:(()=>{const e=document.querySelector('button[data-autom=\"add-to-cart\"],button[name=\"add-to-cart\"]');return !!e && !!(e.offsetWidth||e.offsetHeight||e.getClientRects().length) && !e.disabled && e.getAttribute('aria-disabled') !== 'true'})()})") as? [String: Any] ?? [:]
            guard let observed = URL(string: facts["href"] as? String ?? "") else { return "uncertain" }
            if observed.host != expectedURL.host { return "off_target" }
            if observed.path == "/shop/bag" { return "bag" }
            if observed.path != expectedURL.path { return "off_target" }
            if facts["ready"] as? String == "complete", facts["addReady"] as? Bool == true { return "add_ready" }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return "uncertain"
    }

    func evaluate(_ expression: String) async throws -> Any? {
        try requireConnection()
        let result = try await command("Runtime.evaluate", [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true
        ])
        guard let envelope = result["result"] as? [String: Any],
              let remote = envelope["result"] as? [String: Any] else { return nil }
        if let exception = envelope["exceptionDetails"] as? [String: Any] {
            let description = (exception["text"] as? String) ?? "页面脚本执行失败"
            throw BrowserControllerError.protocolError(description)
        }
        let value = remote["value"] ?? remote["description"]
        if let rawURL = value as? String, expression.trimmingCharacters(in: .whitespacesAndNewlines) == "location.href" {
            noteObservedPageURL(rawURL)
        } else if let pageFacts = value as? [String: Any], let rawURL = pageFacts["href"] as? String {
            noteObservedPageURL(rawURL)
        }
        return value
    }

    func click(selector: String, expectedURL: String? = nil) async throws -> [String: Any] {
        let expression = try Self.clickExpression(selector: selector, expectedURL: expectedURL)
        guard let value = try await evaluate(expression) as? [String: Any] else {
            throw BrowserControllerError.protocolError("页面没有返回点击结果")
        }
        return value
    }

    static func clickExpression(selector: String, expectedURL: String? = nil) throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: selector, options: [.fragmentsAllowed])
        guard let selectorJSON = String(data: encoded, encoding: .utf8) else {
            throw BrowserControllerError.protocolError("无法编码页面选择器")
        }
        let expectedJSON = String(data: try JSONSerialization.data(withJSONObject: expectedURL ?? "", options: [.fragmentsAllowed]), encoding: .utf8) ?? "\"\""
        let expression = """
        (() => {
          const selector = \(selectorJSON);
          const expected = \(expectedJSON);
          if (expected) {
            const target = new URL(expected);
            if (location.host !== target.host || location.pathname !== target.pathname)
              return {state:'mismatch', message:'当前不是目标商品页', href:location.href};
          }
          const element = document.querySelector(selector);
          if (!element) return {state:'missing', message:'找不到目标元素'};
          if (!(element.offsetWidth || element.offsetHeight || element.getClientRects().length)) return {state:'hidden', message:'目标元素不可见'};
          if (element.disabled || element.getAttribute('aria-disabled') === 'true') return {state:'disabled', message:'目标元素不可用'};
          element.click();
          return {state:'clicked', message:'目标元素已发出点击', href:location.href, eventCount:window.__asaClickCount || 0};
        })()
        """
        return expression
    }

    /// A visible site acknowledgement can end the short settling wait early.
    /// It is not proof that the bag contains the item.
    func waitForAddFeedback(maxWaitSeconds: Double = 4) async throws -> Bool {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            let expression = """
            (() => {
              if (/\\/shop\\/bag(\\/|$)/i.test(location.pathname)) return true;
              return [...document.querySelectorAll('[role=dialog],[role=alert],[aria-live]')]
                .some(e => /已加入购物袋|已添加到购物袋|Added to Bag/i.test(e.innerText || ''));
            })()
            """
            if (try? await evaluate(expression) as? Bool) == true { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func waitForCheckoutTransition(maxWaitSeconds: Double = 4) async throws -> String {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            let href = try await evaluate("location.href") as? String ?? ""
            let status = Self.checkoutTransitionState(href)
            if status != "waiting" { return status }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return "uncertain"
    }

    static func checkoutTransitionState(_ href: String) -> String {
        guard let url = URL(string: href), managedStoreURL(href) else { return "off_target" }
        if isManagedAccountPage(href) { return "manual" }
        if url.path.lowercased() == "/shop/checkout" || url.path.lowercased().hasPrefix("/shop/checkout/") { return "handoff" }
        return url.path == "/shop/bag" ? "waiting" : "off_target"
    }

    /// Fail closed if Apple changes its bag markup or quantity is not explicit.
    func inspectBag(expectedPartNumber: String, requireOfficialLocation: Bool = true) async throws -> [String: Any] {
        let expression = try Self.bagInspectionExpression(expectedPartNumber: expectedPartNumber, requireOfficialLocation: requireOfficialLocation)
        guard let value = try await evaluate(expression) as? [String: Any] else {
            throw BrowserControllerError.protocolError("购物袋没有返回核验结果")
        }
        return value
    }

    static func bagInspectionExpression(expectedPartNumber: String, requireOfficialLocation: Bool = true) throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: expectedPartNumber, options: [.fragmentsAllowed])
        guard let partJSON = String(data: encoded, encoding: .utf8) else {
            throw BrowserControllerError.protocolError("无法编码商品型号")
        }
        let expression = """
        (() => {
          const part = \(partJSON).toLowerCase();
          if (\(requireOfficialLocation ? "true" : "false") && (location.hostname !== 'www.apple.com.cn' || location.pathname !== '/shop/bag'))
            return {state:'unknown', message:'当前不是官方购物袋页'};
          const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const items = [...document.querySelectorAll('[data-autom="bag-item"],.rs-bag-product,.rs-iteminfo')].filter(visible);
          const roots = items.filter(e => !items.some(p => p !== e && p.contains(e)));
          const matches = roots.filter(e => [...e.querySelectorAll('a[href]')].some(a => a.href.toLowerCase().includes('/' + part)) || (e.innerText || '').toLowerCase().includes(part));
          const empty = roots.length === 0 && /你的购物袋中没有商品|你的购物袋是空的|您的购物袋为空|购物袋中暂无商品|Your bag is empty/i.test(document.body?.innerText || '');
          if (empty) return {state:'empty', items:0};
          if (roots.length !== 1 || matches.length !== 1)
            return {state:roots.length > 0 ? 'conflict' : 'unknown', message:'购物袋商品数量或型号无法唯一核验', items:roots.length};
          const quantities = [...matches[0].querySelectorAll('select,input')].filter(e => /quantity/i.test((e.name || '') + ' ' + (e.id || '') + ' ' + (e.getAttribute('data-autom') || '')));
          if (quantities.length !== 1 || String(quantities[0].value) !== '1')
            return {state:quantities.length === 1 ? 'conflict' : 'unknown', message:'购物袋目标商品数量无法确认为 1', items:roots.length};
          return {state:'confirmed', message:'购物袋已确认目标商品及数量 1', items:roots.length};
        })()
        """
        return expression
    }

    func verifyTarget(allowedHosts: Set<String>, expectedPartNumber: String? = nil) async throws -> [String: Any] {
        let expression = """
        (() => {
          const text = document.body ? document.body.innerText : '';
          const buttons = [...document.querySelectorAll('button,a,[role="button"]')]
            .filter(e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length))
            .map(e => ({text:(e.innerText || e.getAttribute('aria-label') || '').trim(), disabled:!!e.disabled}));
          return {href:location.href, title:document.title, text:text.slice(0,2000), buttons};
        })()
        """
        guard let facts = try await evaluate(expression) as? [String: Any] else {
            throw BrowserControllerError.protocolError("页面状态读取失败")
        }
        guard let href = facts["href"] as? String, let host = URL(string: href)?.host,
              allowedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            throw BrowserControllerError.targetMismatch("页面不在允许的官方域名")
        }
        if let expectedPartNumber, !(facts["text"] as? String ?? "").contains(expectedPartNumber) {
            throw BrowserControllerError.targetMismatch("页面没有显示预期型号 \(expectedPartNumber)")
        }
        return facts
    }

    private func requireConnection() throws {
        guard isConnected, socket != nil else { throw BrowserControllerError.websocketUnavailable }
    }

    private func findBrowser() throws -> (name: String, executable: URL) {
        let candidates = [
            ("Microsoft Edge", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
            ("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            ("Chromium", "/Applications/Chromium.app/Contents/MacOS/Chromium")
        ]
        for (name, path) in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return (name, URL(fileURLWithPath: path))
        }
        throw BrowserControllerError.noSupportedBrowser
    }

    private func browserProfile() throws -> URL {
        if let isolatedProfileURL {
            try FileManager.default.createDirectory(at: isolatedProfileURL, withIntermediateDirectories: true)
            return isolatedProfileURL
        }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AppleStoreAssistantNative", isDirectory: true)
            .appendingPathComponent("ManagedBrowserProfile", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func reservePort() async throws -> Int {
        for port in 9229...9249 {
            let url = URL(string: "http://127.0.0.1:\(port)/json/version")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.05
            if (try? await URLSession.shared.data(for: request)) == nil { return port }
        }
        throw BrowserControllerError.launchFailed("没有可用的本机控制端口")
    }

    private func waitForDevTools() async throws {
        // Edge may need more than ten seconds on its first launch while it
        // creates the dedicated profile and starts the renderer.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let _ = try? await httpJSON(path: "/json/version") { return }
            if let process, !process.isRunning {
                throw BrowserControllerError.launchFailed("浏览器进程已退出，控制端口 \(browserPort) 未启动")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserControllerError.devToolsUnavailable
    }

    private func listTargets() async throws -> [[String: Any]] {
        guard let value = try await httpJSON(path: "/json/list") as? [[String: Any]] else {
            throw BrowserControllerError.noPageTarget
        }
        return value
    }

    private func httpJSON(path: String) async throws -> Any {
        let url = URL(string: "http://127.0.0.1:\(browserPort)\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BrowserControllerError.devToolsUnavailable
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func connectWebSocket(_ url: URL?, enableRuntime: Bool = true) async throws {
        guard let url else { throw BrowserControllerError.websocketUnavailable }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        socket = task
        lastDisconnectReason = nil
        task.resume()
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case .string(let value): data = Data(value.utf8)
                    case .data(let value): data = value
                    @unknown default: continue
                    }
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if object["method"] as? String == "Fetch.requestPaused", let pages = self.fixturePages,
                       let params = object["params"] as? [String: Any], let requestID = params["requestId"] as? String,
                       let request = params["request"] as? [String: Any], let url = request["url"] as? String {
                        let html = pages[url]
                        Task { @MainActor in
                            _ = try? await self.command("Fetch.fulfillRequest", ["requestId": requestID,
                                "responseCode": html == nil ? 404 : 200,
                                "responseHeaders": [["name":"Content-Type","value":"text/html; charset=utf-8"]],
                                "body": Data((html ?? "Test fixture not found").utf8).base64EncodedString()])
                        }
                        continue
                    }
                    if let id = object["id"] as? Int, let waiting = self.pending.removeValue(forKey: id) {
                        if let error = object["error"] as? [String: Any] {
                            let message = error["message"] as? String ?? "未知错误"
                            waiting.continuation.resume(throwing: BrowserControllerError.protocolError(message))
                        } else {
                            waiting.continuation.resume(returning: object)
                        }
                    }
                }
            } catch {
                // stop() cancels the old task deliberately. Do not report that
                // cancellation as an unexpected loss of the current connection.
                guard !Task.isCancelled, self.socket === task else { return }
                self.isConnected = false
                let detail = error as NSError
                self.lastDisconnectReason = "\(error.localizedDescription) [\(detail.domain):\(detail.code)]"
                self.pending.values.forEach { $0.continuation.resume(throwing: error) }
                self.pending.removeAll()
            }
        }
        // A short protocol round-trip proves that a page target and socket are live.
        if enableRuntime { _ = try await command("Runtime.enable") }
    }

    private func command(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        try requireConnectionForCommand()
        nextID += 1
        let id = nextID
        var object: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { object["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8), let socket else {
            throw BrowserControllerError.websocketUnavailable
        }
        let cancellation = BrowserCommandCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(continuation: continuation)
                Task { @MainActor in
                    do {
                        guard self.pending[id] != nil else { return }
                        if cancellation.isCancelled { throw CancellationError() }
                        try await socket.send(.string(string))
                    } catch {
                        if let waiting = self.pending.removeValue(forKey: id) {
                            waiting.continuation.resume(throwing: error)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                    let message = "浏览器控制命令超时：\(method)"
                    // A timed-out CDP command may still be in flight. Force the
                    // coordinator to reattach to the same target before its next
                    // read, while preserving the pending purchase checkpoint.
                    self.isConnected = false
                    self.lastDisconnectReason = message
                    waiting.continuation.resume(throwing: BrowserControllerError.protocolError(message))
                }
            }
        }, onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        })
    }

    private func requireConnectionForCommand() throws {
        guard socket != nil else { throw BrowserControllerError.websocketUnavailable }
    }

    private func stringResult(_ object: [String: Any]) -> String? {
        guard let envelope = object["result"] as? [String: Any],
              let remote = envelope["result"] as? [String: Any] else { return nil }
        return remote["value"] as? String
    }
}
