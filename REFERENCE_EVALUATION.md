# Apple Store 自动购买工具：开源项目评估

评估对象：

- [ENCHIGO/apple-pickup-watcher](https://github.com/ENCHIGO/apple-pickup-watcher)
- [MoshiCoCo/Apple-Monitor](https://github.com/MoshiCoCo/Apple-Monitor)
- [Yofuria/iphone-pickup-monitor](https://github.com/Yofuria/iphone-pickup-monitor)
- [hteen/apple-store-helper](https://github.com/hteen/apple-store-helper)

下载位置：`reference_projects/`。四个仓库均作为只读参考，不直接修改。

## 当前验证结果

| 项目 | 本地验证 | 结论 |
|---|---|---|
| `iphone-pickup-monitor` | Python 3.12，41 个离线测试全部通过 | 可作为可靠性设计参考 |
| `apple-pickup-watcher` | 未编译；项目要求 Rust 1.98，本机为 1.97.1 | 源码和测试体系完整，但需要升级工具链后再验证 |
| `Apple-Monitor` | 未运行；本机没有 Java/Maven | 源码审查 |
| `apple-store-helper` | 未运行；本机没有 Go | 源码审查 |

## 逐项目结论

### 1. apple-pickup-watcher

优点：

- 当前使用 `/shop/retail/pickup-message`，而不是旧的 `fulfillment-messages`。
- 有 `InStock / OutOfStock / Unknown` 三态，失败不能伪装成无货。
- 有请求预算、缓存年龄检查、403/541 退避、同城门店合并查询。
- Rust core、CLI、Tauri 桌面端分层清晰，测试数量和覆盖面最好。
- 配置保存、状态持久化、通知队列和日志设计较完整。

问题和边界：

- GPL-3.0-or-later，直接派生并分发时需要遵守 GPL。
- 包含代理列表和切换机制；新工程不采用这部分，因为它属于规避出口限制的方向。
- 包含 Chrome/TLS/请求特征相关代码；新工程只保留必要的会话和错误处理，不复制伪装或绕过风控的部分。
- 工具链较重，对 MVP 来说开发成本偏高。

结论：最值得借鉴状态机、预算、退避、配置和测试设计，但不直接 fork。

### 2. Apple-Monitor

优点：

- MIT 许可证，复用限制相对少。
- 已有中国大陆、多地区、多型号、门店白名单、Bark 和飞书推送。
- 配置模型和通知链路适合快速做 MVP。

问题：

- 当前源码仍使用 `/shop/fulfillment-messages`。
- 主要判断 `pickupDisplay == available`，没有完整的未知状态体系。
- HTTP 非 200、JSON 结构异常和部分业务错误处理较粗，容易把接口变化当成暂时无货。
- 每个型号之间固定等待，整体轮询节奏不适合作为高可靠底层。
- Maven 配置中默认跳过测试，不能仅凭构建成功判断可靠性。

结论：可参考配置和通知模块；不采用其库存客户端作为最终核心。

### 3. iphone-pickup-monitor

优点：

- Python 标准库实现，依赖少，适合快速验证。
- 使用较新的 `retail/pickup-message` 路径。
- 有 Chrome 页面握手、缓存检查、状态去重、请求合并、403/541 退避。
- 41 个离线测试覆盖库存解析、异常、限流、通知、配置和状态恢复。
- 不读取用户日常浏览器 Cookie，不登录、不下单。

问题和边界：

- 无桌面配置界面。
- 没有下单辅助模块。
- 未在仓库中确认到明确许可证，不能直接复制代码到需要分发的新产品。
- 使用了部分浏览器自动化特征控制；新工程只保留本地可见浏览器辅助，不做风控规避。

结论：最适合作为 Python MVP 的行为和测试参考；代码是否复用要先确认许可证，默认按重新实现处理。

### 4. apple-store-helper

优点：

- 原始项目，包含产品目录、地区、门店和简单桌面界面。
- 有自动打开购物袋的基础流程。

问题：

- 依赖旧的 `fulfillment-messages` 接口。
- 主循环约每 500 毫秒检查一次，容易触发限流。
- 没有可靠的 `Unknown` 状态；请求失败、响应变化和无库存容易混在一起。
- 通知失败可能直接 panic，Bark URL 拼接也缺少严谨编码和重试。
- 无自动化测试。
- GPL-3.0。

结论：只作为历史资料和产品目录参考，不作为新工程基础。

## 新工程建议

采用“干净重建 + 有选择地吸收设计”的方式：

```text
app/
  domain/       库存三态、目标、事件、订单状态
  providers/    Apple 自提查询适配器；未来再加配送适配器
  scheduler/    固定时间启动、单实例锁、暂停和停止
  notifier/     macOS、Bark、飞书/Webhook
  browser/      可见浏览器、商品页和购物袋辅助
  storage/      SQLite、Keychain、运行状态和日志
  ui/           配置界面
```

第一版只做：

1. 产品和门店配置。
2. 30 秒级的保守库存轮询。
3. 有货/无货/未知三态。
4. 403、429、541、缓存过期和结构变化处理。
5. 有货后通知并打开指定商品页或购物袋。
6. 用户在 Apple 官网完成最终确认和支付。

不加入：

- 多账号并发；
- 代理轮换；
- 验证码识别或绕过；
- 指纹伪装；
- 自动支付；
- 无限重试或高频刷新。

## 延迟和可靠性基线

在没有限流、网络正常、电脑保持唤醒的理想情况下，30 秒轮询的库存发现延迟为 0～30 秒，平均约 15 秒；通知通常再增加 1～5 秒。5 秒轮询不代表真实延迟能达到 5 秒，因为 Apple 的接口存在请求预算、缓存和封锁机制。

系统验收指标建议为：

- 查询失败绝不显示为“无货”；
- 同一个库存事件最多通知一次；
- 进程重启后不丢失退避和停止状态；
- 订单辅助最多自动打开一次购物袋；
- 日志中不出现账号密码、Cookie 值、支付信息或 Bark 完整密钥；
- 最终订单成功率不承诺，由库存竞争、Apple 结算和支付风控共同决定。

## 最终选型

当前建议：

- 工程方式：新建项目，不直接 fork。
- MVP 语言：Python 3.12+。
- 库存核心：重新实现 `retail/pickup-message` 适配器，吸收 `iphone-pickup-monitor` 和 `apple-pickup-watcher` 的状态、预算和测试思想。
- UI：先做本地 CLI/轻量界面，稳定后再决定 Tauri。
- MIT 的 `Apple-Monitor` 只借鉴配置和通知思路，不采用其旧库存接口。
- 所有浏览器和购买流程只面向用户自己的 Apple 账户，并在最终提交订单和支付前暂停。
