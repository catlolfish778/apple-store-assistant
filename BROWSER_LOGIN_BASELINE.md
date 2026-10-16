# 正常浏览器登录基线

日期：2026-09-19。测试方式：隔离的 Microsoft Edge 实例，用户本人在可见窗口中完成账号、密码和二次认证；诊断器只记录脱敏的域名、路径、HTTP 方法、状态码和耗时，不记录请求体、响应体、Cookie 值、请求头值、密码或验证码。

## 结论

正常 Edge 浏览器登录成功，Apple Store 会话已经建立。当前原生 App 的 WKWebView 登录失败不是“没有触发二次认证”，而是 Apple Store 在认证回调阶段对两种运行环境给出了不同结果。

## 关键链路对比

| 阶段 | 正常 Edge | App 内 WKWebView | 判断 |
| --- | --- | --- | --- |
| 二次认证安全码 | `idmsa.apple.com.cn/appleauth/auth/verify/phone/securitycode` → 200 | 同类认证请求 → 200 | 二次认证已触发并完成 |
| 信任设备 | `idmsa.apple.com.cn/appleauth/auth/2sv/trust` → 204 | 已有认证链路完成 | 不是验证码输入问题 |
| Apple Store 会话接收 | `secure7.www.apple.com.cn/shop/signIn/idms/authx` → 200 | `secure8.www.apple.com.cn/shop/signIn/idms/authx` → 541 | 失败边界在 Store 会话接收 |
| 登录后账号页 | `secure7.www.apple.com.cn/shop/account/home` → 200 | 未到达 | 会话未被 Store 接受 |
| 登录后风控脚本 | `/shop/shld/v2_1/verify.js` → 200 | 未观察到成功完成 | 运行环境/会话风控状态不同 |
| 登录后购物袋状态 | `/shop/bag/status` → 200 | 未到达 | 不是购物袋接口的问题 |
| 账号主页数据 | `/shop/accounthomex` → 200，多次 | 未到达 | 正常浏览器已完成登录 |

正常 Edge 的 UA 为 Chromium/Edge；App 当前使用 WKWebView，并设置了 Safari 兼容 UA。除此之外，两次认证回调落到的 Apple Store 节点也不同（`secure7` 与 `secure8`）。目前证据能确定失败边界，但还不能单独证明是 UA、WebKit 环境、节点选择，还是它们的组合导致 541。

## 对工程的影响

继续修补 WKWebView 的登录回调，不能把正常浏览器已经验证成功的会话直接带入 App。更可靠的方案是：

1. App 启动一个独立、可见的 Edge/Chrome 托管配置；
2. 用户在该浏览器窗口中完成登录和二次认证；
3. **目标安全边界：**App 通过本机 CDP 只读取页面状态、导航和脱敏网络状态，不读取密码或 Cookie 值；
4. 后续商品配置、购物袋核验和结账交接都在同一个已认证浏览器页面中执行，避免跨浏览器复制会话；
5. 最终付款、验证码、银行授权仍由用户在浏览器页面中确认。

上面第 3 点是目标边界，不是当前登录实现的完整描述。当前 `native/BrowserController.swift` 会尝试触发 Edge 自带的已保存凭据填充；页面脚本会读取密码栏值来检查是否非空、核对账号并至多提交一次。密码字符串不会作为脚本结果返回原生侧或写入配置/日志，但 App 通过 CDP 控制专用浏览器，因此不能声称它技术上无法接触登录表单或凭据。公开使用前应先移除或隔离这段登录自动化，并重新验证边界。

这样登录和购买使用同一个浏览器会话，避免 WKWebView 541；代价是登录窗口是系统浏览器，而不是完全嵌入 App 的网页视图。若坚持纯 App 内嵌 WebView，当前测试结果不能承诺 Apple Store 会接受该会话。

## 公开项目交叉验证

- [`woke/apple-store`](https://github.com/woke/apple-store) 的公开说明记录了 Apple Shield 在部分 Store 请求上返回 541；它的处理方式是启动干净 Chrome 完成 Apple 的 JavaScript challenge，再使用匹配 macOS Chrome TLS/HTTP/2 指纹的传输重试。该项目明确保持只读，不登录、不改购物袋、不购买。
- [`suversal/apple-store-inventory-monitor`](https://github.com/suversal/apple-store-inventory-monitor) 明确说明 Tauri WebView 和普通 HTTP 客户端不能稳定取得 Apple 库存 JSON，因此改用独立 Chromium 会话，并在同一会话中完成页面校验和查询；遇到 403/541 会冷却，而不是把失败当作无货。
- [`ENCHIGO/apple-pickup-watcher`](https://github.com/ENCHIGO/apple-pickup-watcher) 的说明把加袋、结账和付款留给用户，默认只监控并打开购物袋。这些公开项目没有提供一个可验证的 Apple Store 登录后自动付款实现。

这些资料不能证明 Apple 对所有 WKWebView 都一律拒绝，但与本次 Edge 200 / App 541 的实测方向一致：真实 Chromium 的页面校验和网络指纹更接近 Apple Store 预期环境。

## 诊断工具

脱敏记录器位于 `tools/record_browser_trace.py`。它连接本机 CDP 端口，只输出方法、脱敏 URL、状态和耗时。一次测试产生的原始记录保存在 `/tmp/apple-store-login-diagnostic.trace.jsonl`，未纳入项目源码和版本控制。
