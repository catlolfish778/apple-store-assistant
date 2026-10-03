# Apple 官方商品数据、配置映射与结账链路边界

> 文档状态：已确认的研究结论与工程设计基线
>
> 最后核验：2026-09-19（中国大陆 Apple Store 页面）
>
> 适用范围：通用 Apple Store 商品的预配置、开售时快速报单和官方结账辅助；不包含自动支付、验证码绕过、多账号、代理轮换或风控规避。

## 0. 核心产品目标

2026-09-19 实现更新：原生 App 已接入官方目录与可见页面按钮执行；用户可显式配置后续步骤及有金额上限的最终提交。当前功能边界与验证证据以 [NATIVE_APP.md](NATIVE_APP.md) 为准。本文其余部分保留早期研究与规划，不表示真实订单全链路已经验收。

本项目的核心不是临时帮用户浏览商品，而是让用户在开售前就把本次要购买的商品和配置全部确定下来，形成一个可校验的“订单包”。开售时尽量跳过型号选择、容量选择、颜色选择、地址填写和付款方式选择等重复环节，直接使用已经准备好的订单包进入官方购买流程。

目标流程：

    用户提前选择任意 Apple 商品
            ↓
    读取官方商品配置并解析 partNumber
            ↓
    保存完整订单包
            ↓
    提前准备登录、配送和唯一付款方式
            ↓
    到开售时间
            ↓
    校验订单包与官网配置仍然一致
            ↓
    直接打开准确商品并快速进入购物袋/结账
            ↓
    完成官方订单提交

“任意商品”表示程序不把产品写死为 iPhone Duo。iPhone Duo 是当前第一个已核验完整配置矩阵的示例，未来应支持用户提供的任何 Apple 官方商品购买页，只要页面能解析出有效的配置和具体变体。

订单包必须在开售前锁定以下内容：

- 商品来源国家/地区和官方购买页；
- 产品系列和动态配置选项；
- 最终 partNumber 和官方商品链接；
- 购买数量；
- 配送或门店取货方案；
- 用户预先选择的账户/浏览器会话；
- 付款方式配置是否已准备好，但不保存支付敏感数据；
- 开售时间和失效策略。

这里的“锁定”是锁定本次购买意图和具体配置，不代表 Apple 提前锁定库存。库存只有在官方结账和订单确认过程中才可能被占用。

## 1. 先说结论

我们真正需要保存的不是“iPhone 17 黑色 256GB”这类营销名称，而是苹果商品目录中一组配置选项最终对应的 partNumber。

    产品系列 + 动态配置选项
            ↓
    苹果官方商品变体
            ↓
    partNumber

例如：

    iPhone 17 + 256GB + 黑色
            ↓
    familyType        = iphone17
    dimensionCapacity = 256gb
    dimensionColor    = black
            ↓
    partNumber        = MG6W4CH/A

partNumber 可以帮助我们跳过页面上的型号、容量、颜色选择步骤，但它不是库存锁定凭证，也不是订单号。加入购物袋也不等于苹果已经为账户保留商品；库存、配送/取货资格、价格和支付状态仍可能在结账时重新确认。

## 2. 官方数据来源

### 2.1 当前确认的商品配置页面

以 iPhone 17 为例：

    https://www.apple.com.cn/shop/buy-iphone/iphone-17

官方链接：

- [Apple 中国大陆 iPhone 购买页](https://www.apple.com.cn/shop/buy-iphone)
- [Apple 中国大陆 iPhone 17 配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-17)
- [按具体配置访问的商品页示例](https://www.apple.com.cn/shop/buy-iphone/iphone-17/MG714CH/A)

### 2.2 数据不是独立的公开 JSON API

当前观察到的配置数据被内嵌在商品页返回的 HTML 中，入口为：

    window.PRODUCT_SELECTION_BOOTSTRAP.productSelectionData

这份数据由商品页面直接使用。它不是我们可以长期依赖的、带版本保证的开发者 API，因此解析器必须：

1. 记录页面来源 URL 和抓取时间；
2. 校验关键字段是否存在；
3. 遇到结构变化时进入 Unknown，不能把异常当成无货；
4. 保存脱敏的本地快照和 schema hash，便于复现问题；
5. 不把登录 Cookie、支付信息或账户数据混入快照。

### 2.3 本次实际观察到的结构

页面中包含以下主要字段：

    sections
    displayValues
    products
    priceDisplayOrder
    labels
    imageDictionary

以 iPhone 17 为例，sections 返回：

    [
      {
        "formFieldName": "dimensionColor",
        "dimension": "dimensionColor",
        "controller": "as.ColorSelectionController"
      },
      {
        "formFieldName": "dimensionCapacity",
        "dimension": "dimensionCapacity",
        "controller": "as.CapacitySelectionController"
      }
    ]

displayValues 负责把页面内部值映射成用户看到的名称：

    {
      "dimensionColor": {
        "black": "黑色",
        "white": "白色",
        "sage": "鼠尾草绿色",
        "lavender": "薰衣草紫色",
        "mistblue": "青雾蓝色"
      },
      "dimensionCapacity": {
        "256gb": "256GB",
        "512gb": "512GB"
      }
    }

容量值的原始文本可能包含 <small>、脚注等 HTML 标记。程序显示给用户时应做安全的 HTML 文本清理，内部仍保存原始值和规范化值。

## 3. 商品配置如何对应到最终变体

products 数组中的每一项代表一个具体的可销售配置。关键字段如下：

| 字段 | 示例 | 用途 |
|---|---|---|
| partNumber | MG6W4CH/A | 最重要的最终商品标识 |
| basePartNumber | MG6W4 | 零件号基础编号 |
| familyType | iphone17 | 产品系列 |
| productLocatorFamily | iphone17 | 产品定位系列 |
| dimensionCapacity | 256gb | 容量内部值 |
| dimensionColor | black | 颜色内部值 |
| fullPrice | mg6w4ch_a | 价格表的引用键 |
| dimensionSteporder | 300 | 页面排序信息 |

例如，解析后的变体可以表示为：

    {
      "partNumber": "MG6W4CH/A",
      "basePartNumber": "MG6W4",
      "familyType": "iphone17",
      "productLocatorFamily": "iphone17",
      "dimensionCapacity": "256gb",
      "dimensionColor": "black",
      "priceRef": "mg6w4ch_a"
    }

价格通常需要通过 displayValues.prices[priceRef] 再解析：

    {
      "product": "MG6W4CH/A",
      "priceCurrency": "CNY",
      "currentPrice": {
        "amount": "RMB 6,799",
        "raw_amount": "6799.00"
      },
      "validProducts": ["MG6W4CH/A"]
    }

不同产品的配置维度不固定。例如 iPhone 16 页面还观察到：

    dimensionScreensize
    dimensionColor
    dimensionCapacity

因此程序不能把配置字段写死为“型号、容量、颜色”，必须按照 sections 动态生成选项组。

### 3.1 iPhone Duo 官方配置矩阵

本项目当前明确的目标产品是 iPhone Duo。核验日期为 2026-09-19。

官方页面：

- [iPhone Duo 产品介绍页](https://www.apple.com.cn/iphone-duo/)
- [iPhone Duo 官方购买页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo)

产品介绍页和购买页是两个不同用途的页面：

- 产品介绍页用于展示产品、颜色和发售说明；
- 购买页包含容量、颜色、价格、具体变体和 partNumber；
- 程序必须以购买页的 productSelectionData 为配置来源；
- 产品介绍页不能直接作为下单配置的唯一来源。

官方购买页当前显示：10 月 16 日晚 8 点接受预购、10 月 23 日发售，并注明机型将在获得批准后发售。[官方 iPhone Duo 购买页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo)

#### 配置选项

这里用户所说的“内存”实际对应苹果字段 dimensionCapacity，即存储容量，不是运行内存 RAM。

| 内部值 | 用户显示 |
|---|---|
| 256gb | 256GB |
| 512gb | 512GB |
| 1tb | 1TB |
| 2tb | 2TB |

颜色只有两个：

| 内部值 | 用户显示 |
|---|---|
| nightsky | 夜空色 |
| starwhite | 星光白色 |

当前 iPhone Duo 的配置组为：

    dimensionColor
    dimensionCapacity

当前官方配置矩阵共有 8 个有效变体：

| 容量 | 颜色 | partNumber | 价格 | 官方配置页 |
|---|---|---|---:|---|
| 256GB | 夜空色 | MK2N4CH/A | RMB 15,999 | [配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2n4ch/a) |
| 256GB | 星光白色 | MK2M4CH/A | RMB 15,999 | [配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2m4ch/a) |
| 512GB | 夜空色 | MK2Q4CH/A | RMB 17,999 | [配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2q4ch/a) |
| 512GB | 星光白色 | MK2P4CH/A | RMB 17,999 | [配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2p4ch/a) |
| 1TB | 夜空色 | MK2U4CH/A | RMB 21,499 | [配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2u4ch/a) |
| 1TB | 星光白色 | MK2T4CH/A | RMB 21,499 | [配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2t4ch/a) |
| 2TB | 夜空色 | MK2W4CH/A | RMB 26,499 | [配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2w4ch/a) |
| 2TB | 星光白色 | MK2V4CH/A | RMB 26,499 | [配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2v4ch/a) |

#### iPhone Duo 变体样例

以 1TB 夜空色为例：

    {
      "familyType": "iphoneduo",
      "productLocatorFamily": "iphoneduo",
      "dimensionCapacity": "1tb",
      "dimensionColor": "nightsky",
      "partNumber": "MK2U4CH/A",
      "basePartNumber": "MK2U4",
      "productUrl": "https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2u4ch/a",
      "priceCurrency": "CNY",
      "priceAmount": "21499.00",
      "comingSoon": true,
      "getReady": false
    }

以 1TB 星光白色为例：

    {
      "familyType": "iphoneduo",
      "dimensionCapacity": "1tb",
      "dimensionColor": "starwhite",
      "partNumber": "MK2T4CH/A",
      "basePartNumber": "MK2T4",
      "productUrl": "https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2t4ch/a",
      "priceCurrency": "CNY",
      "priceAmount": "21499.00",
      "comingSoon": true,
      "getReady": false
    }

当前 comingSoon 为 true、getReady 为 false，说明官方已经公开了配置矩阵和价格，但仍处于预售/发售准备状态。这个状态不能当作库存，也不能当作已锁定商品。

#### App 选择器要求

App 中应按以下顺序生成 iPhone Duo 预设：

    产品：iPhone Duo
    存储容量：256GB / 512GB / 1TB / 2TB
    颜色：夜空色 / 星光白色
    数量：1

用户选择后立即显示并保存：

    选项组合
    partNumber
    价格
    官方配置链接
    catalogFetchedAt
    catalogHash

如果用户只选择容量而没有选择颜色，程序应把它保存为两个候选变体，而不是擅自选择颜色。例如：

    iphoneduo + 1tb
      ├── nightsky  → MK2U4CH/A
      └── starwhite → MK2T4CH/A

只有在用户明确选择颜色，或者用户明确允许“任一颜色都可以”时，才允许进入抢购预设的 Ready 状态。

## 4. 内部配置模型设计

用户之前提出的内部编码可以保留，但只能作为项目自己的别名，不能直接提交给苹果。

不推荐：

    AA = iPhone 17
    AA-1 = 256GB
    AA-b = 黑色

推荐使用带作用域的配置键：

    catalog:cn:iphone17
    catalog:cn:iphone17:dimensionCapacity:256gb
    catalog:cn:iphone17:dimensionColor:black

原因是 256gb、black 可能在多个产品系列中重复出现，不能做全局唯一 ID。

### 4.1 购买预设建议结构

    {
      "presetId": "iphone17-256-black-cn",
      "market": "cn",
      "catalogUrl": "https://www.apple.com.cn/shop/buy-iphone/iphone-17",
      "familyType": "iphone17",
      "selections": {
        "dimensionCapacity": "256gb",
        "dimensionColor": "black"
      },
      "resolvedVariant": {
        "partNumber": "MG6W4CH/A",
        "productUrl": "https://www.apple.com.cn/shop/buy-iphone/iphone-17/MG6W4CH/A",
        "priceCurrency": "CNY",
        "priceAmount": "6799.00"
      },
      "catalogFetchedAt": "2026-09-19T00:00:00+08:00",
      "catalogHash": "sha256:..."
    }

catalogHash 和 catalogFetchedAt 的作用是：开售时发现苹果页面结构或商品配置发生变化，可以提示用户重新确认，而不是静默使用过期零件号。

### 4.2 通用订单包

为了在开售瞬间尽量跳过重复步骤，配置预设不能只保存商品名称，而应保存一个通用订单包：

    {
      "orderPackageId": "iphoneduo-1tb-nightsky-cn",
      "market": "cn",
      "catalogUrl": "https://www.apple.com.cn/shop/buy-iphone/iphone-duo",
      "familyType": "iphoneduo",
      "selections": {
        "dimensionCapacity": "1tb",
        "dimensionColor": "nightsky"
      },
      "resolvedVariant": {
        "partNumber": "MK2U4CH/A",
        "productUrl": "https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2u4ch/a"
      },
      "quantity": 1,
      "fulfillmentProfile": "default-cn",
      "paymentProfile": "default-single-method",
      "releaseAt": "2026-10-16T20:00:00+08:00",
      "catalogHash": "sha256:...",
      "status": "ready"
    }

其中 fulfillmentProfile 和 paymentProfile 只保存本地引用和准备状态，不保存地址、卡号、Cookie、支付令牌或密码。订单包的作用是让程序知道开售时“报哪一个商品、报多少件、使用哪一个官方配置页”，而不是伪造或重放 Apple 的订单请求。

## 5. 购买链路分层

我们必须区分“发现商品”“加入购物袋”“结账”“支付”四个阶段：

    商品目录解析
        ↓
    配置映射到 partNumber
        ↓
    库存/配送或门店可用性检查
        ↓
    官方页面选择或加入购物袋
        ↓
    结账信息确认
        ↓
    支付与订单提交

### 5.0 开售时的最短可行路径

所有可以提前做的步骤都放到开售前。开售瞬间只保留与商品有效性和订单确认直接相关的步骤：

开售前：

1. 解析官方商品页；
2. 选择商品和全部配置；
3. 解析并保存 partNumber；
4. 确认数量、配送/取货方案和账户会话；
5. 确认唯一付款方式已能在官方页面使用；
6. 可选：提前准备购物袋，但不把它当作库存锁定；
7. 检查订单包状态为 Ready。

开售时：

1. 使用订单包打开准确商品页或准备好的购物袋；
2. 校验商品名称、配置、数量和 partNumber；
3. 进入结账并复用已准备的配送和付款选择；
4. 处理 Apple 要求的最终确认、验证码或银行验证；
5. 只进行一次有明确结果的订单提交；
6. 以订单号和官方确认页面作为成功依据。

程序不应在开售时重新遍历所有商品、重新让用户选择容量和颜色，也不应因为一次未知响应而无限重复提交。

### 5.1 商品目录解析

特点：

- 通常可以在未登录状态读取商品配置页面；
- 得到的是选项、有效变体、价格等目录信息；
- 不代表商品有库存；
- 不代表商品已经被账户锁定。

### 5.2 库存和配送/取货检查

特点：

- 需要根据商品 partNumber、地区和门店/配送条件检查；
- 结果可能是有货、无货或未知；
- HTTP 错误、限流、响应结构变化必须归类为 Unknown；
- 查询结果不是库存件数，也不是库存预留凭证；
- 查询成功后到用户结账之间，库存仍可能被其他订单占用。

### 5.3 购物袋

购物袋是订单准备状态，不等同于库存锁定。苹果帮助页面说明，用户可以保存购物袋并随后继续结账，但最终仍需经过结账和付款流程。[Apple 账户与购物袋说明](https://www.apple.com.cn/shop/help/your_account)

### 5.4 结账和付款

苹果官方购买流程包括查看购物袋、结账、登录、填写配送和付款信息，最后提交订单。[Apple 购物体验](https://www.apple.com.cn/shop/help/shopping_experience)

付款方式还可能跳转到 Apple Pay、支付宝、微信支付、信用卡或分期机构页面。付款信息、验证码、二次验证和风控判断不应由本项目代存或代提交。[Apple 付款与安全性](https://www.apple.com.cn/shop/help/payments)

## 6. 关于“网页下单接口”和参数的确认边界

### 6.1 当前能确认的内容

我们可以确认商品目录页面的数据入口和字段，例如：

    PRODUCT_SELECTION_BOOTSTRAP
    productSelectionData
    sections
    displayValues
    products
    partNumber
    dimensionColor
    dimensionCapacity

这些数据足够完成：

1. 商品目录同步；
2. 动态配置选择器；
3. 用户配置保存；
4. 配置到 partNumber 的解析；
5. 打开准确的商品页面；
6. 在用户确认后辅助进入购物袋或结账页。

### 6.2 当前不能作为稳定依赖的内容

苹果没有为 Apple Store 在线硬件购买流程公开一个供第三方调用、带版本保证的“自动下单 API”。结账阶段的请求通常会依赖当前浏览器会话和订单状态，可能涉及：

- 登录会话和 Cookie；
- 购物袋或订单草稿标识；
- 商品和数量；
- 配送或门店取货信息；
- 地址、联系方式和账户信息；
- 支付方式令牌；
- CSRF、验证码、二次验证和风控状态。

上述是状态类别，不是已确认的固定参数名称。我们不应把某一次浏览器请求的路径和请求体硬编码成自动付款器，因为页面更新、会话变化和风控策略都可能使它失效，也会造成重复订单或账户风险。

### 6.3 允许的验证方式

如果需要了解“从加入购物袋到结账页”的实际时延，可以在用户自己的浏览器中进行一次人工授权测试：

1. 用户本人登录自己的 Apple 账户；
2. 使用普通商品或测试商品走到购物袋/结账页；
3. 只记录请求时间、响应状态、页面阶段和错误类型；
4. 对 Cookie、Authorization、地址、支付令牌和请求体做脱敏或完全不保存；
5. 不提交真实支付，不重复重放请求。

这类测试用于测量正常页面流程，不用于探测、扫描、绕过或重放受保护的内部接口。

## 7. 工程边界和安全原则

Apple 网站使用条款明确限制使用网页机器人、网页采集工具、自动设备或类似方法访问、获取或监控网站内容，也禁止探测或测试网站的安全和身份验证措施。[Apple 网站使用条款](https://www.apple.com.cn/legal/internet-services/terms/site.html)

因此本项目采用以下边界：

### 可以做

- 低频同步官方商品配置页面；
- 把用户选择转换为苹果官方 partNumber；
- 保存本地购买预设和目录快照；
- 检查浏览器是否已由用户登录；
- 打开官方商品页、购物袋或结账页；
- 在用户明确确认后辅助完成页面内选择；
- 对库存结果采用 InStock / OutOfStock / Unknown 三态；
- 在异常时停止并明确提示用户。

### 不做

- 保存 Apple 密码、Cookie、银行卡号、支付密码或支付令牌；
- 自动处理验证码、二次验证或风控挑战；
- 代理轮换、指纹伪装、多账号并发或绕过限流；
- 无限重复提交订单；
- 直接重放隐藏结账接口；
- 自动完成最终支付；
- 宣称购物袋或查询结果可以锁定库存。

## 8. 对现有项目的改造要求

当前项目已经有手工填写 part_number 的购买配置预设。下一步应把它升级为“官方目录驱动预设”：

    官方商品页同步器
            ↓
    ProductSelectionData 解析器
            ↓
    动态选项和有效组合
            ↓
    配置预设解析器
            ↓
    partNumber 校验
            ↓
    库存查询和官方页面辅助

建议增加以下模块：

    apple_store_assistant/catalog/
      apple_product_page.py       # 获取官方商品页
      product_selection_parser.py # 解析 PRODUCT_SELECTION_BOOTSTRAP
      normalizer.py               # 清理 HTML 文本、统一字段
      variant_resolver.py         # 选项组合 → partNumber
      order_package.py            # 保存和校验通用订单包

    apple_store_assistant/browser/
      session_readiness.py        # 只判断用户浏览器是否准备好
      assisted_flow.py             # 打开官方商品页/购物袋/结账页
      release_executor.py          # 到点执行最短官方页面流程

现有库存提供器继续只负责库存状态，不把结账逻辑塞进库存模块。

## 9. 验收标准

目录模块完成后至少满足：

- 能从固定官方商品页解析 sections、displayValues 和 products；
- 能把用户选择的所有维度解析成唯一 partNumber；
- 无效组合不能保存为有效预设；
- 页面结构变化时返回明确的 Unknown/SchemaChanged，不能误报无货；
- 容量、价格等 HTML 文本能安全清理；
- 预设保存来源 URL、更新时间和目录 hash；
- 开售时不需要重新选择型号、容量、颜色、数量、配送和付款方式；
- 开售时能先核对订单包与购物袋商品，防止错误商品被提交；
- 不写入密码、Cookie、支付信息和完整授权头；
- 能打开准确商品页，但最终下单和支付仍由用户确认；
- 测试使用本地固定 HTML fixture，不对苹果生产站点进行高频测试。

## 10. 资料来源和证据等级

### A 级：官方页面直接观察

- [Apple 中国大陆 iPhone 17 配置页](https://www.apple.com.cn/shop/buy-iphone/iphone-17)
- [Apple 中国大陆 iPhone 购买页](https://www.apple.com.cn/shop/buy-iphone)
- [Apple 中国大陆 iPhone Duo 产品介绍页](https://www.apple.com.cn/iphone-duo/)
- [Apple 中国大陆 iPhone Duo 购买页](https://www.apple.com.cn/shop/buy-iphone/iphone-duo)

观察内容：HTML 内嵌的 PRODUCT_SELECTION_BOOTSTRAP.productSelectionData、配置维度、显示值、变体、partNumber、价格引用，以及 comingSoon/getReady 发售状态字段。

### B 级：官方购买帮助和条款

- [购物体验](https://www.apple.com.cn/shop/help/shopping_experience)
- [你的账户](https://www.apple.com.cn/shop/help/your_account)
- [付款与安全性](https://www.apple.com.cn/shop/help/payments)
- [发货与交货](https://www.apple.com.cn/shop/help/shipping_delivery)
- [Apple 网站使用条款](https://www.apple.com.cn/legal/internet-services/terms/site.html)

观察内容：官方购买步骤、账户/购物袋行为、付款方式、欺诈防范和自动化访问边界。

### C 级：本地开源项目源码评估

详见 [REFERENCE_EVALUATION.md](REFERENCE_EVALUATION.md)。这些项目可以作为状态机、退避、错误分类和测试设计参考，但它们不是苹果官方接口文档，也不能证明任何隐藏结账接口长期稳定。

## 11. 当前决策

1. 使用“干净重建 + 选择性吸收开源设计”，不直接 fork 任一项目。
2. 支持任意符合页面结构的 Apple 官方商品，iPhone Duo 作为第一组完整验证样例。
3. 商品配置以苹果官方目录为准，最终落到 partNumber。
4. 开售前形成订单包，开售时执行最短官方页面流程。
5. 目录同步、库存检查、订单包和浏览器结账辅助分层。
6. 不把购物袋当成库存锁定，不承诺订单成功率。
7. 不实现隐藏结账接口重放、风控绕过和自动支付。
