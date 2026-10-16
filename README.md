# Apple Store Assistant

> 一个独立的 macOS Apple Store 购买准备工具，与 Apple 无关联。

[使用教程](USER_GUIDE.md) · [GPL-3.0 许可证](LICENSE) · [支持项目](SUPPORT.md) · [X：一片雪花](https://x.com/catlolfish778)

## 开源与支持

源码按 **GPL-3.0-only** 开放，可按许可证使用、修改和再分发。欢迎提 Issue、改进文档和提交修复。分发修改版时须遵守 GPL，包括提供相应源码；商业使用同样受该许可证约束，打赏不构成商业授权。

这是我们第一次公开分享这个工具。如果它帮你少做了一些重复操作，欢迎自愿打赏，支持后续维护；Star、反馈问题和分享经验也很有帮助。**无最低金额，源码和功能没有打赏门槛，也不保证抢购成功。**

- 项目动态与联系：[X @catlolfish778](https://x.com/catlolfish778)
- 网络：**BNB Smart Chain 主网（BSC，Chain ID 56）**
- 资产：BNB，或该链的 USDT（Binance-Peg BSC-USD）；代币合约与核对步骤见 [打赏说明](SUPPORT.md)。
- 收款地址：`0x39C46F09b03150AB407b028605CCd80B66ECb0B0`

转账前请核对网络、资产与完整地址；链上打赏不会自动发放安装包、授权或下单服务。

## 当前版本：原生 App 0.3

这个 App 帮你提前选定 Apple 中国官网商品和具体规格，在指定时间通过可见的购买流程减少重复操作。库存由 Apple 实时决定；商品进入购物袋不代表库存已锁定，App 不承诺下单成功。

![购买准备与结账流程示意，非实测录屏](docs/images/purchase-assistant-flow.svg)

原生 App 的完整操作步骤、边界和验证记录见 [NATIVE_APP.md](NATIVE_APP.md)。原生源码在 `native/`，构建命令为 `bash native/build.sh`。

面向使用者的逐步操作、机型计划、取货联系人、发票与支付设置说明见 [USER_GUIDE.md](USER_GUIDE.md)（含流程示意图）。

目前分享源码与构建步骤。没有 Developer ID 签名和 Apple 公证的安装包；`native/build.sh` 只做本机临时签名。建议先阅读教程与下方账号/隐私说明，再自行检查源码并构建。当前构建目标为 Apple Silicon、macOS 13 或以上，需要 Xcode Command Line Tools 和 Microsoft Edge 或 Google Chrome；Intel Mac 尚未适配验证。

## 购买流程

1. 选择或创建商品计划，核对官方商品页、具体规格和型号编号。
2. 在 App 管理的专用 Edge/Chrome 窗口中登录 Apple 账号，并完成 Apple 要求的身份验证。
3. 设置门店、取货联系人、发票资料和开售时间，然后点击“一键托管”。
4. 到设定时间，App 在专用浏览器中按计划准备商品、核对购物袋，并进入 Apple 官方结账页面。
5. 可选择由 App 自动填写已保存的联系人/发票资料，并按用户选择的支付宝或微信核对订单。开启此功能后，App 可以在订单核对页（Review）信息匹配时向 Apple 提交订单，等待 Apple 确认待付款订单后停止。
6. 用户自行完成 Apple 要求的验证码、身份验证及实际付款。App 不进入支付宝/微信付款流程，也不会点击“现在支付”。

购物袋阶段会核对商品与数量；Review 阶段核对付款方式标签和总金额，结果不明确时不会重复提交。**当前 Review 不强制匹配取货门店名称，自动选店可能回退到其他可取货门店，请亲自确认最终门店；需要逐项手动确认时，请关闭结账自动化。**

目前尚未在真实开售中验证从开售到生成待付款订单的完整链路；现有验证主要覆盖离线演练和本地隔离浏览器流程。

## 浏览器与账号

- 真实登录和购买流程使用 App 启动或接管的**专用 Edge/Chrome 配置**，与用户日常浏览器配置分开。App 内的 WebKit 只用于读取商品规格或诊断，不承担真实购买操作。
- Apple 登录在专用浏览器的 Apple 官方页面完成。当前实现会尝试触发 Edge 自带的已保存凭据填充；页面脚本会读取密码栏值来判断是否非空、检查账号是否匹配，再至多提交一次登录。密码字符串不会作为脚本结果返回原生侧，也不会写入配置、任务状态或日志；但 App 能通过本机调试接口控制专用浏览器，因此不应将此实现描述为 App 技术上无法接触登录表单或凭据。当前界面没有关闭这项自动尝试的开关。
- Apple 登录状态和 Cookie 保留在专用浏览器资料目录中，供下次使用；App 不把它们复制到普通浏览器或 App 日志。正常退出会关闭专用浏览器进程，但保留该目录。用户日常使用的 Edge/Chrome 不受影响。
- 若 Apple 要求验证码、二次验证或重新登录，用户需要在专用浏览器中完成。

## 联系人、发票与付款资料

- 点击“保存联系人与发票资料”后，联系人和发票预设保存到本机 macOS 钥匙串，设为本机设备专用，不通过钥匙串同步。可以用“清除本机保存资料”删除联系人和发票字段；门店、付款方式和默认发票类型等偏好会保留。
- 资料可包括取货联系人、邮箱、电话、身份证件后四位、个人发票抬头、公司名称和税号，以及增值税专用发票所需的公司和银行信息。身份证件后四位默认只在当前 App 会话中保留；只有勾选保存后才跨次保留。
- 增值税专用发票条款只有在用户阅读并明确授权后，App 才会代为勾选。Apple 页面资料缺失、字段不明确或条款授权未保存时，自动填写会暂停。
- 付款自动化仅支持用户选择的支付宝或微信。App 保存所选付款方式，不保存支付宝/微信账号、支付密码、银行卡号或验证码；发票资料中的公司银行信息属于发票预设，保存在 macOS 钥匙串。

当前支持方式及未来新增方式所需的代码位置、页面适配和验证要求，见 [架构文档的付款方式扩展说明](ARCHITECTURE.md)。

## 本机数据与隐私

数据目录：`~/Library/Application Support/AppleStoreAssistantNative/`

- 商品计划、任务状态、运行设置和诊断记录保存在本机。任务录制包含执行阶段、时间、商品型号和页面按钮状态，用于复盘操作结果；不保存账号、地址、付款资料、Cookie、页面正文或请求内容。
- Apple 登录会话单独保存在专用浏览器资料目录；联系人和发票预设单独保存在 macOS 钥匙串。
- Apple 确认生成待付款订单后，任务状态会记录订单号和页面显示的付款期限。订单号和付款期限不是付款凭证，也不代表库存已为用户保留。
- 删除 App 数据目录会清除本机保存的计划、任务记录和专用浏览器登录会话；请先退出 App。清除钥匙串中的联系人和发票资料可在 App 中单独操作。

## 使用边界

- 所有购买页面操作均在 Apple 官方页面进行；本工具不会绕过验证码、二次验证、限流或其他风控，也不使用多账号、代理轮换或指纹伪装。
- Apple 页面、库存和结账规则可能变化。使用前请确认自动化访问符合 Apple 适用的网站条款。
- App 在不同阶段核对商品/数量及付款方式/金额；当前 Review 不强制匹配门店名称，请亲自核对最终订单。App 不会锁定库存，也不保证订单或购买成功。
- 创建待付款订单不等于完成付款；最终付款由用户在 Apple 官方流程中自行决定。

## 构建与验证

```bash
bash native/build.sh
bash native/test-automation.sh
```

当前验证范围、未验证事项和演练边界见 [NATIVE_APP.md](NATIVE_APP.md) 与 [native/VALIDATION.md](native/VALIDATION.md)。离线演练和本机模拟不访问 Apple 账号、不创建真实订单，不能用于推断真实开售的时延或成功率。

## 旧版 Python/Tk 与 CLI

仓库仍保留早期 Python/Tk 原型和自提库存查询 CLI。它们与当前原生 App 是不同的旧流程；以下命令只用于旧 CLI，不启动原生托管购买流程：

```bash
python3 -m apple_store_assistant validate -c config.example.json
python3 -m apple_store_assistant check -c config.example.json --no-open
python3 -m apple_store_assistant run -c config.example.json
```

旧 CLI 的配置字段和限制见 [APPLE_OFFICIAL_DATA_AND_CHECKOUT_BOUNDARIES.md](APPLE_OFFICIAL_DATA_AND_CHECKOUT_BOUNDARIES.md)。
