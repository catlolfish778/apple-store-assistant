# 验证记录

## 2026-10-16 源码公开前验收

- `bash native/test-automation.sh` 通过：新增 CheckoutProfile 启动策略测试、正式协调器 17 场景、Domain、BrowserController、TaskRecording、隔离浏览器联调、原生构建和 App 离线自测。
- `python3 -m unittest discover -v` 通过：25 项测试。
- 新增回归测试先复现隔离启动仍调用保存资料读取器的问题，再验证修复后隔离模式不调用读取器，正常启动仍保留资料加载及错误处理。进程采样曾确认旧 App 自测卡在钥匙串 `SecItemCopyMatching`；修复后 App 自测正常完成。
- `--self-test` 与 `--preview` 使用隔离存储，并跳过真实联系人/发票钥匙串资料读取。App 自测仍只演练本地流程；不访问真实 Apple 购物袋或创建订单。
- README 与教程的相对链接、流程 SVG 的 XML 结构检查通过。Git 历史中的 96 个文本版本未命中本次扫描的私钥、常见访问 Token、个人邮箱及用户名目录等模式；这是有限的静态检查，不是独立安全审计。

当前可选结账自动化能够尝试创建待付款订单，实际付款由用户完成。Review 只核对付款方式标签和金额，不强制匹配门店名称。真实开售完整链路、成功率及高峰网络表现仍未验收，旧演练数据不代表这些指标。

## 2026-09-27 一键托管 0.3

`bash native/test-automation.sh` 已通过：正式协调器 17 个确定性场景、DomainTests、BrowserControllerTests、TaskRecordingTests、隔离 Edge 中完整协调器 + 正式浏览器适配层、原生 App 隔离数据自测。

浏览器联调同时验证：按专用 profile 所属进程接管端口、原标签页重连、登录自动继续、继续后配置选项消失、旧成功提示不能触发导航、六秒后新加购提示、唯一目标/数量、结账内容确认。浏览器请求全部由本地 fixture 拦截，不触及真实 Apple 账号或购物袋。原生 App 的 `--self-test` 使用临时数据目录，不覆盖用户计划和任务。

实际界面预览检查了设置分组、常显计划摘要、运行时编辑禁用、演练完成后恢复编辑。付款和实际订单未测试。当前支持的自动化终点是识别官方结账页，不是已提交订单；官网缺失的配送/付款资料仍需用户补齐。

## 0.2 历史验证

日期：2026-09-19；环境：本机 Apple Silicon，Swift 6.2.3，以 Swift 5 模式编译，目标 macOS 13+。

| 验证 | 结果 | 能证明什么 |
| --- | --- | --- |
| 原生 App 编译与本机签名检查 | 通过 | App 可独立启动，不依赖 Python/Chrome |
| Python unittest | 25 项通过 | 旧功能回归、真实公开目录解析及配置映射 |
| DomainTests | 通过 | 域名、配置唯一性、时间、提交条件、计划持久化和尝试恢复 |
| BridgeTests / WKWebView | 19 项通过 | 正式页面桥接代码在浏览器内处理各种状态 |
| --self-test | passed=true，productionEngine=true | 正式执行引擎完成本地页面全流程 |
| 本次自测运行记录 | step=2，attempted=[1,2]，state=handoff | 配置阶段跳过无须点击的步骤，加袋和结账各点击一次 |
| 本次自测本地触发偏差 | 52.657 ms | 仅证明这一次本机定时结果，不是 Apple 接单延迟 |
| 真实官网 UI | 读取 iPhone Duo 8 变体、1TB 夜空色及价格 | 内嵌 WebKit 能读取实际公开配置数据 |
| 账号入口 | 到达官方登录页及 Touch ID 提示 | 登录入口工作；没有完成用户身份授权 |
| 登录回调诊断（本次） | `idmsa` 的 `signin/init`、`signin/complete` 为 200，Apple Store `idms/authx` 为 541；修复版显示 541、支持验证码输入提示、官方新窗口承接和超时提示 | 二次认证已触发并完成，失败点在 Apple Store 会话接收阶段；不再把异常静默表现为无限转圈 |
| 单 WebView 会话实验版 | 编译通过，账号窗口与购买页复用同一 WKWebView 实例；尚待用户重新登录后以新的 `authx` 状态验收 | 排除“两个 WebView 的页面上下文分离”这一 541 候选根因；不能在未重新登录前宣称已修复 |
| 隔离 Edge 正常浏览器基线 | 二次认证 200/204，`secure7.../authx` 200，账号页、风控脚本、购物袋状态及账号主页接口均 200 | 正常浏览器可以建立有效 Store 会话；与 WKWebView 的 541 对照见 `BROWSER_LOGIN_BASELINE.md` |
| 专用浏览器 CDP 本机压力测试 | 1000/1000 次点击一致；P50 1.0ms、P95 1.5ms、P99 1.9ms、最大 10.6ms | App 可启动独立 Edge、锁定目标页面并通过 CDP 发出定时页面动作；不代表 Apple 网络或订单成功 |

不包含真实付费下单、银行授权或抢购成功率。真实结账摘要的 CSS 结构仍需在用户登录后的流程中验收；信息不完整时当前实现会暂停，不盲点最终按钮。

机器可读结果：`build/native/bridge-test-result.json`，以及 Application Support 中的 `demo-result.json` / `demo-run.json`。后续运行会更新这些文件。

复现命令见项目根目录的 `NATIVE_APP.md`。本地正式执行引擎自测应在没有另一个实例运行时，从 App bundle 启动 `--self-test`；浏览器控制器自测使用 `--browser-self-test`，两者成功后自动退出。正常双击不会执行任何购买任务。
