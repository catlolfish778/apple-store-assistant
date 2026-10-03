# 原生购买托管 App 0.3

更新：2026-09-27。当前桌面交付以本文和 native 源码为准；旧 Python/Tk 原型独立保留。

## 使用方式

1. 打开项目根目录的 **Apple Store Assistant.app**。App 会启动或复用自己的专用 Edge/Chrome 浏览器实例，并打开 Apple 账号页；它不会选择或控制用户日常浏览器窗口。
2. 在专用浏览器的 Apple 官方页面登录并完成需要的身份验证，然后选择已保存的计划。需要新建计划时，在“商品与配置”中读取官网规格并保存准确型号。
3. 设置开售日期和时间。默认准备复核 300 秒、静默 60 秒、执行窗口 60 秒；界面会显示对应时刻。
4. 在“取货与结账资料”中配置门店、联系人、发票类型和付款方式。是否保存联系人/发票预设、是否保存身份证件后四位、是否开启结账自动化都由用户选择。
5. 点击**一键托管**。App 检查专用浏览器登录状态和购物袋，准备准确商品页；到设定时间后按计划执行，并在右侧显示进度。
6. 若需要登录或身份验证，在专用浏览器完成；程序会自动继续。需要人工处理或状态无法确认时会暂停，不会因为结果未知而重复提交。

运行期间计划和时间不可更改；可以查看专用浏览器或停止任务。辅助浏览器操作及离线演练收在“辅助操作与演练”中。

### 浏览器与账号

- 实际登录、购物袋和结账流程使用 App 自己的专用 Edge/Chrome 资料目录：`~/Library/Application Support/AppleStoreAssistantNative/ManagedBrowserProfile/`。App 只按该资料目录核实并控制对应浏览器进程，不会接管普通 Edge/Chrome 窗口。正常退出会关闭专用浏览器进程，但保留资料目录和登录状态；用户日常浏览器不受影响。
- Apple 账号在专用浏览器的 Apple 官方页面登录。若该浏览器已保存登录凭据，App 可调用浏览器自带的密码管理器填入凭据；仅在确认账号一致且密码栏已填入后提交一次。App 只检查密码栏是否已填入，不读取密码文本，也不会将密码内容保存或写入 App 日志。
- Cookie 和登录会话留在专用浏览器资料目录中；App 不把它们复制到普通浏览器或任务日志。需要重新登录、验证码或二次验证时，由用户在 Apple 官方页面完成。
- 如需清除专用浏览器的本机登录状态，先退出 App，再删除上述 `ManagedBrowserProfile` 目录。删除后下次启动会重新创建空白资料目录，需要重新登录。

### 联系人、发票与付款资料

- 点击“保存联系人与发票资料”后，联系人及发票预设保存到本机 macOS 钥匙串，设置为本机设备专用，不通过钥匙串同步。可以点击“清除本机保存资料”删除联系人和发票字段；门店、付款方式和默认发票类型等偏好会保留。
- 预设字段包括取货联系人姓名、邮箱、电话、身份证件后四位、个人发票抬头、公司名称和纳税人识别号，以及增值税专用发票所需的公司和银行信息。身份证件后四位默认只保留在当前 App 会话；只有勾选“保存”才会跨次保存。
- 增值税专用发票的条款只有在用户阅读并明确授权、保存预设后，程序才会代为勾选。公司发票是否符合条件、需要哪些字段，以 Apple 当前页面要求为准。
- 付款自动化只支持用户选择的支付宝或微信。付款方式偏好保存在本机运行设置中；App 不保存支付宝/微信登录凭据、支付密码、银行卡号或验证码。增值税专用发票的银行资料是发票预设，保存在 macOS 钥匙串。
- 新增付款方式涉及界面选项、官网付款选项识别、选择状态确认和 Review 核验；代码扩展位置与验收要求见 [ARCHITECTURE.md](ARCHITECTURE.md) 的“付款方式支持与扩展”。

### 订单生成与付款边界

- 购买默认值为准确商品 × 1、不折抵换购、不加 AppleCare+。
- 关闭结账自动化时，App 将结账页面交给用户继续操作。开启后，只有用户已选择支付宝或微信时，App 才会填写已保存的联系人和发票资料、选择付款方式，并核对 Review 页面中的商品、门店、付款方式和总金额。
- 核对通过后，App 最多点击一次 Apple 页面的“立即下单”，等待 Apple 确认生成待付款订单后停止。它不会打开支付页面、点击“现在支付”、发起付款或处理支付验证。
- 缺少资料、页面字段不唯一、Review 信息不匹配或下单结果不明时，App 会停止并提示检查；它不会改选其他资料，也不会重试未知结果的下单动作。
- 进入购物袋不等于库存锁定，待付款订单也不表示付款完成或库存一定保留。App 不承诺库存、订单或购买成功。

## 自动准备与执行

正式逻辑只有一套：ManagedAutomation 协调器经 AutomationBrowser 协议调用专用浏览器。旧的并行 WKWebView 购买执行路径已移除，WKWebView 只保留商品规格读取与诊断。

- 托管后立即首次准备；若提前很久托管，在“准备复核”时间到达时可复查会话和购物袋。
- 购物袋为空时准备商品页；已存在唯一目标型号、数量 1 时，到点复核后直接结账，避免重复加购。
- 购物袋存在其他商品或数量冲突时提示用户调整，并持续复查。程序不删除或修改用户已有商品。
- 配置准备完成后的静默段不主动刷新；最后 5 秒每约 100ms 读取本地页面按钮状态。T0 前不会发出购买点击。
- 可关闭的“开售 5 秒后仍未开放：最多更新一次页面”选项，默认启用。仅在尚未发出任何购买动作、按钮仍不可用时执行一次；已点击“继续”或加购后绝不触发此恢复。它是有限的旧页面恢复尝试，不证明 Apple 页会自动开放，也不保证刷新成功。
- “继续”与真正加购分别处理，只有明确识别下一阶段才继续。点击前原子保存待确认记录，未知结果不重复提交。
- 已发出的动作可在剩余执行窗口内持续观察。旧的“4 秒无反馈就暂停”已移除；页面旧成功提示不能当作本次加购成功。
- 购物袋型号和数量必须明确匹配；结账前在同一次浏览器调用中再次核验，避免切换页面后误点。
- 结账交接须同时满足允许的 Apple 中国商店主机、结账路径、非登录验证状态和可识别的配送/付款/订单摘要内容。它不表示订单成立或付款完成。
- “取货与结账资料”使用独立边框卡片管理门店、取货联系人和发票预设。联系人及发票字段保存在 macOS 钥匙串，不进入 `run.json`、日志或任务录制；身份证件只要求 Apple 页面所需的后四位，且默认不跨次保存。
- 发票默认类型为个人电子发票，也可分别预设公司/其他和增值税专用发票。仅当用户在专票卡片中明确勾选已阅读并授权，程序才会代为勾选 Apple 发票条款。任何必填资料缺失、页面字段不唯一、发票类型不可用或继续按钮结果不明时都会停下，不会改选其他类型或重复点击。
- 在“付款与下单”中只能选择支付宝或微信。程序必须确认选择结果后点击一次“检查订单”；Review 页面付款方式及总金额与预设不符时停止。核对通过后只点击一次“立即下单”，并等待 Apple 显示待付款订单；超时不会重试下单。
- 正常终点是 Apple 确认待付款订单。程序记录订单号和页面显示的付款期限，随后停止；绝不点击“现在支付”，不接触支付宝/微信授权、付款密码或验证码。

## 时间、连接与停止

- 执行截止始终为设定时间 + 执行窗口，登录、自动恢复和重连不会延长。
- App 正常启动时自动接管专用浏览器；健康实例直接复用。旧实例失联时只检查并恢复 App 专用资料目录，不会关闭用户日常使用的 Edge/Chrome。
- 浏览器控制通过专用实例的本机 DevTools 接口完成，不依赖 macOS“自动化”或“辅助功能”权限；首次启动页会说明账号登录位置和密码处理方式。
- 浏览器断连时只重连原标签页，保持已发出动作的待核验状态。不会因结果未知而重新加购。
- 冷启动接管只寻找专用资料目录所属进程的控制端口，不扫描接管无关浏览器。
- 正常退出 App 会关闭专用浏览器实例，但保留专用资料目录和登录数据；用户日常浏览器不受影响。若购物袋或结账页仍打开，退出前会提示确认。运行中退出仍需确认停止；系统空闲防睡眠已启用，合盖/强制睡眠和系统时间变化仍可能使任务失效。
- 点击“停止”取消后续自动操作，不能撤销官网已经收到的操作。App 重启不会自动补发。上次待核验的购买动作存在时，开始新任务前需核对官网结果。
- 正常终点为“待付款”，不显示虚构的“订单完成”。

## 录制与证据

每次任务单独存入 Application Support/AppleStoreAssistantNative/task-recordings/<UUID>/，包括 manifest.json 和 events.jsonl。记录阶段、按钮状态变化、点击类型、T0 调度偏差、相对时刻和核验结果；不保存页面正文、地址、密码、Cookie、卡号或请求正文。它是事件时间线，不是视频，也不能证明 Apple 服务器已锁定库存。

## 本轮验收（2026-09-27）

- 正式协调器 17 个确定性场景：登录后自动继续、购物袋冲突解除、已有商品复用、两阶段购买、继续响应丢失后凭本次动作标记恢复、加购/结账十秒延迟、断连恢复、未知结果不重发、有限刷新、截止时间、持久化失败、取消。
- 隔离无头 Edge 中运行完整正式协调器和正式浏览器适配层：登录自动继续、继续后选项消失、陈旧成功提示、六秒新反馈、购物袋及结账核验。所有页面请求由本地 fixture 拦截，不访问 Apple、不操作真实账号。
- 原生 App 隔离数据目录自测 passed=true；领域、浏览器脚本、任务录制回归通过。
- 新界面检查：计划摘要常显、设置分组、右侧任务进度、运行期间锁定编辑、完成后重新启用。
- 尚未验收：真实开售页面的开放方式、登录后真实购物袋/结账全部变体、Apple 高峰网络与库存响应、从真实开售到待付款订单的完整成功链路，以及实际付款。无法据此估算节省几秒或承诺抢购成功率。

复现全部本轮检查：运行 bash native/test-automation.sh。测试创建临时资料目录；不会复用用户账号。浏览器网络拦截依据 [Chromium Fetch 协议](https://chromedevtools.github.io/devtools-protocol/tot/Fetch/)。

以下为此前测试的历史证据；不得把历史演练等同于真实开售验收。

## 浏览器控制器的第一阶段验收

### 离线定时执行耗时模拟（2026-09-23）

以下命令使用临时隔离的无头 Edge/Chrome 资料目录，在本地模拟“禁用的继续按钮开放 → 继续 → 真正加购按钮出现 → 点击 → 收到页面反馈 → 打开模拟购物袋 → 核验唯一型号与数量 1 → 点击结账”。还验证预开售刷新确实产生新文档，未点击时无加购反馈。不连接已登录的专用浏览器，不访问 Apple，也不产生真实购物袋或订单：

```bash
xcrun swiftc -swift-version 5 -framework AppKit -framework WebKit native/Domain.swift native/BrowserController.swift native/ManagedFlowSimulation.swift -o build/native/managed-flow-simulation
build/native/managed-flow-simulation
```

旧版四轮本机模拟（只有加购按钮）曾测得 T0 后识别可用需 87–113ms、识别至结账点击 35.6–43.5ms。新版「继续 → 加购」离线模拟已通过，但两组模型不同，不应相减得出节省时间。浏览器冷启动/连接应在准备段完成。以上只度量浏览器控制与本地页面开销；模拟没有运行真实 Apple 页面脚本、网络/排队/库存确认和付款，不能推算真实开售耗时或成功率。正式任务录制用于现场逐段验收。

当前版本已经包含本机安全 fixture 自测，不访问 Apple、不登录、不加购物袋、不支付：

```bash
./dist/Apple\ Store\ Assistant\ Native.app/Contents/MacOS/AppleStoreAssistant --browser-self-test
```

该命令会启动专用 Edge/Chrome，锁定 App 自己创建的测试页面，按单调时钟发出 1000 次页面点击，并把结果写入 `~/Library/Application Support/AppleStoreAssistantNative/browser-self-test.json`。最近一次结果为：1000/1000 点击一致，P50 约 1.0ms、P95 约 1.5ms、P99 约 1.9ms、最大约 10.6ms。这个指标只代表本机 App 到已连接页面目标的控制调用，不代表 Apple 网络、库存或下单耗时；真实页面仍需逐步验证。

真实托管的浏览器控制状态和购买动作统一走专用 Edge/Chrome；App 内 WKWebView 仅保留商品规格读取和诊断功能。专用浏览器的登录态、身份验证和购买页属于同一会话。开启结账自动化且完成必要设置后，App 可以在 Apple 官方页面提交一次订单，等待待付款订单确认后停止；它不会打开支付页面或发起实际付款。待付款订单生成不代表库存已保留，真实开售完整链路仍未验收。

## 当前验证证据

- Apple 真实网页：App 内成功加载 iPhone Duo 购买页，读取 8 个变体；夜空色 1TB 对应 MK2U4CH/A，价格读取为 21,499 元。
- Apple 登录入口：App 内到达官方登录页，系统弹出 Touch ID 登录提示；测试没有进行身份授权。
- 真实公开 HTML：保存 iPhone Duo、iPhone 17 及 iPhone 17 精确配置页快照，修复原 Python 解析器不支持 JavaScript 未加引号外层键的缺陷。
- Python：25 项测试，包括两种真实目录结构与 iPhone Duo 全部 8 个配置映射。
- 原生领域测试：来源域名、配置唯一性、过去时间拒绝、自动提交前提、计划保存/恢复、已尝试步骤恢复。
- WebKit：19 项真实浏览器引擎内离线检查，测试公开目录解析、按钮状态、错误型号、数量、多商品、登录/验证码及金额上限。
- 登录诊断：账号页固定为可布局的 App 内 WebKit 容器，共享持久会话，承接官方认证新窗口；记录开始导航、提交、完成、失败、超时和 WebKit 进程终止，避免无提示地无限转圈。
- 会话上下文实验版：账号页和购买页现在复用同一个 WKWebView 实例；账号窗口关闭后再挂回主窗口，保留同一页面上下文。该改动用于验证 Apple Store 541 是否由跨 WebView 会话接收造成。
- 本次登录实测：Apple `idmsa` 的 `signin/init` 和 `signin/complete` 均返回 200，但 Apple Store `/shop/signIn/idms/authx` 返回 541。该结果说明二次认证已完成，失败发生在 Apple Store 会话接收阶段；App 会显示 541 提示，不再伪装成普通加载中。
- 正常浏览器基线：隔离 Edge 中 `idmsa` 二次认证返回 200/204，`secure7.www.apple.com.cn/shop/signIn/idms/authx` 返回 200，随后账号页、`/shop/shld/v2_1/verify.js`、购物袋状态和 `/shop/accounthomex` 均成功。与 App 的 `secure8.../authx` 返回 541 形成明确对照，详见 [BROWSER_LOGIN_BASELINE.md](BROWSER_LOGIN_BASELINE.md)。
- App 中「离线全流程演示」调用与正式托管相同的执行引擎，操作本地测试页；不代表真实库存或支付验收。
- 专用浏览器托管迁移：本地 CDP 导航、页面完成等待、商品页状态检查、加入购物袋、同会话购物袋导航和结账交接均已覆盖；真实 Apple 开售时序和页面变化仍需在不支付的条件下做现场验收。

尚未验证：付费订单成功率、真实开售抢购时延、登录后完整支付链路、所有 Apple 产品页面兼容性。商品进入购物袋不代表库存保留，也不代表存在固定的付款保留时间。

## 本地数据与构建

数据目录：`~/Library/Application Support/AppleStoreAssistantNative/`

- `plans.json`：仅保存商品配置（名称、官方链接、型号、规格和采集元信息），不保存抢购时间或执行参数。保存、另存、导入和切换商品计划不影响当前任务的时间设置。旧格式在 App 启动时备份并迁移。
- 抢购日期、准备/静默/执行窗口在 App 当前任务中设置；点击「一键托管」时校验日期并锁定到 `run.json`，执行以点击时的界面设置为准。
- `run.json`：执行进度和尝试记录。Apple 确认待付款订单后，任务状态会记录订单号和页面显示的付款期限。
- `pickup-settings.json`：门店、发票类型和付款方式等运行偏好；不保存付款账号或支付凭据。
- `ManagedBrowserProfile/`：专用 Edge/Chrome 用户资料目录，包含该浏览器自己的登录会话和 Cookie。正常退出 App 不会删除它；删除后需要在专用浏览器重新登录。用户日常浏览器使用独立资料目录，不会被 App 接管。
- 联系人和发票预设：保存在 macOS 钥匙串，设置为本机设备专用、不通过钥匙串同步。包括联系人与发票信息；身份证件后四位只有勾选保存时才跨次保留，否则只驻留在当前 App 会话。App 的“清除本机保存资料”按钮删除钥匙串中的联系人与发票预设。
- `events.json`：运行日志，不含联系人、发票等表单值。
- `task-recordings/<任务 UUID>/manifest.json` 与 `events.jsonl`：每次托管单独建立的毫秒级事件录制，记录阶段、时间、商品型号、按钮状态、点击类型和核验结果；不记录账号、地址、联系人/发票/付款表单值、Cookie、页面正文或请求内容。手动暂停期间继续保留同一任务录制，停止/交接时关闭；写入失败会在普通日志中告警，不改变购买决策。点击「查看日志与任务录制」可打开数据目录。该录制可用于时间线复盘，**不是屏幕视频**，也不能证明 Apple 服务器已接受订单。
- `demo-run.json` / `demo-result.json`：离线演示结果，和真实任务分开。
- App 不会在 WebKit 与专用 Edge/Chrome 之间复制 Cookie，也不会将 Apple 密码或付款凭据写入上述 JSON。浏览器登录会话仍由专用 Edge/Chrome 资料目录保存。

```bash
bash native/build.sh
xcrun swiftc -swift-version 5 native/Domain.swift native/DomainTests.swift -o build/native/domain-tests
build/native/domain-tests
xcrun swiftc -swift-version 5 native/Domain.swift native/TaskRecording.swift native/TaskRecordingTests.swift -o build/native/task-recording-tests
build/native/task-recording-tests
xcrun swiftc -swift-version 5 -framework AppKit -framework WebKit -framework JavaScriptCore native/Domain.swift native/BrowserController.swift native/BrowserControllerTests.swift -o build/native/browser-controller-tests
build/native/browser-controller-tests
xcrun swiftc -swift-version 5 -framework AppKit -framework WebKit native/BridgeTests.swift -parse-as-library -o build/native/bridge-tests
build/native/bridge-tests
python3 -m unittest discover -s tests -v
```

构建产物：`dist/Apple Store Assistant Native.app`，本机 ad-hoc 签名，尚未 Developer ID 公证。旧 Tk App 保存在 `build/Apple Store Assistant Tk 20260919.app`，旧配置不删除。

技术依据：[WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)、[WebKit 持久存储](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/default())。公开商品来源：[iPhone Duo](https://www.apple.com.cn/shop/buy-iphone/iphone-duo)、[iPhone 17](https://www.apple.com.cn/shop/buy-iphone/iphone-17)。
