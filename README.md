# Apple Store Assistant

## 当前交付：原生 App 0.2

双击根目录 `Apple Store Assistant.app`。新版使用 Swift + 系统 WebKit，将真实官方商品目录、规格选择、计划保存、账号登录、购物袋与定时执行集中在 App 内，不再依赖 Python 或外部 Chrome。

完整使用方法、自动执行范围、已验证证据与限制见 [NATIVE_APP.md](NATIVE_APP.md)。原生源码在 `native/`，执行 `bash native/build.sh` 构建。下面内容描述的是保留的旧 Python/Tk MVP，不再代表当前桌面版。

## 历史 Python / Tk MVP

本项目是一个本地运行的 Apple Store 商品预配置与开售时购买辅助工具。目标是让用户提前把 Apple 官方商品的精确配置保存为订单包，到点时使用已核验的 `partNumber` 和商品链接，减少重复选择步骤。

当前代码仍是 MVP：离线官方目录解析与 `OrderPackage` 内核、自提库存查询、专用浏览器会话和到点打开官方页面已经可用；桌面端的“目录选择 → 保存订单包 → 页面校验”尚未接入。不要把现有 UI 预设误认为已实现的订单包或库存锁定。

当前版本的边界：

- 查询指定 Apple Store 直营店的自提状态；
- 可保存手工填写的商品、`part_number`、门店和浏览器预设；
- iPhone Duo 是已完成官方目录核验和解析测试的样例，目录驱动选择器正在开发；
- 发现明确有货时发送通知并打开官方商品页或购物袋；
- 不保存 Apple 账号密码、Cookie、银行卡或支付密码；
- 只通过 Apple 官方结账页面操作；用户选择支付宝或微信后，程序可继续核对并创建待付款订单，确认订单后停止；不自动付款，也不处理验证码、二次验证或支付验证；
- 商品配置最终将以 Apple 官方商品页解析出的 `partNumber` 为准；
- 不使用多账号、代理轮换、验证码识别、指纹伪装或其他规避风控手段。

Apple 的网站使用条款可能限制自动化访问。使用前请确认用途和频率符合适用条款；本项目不会保证库存或订单成功。

## 快速开始

macOS 独立 App 可以直接双击运行：

`Apple Store Assistant.app`

它是打包后的原生 `.app`，不会再弹出终端窗口。

开发备用启动器：

`启动苹果抢购助手.command`

桌面版支持商品/门店/时间配置、购买配置预设、专用 Chrome 会话、托管准备模式、账号状态指示器、静默等待和到点打开官方购物袋。用户第一次在专用 Chrome 配置中手动登录 Apple，程序不读取或保存密码、Cookie 或银行卡；最终订单确认和支付仍在 Apple 官方页面完成。详细说明见 [`MAC_APP_README.md`](MAC_APP_README.md)。

```bash
python3 -m apple_store_assistant validate -c config.example.json
python3 -m apple_store_assistant check -c config.example.json --no-open
python3 -m apple_store_assistant run -c config.example.json
```

配置产品时需要填写 Apple 商品页对应的完整 `part_number`，例如 `XXXXXXCH/A`，不能只填写营销名称。门店编号应来自 Apple 商品页的直营店查询结果。

## 配置说明

关于官方商品页数据、配置选项到 `partNumber` 的映射、购物袋不等于库存锁定，以及结账接口的工程边界，见 [APPLE_OFFICIAL_DATA_AND_CHECKOUT_BOUNDARIES.md](APPLE_OFFICIAL_DATA_AND_CHECKOUT_BOUNDARIES.md)。当前能力、缺口和实施顺序见 [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md)。

复制 `config.example.json` 为本地配置，并修改：

- `location`：Apple 自提查询使用的城市/区域/邮编；
- `city`：用于校验返回的门店城市；
- `stores`：门店编号到名称的映射；
- `products`：产品名称、零件号、官方商品页和目标门店；
- `interval_seconds`：轮询间隔，最小 30 秒；
- `start_at`：可选，ISO 8601 计划开始时间；
- `bark_urls`：可选的 HTTPS Bark 地址数组。

示例配置中的零件号是占位符，只用于演示结构，不能直接查询真实产品。

## 测试

```bash
python3 -m unittest discover -s tests -v
python3 -m apple_store_assistant check -c config.example.json --fixture tests/fixtures/available.json --no-open
```

## 开发路线

1. 完成自提库存适配器、三态模型、退避和状态持久化。
2. 增加配置界面和 macOS 菜单栏/托盘体验。
3. 先接入官方目录解析和不可变订单包，再替换手工配置表单。
4. 增加可见浏览器中的订单包核验和受控交接，并在最终确认/支付前停止。
5. 通过固定目录快照和受控页面测试发现结构变化，不以高频请求作为测试方式。
