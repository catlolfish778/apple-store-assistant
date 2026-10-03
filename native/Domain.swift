import Foundation
import CryptoKit

struct Option: Codable { let value: String; let label: String }
struct Group: Codable { let key: String; let title: String; let options: [Option] }
struct Variant: Codable {
    let partNumber: String
    let family: String
    let selections: [String: String]
    let label: String
    let url: String
    let price: Double
    let comingSoon: Bool
}
struct Catalog: Codable {
    let source: String
    let title: String
    let groups: [Group]
    let variants: [Variant]
    func resolve(_ selections: [String: String]) -> Variant? {
        let matches = variants.filter { $0.selections == selections }
        return matches.count == 1 ? matches[0] : nil
    }
    var hash: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}
struct Action: Codable {
    var kind: String
    var selector: String = ""
    var label: String
    var host: String = ""
    var path: String = ""
}

// Store directory data is a refreshed snapshot of Apple's public retail list.
// Pickup preferences live separately from ProductPlan: they describe the
// fulfillment location the user wants, not the product variant.
struct AppleStore: Codable, Identifiable {
    let storeNumber: String
    let city: String
    let name: String
    let address: String
    let path: String
    var id: String { storeNumber }
}

struct AppleStoreDirectory: Codable {
    let countryCode: String
    let countryName: String
    let sourceURL: String
    let retrievedAt: String
    let stores: [AppleStore]
}

enum CheckoutPaymentMethod: String, CaseIterable, Codable {
    case alipay
    case wechat

    var title: String {
        switch self {
        case .alipay: return "支付宝"
        case .wechat: return "微信支付"
        }
    }
}

struct PickupSettings: Codable {
    var countryCode = "zh_CN"
    var city = ""
    var preferredStoreNumber = ""
    var autoSelectPreferredStore = false
    var defaultInvoiceType = "personal"
    var autoCompleteCheckout = true
    // Empty for older settings until the user explicitly chooses a method.
    var paymentMethod = ""

    private enum CodingKeys: String, CodingKey { case countryCode, city, preferredStoreNumber, autoSelectPreferredStore, defaultInvoiceType, autoCompleteCheckout, paymentMethod }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        countryCode = try values.decodeIfPresent(String.self, forKey: .countryCode) ?? "zh_CN"
        city = try values.decodeIfPresent(String.self, forKey: .city) ?? ""
        preferredStoreNumber = try values.decodeIfPresent(String.self, forKey: .preferredStoreNumber) ?? ""
        autoSelectPreferredStore = try values.decodeIfPresent(Bool.self, forKey: .autoSelectPreferredStore) ?? false
        defaultInvoiceType = try values.decodeIfPresent(String.self, forKey: .defaultInvoiceType) ?? "personal"
        autoCompleteCheckout = try values.decodeIfPresent(Bool.self, forKey: .autoCompleteCheckout) ?? true
        paymentMethod = try values.decodeIfPresent(String.self, forKey: .paymentMethod) ?? ""
    }
}

// Product plans describe the exact device only. These purchase choices are
// common defaults shared by every product and execution path.
struct PurchaseDefaults {
    static let noTradeInLabel = "不折抵换购"
    static let noAppleCareLabel = "不加 AppleCare+ 服务计划"
    static let noTradeInSelector = "input[data-autom=\"choose-noTradeIn\"],#noTradeIn,input[name=\"tradeupinline\"][value=\"noTradeIn\"]"
    static let noAppleCareSelector = "input[data-autom=\"noapplecare\"],input[name=\"applecare-options\"][data-autom=\"noapplecare\"]"
    static let addToBagSelector = "button[data-autom=\"add-to-cart\"],button[name=\"add-to-cart\"]"
}

func isManagedAccountPage(_ rawURL: String) -> Bool {
    guard let url = URL(string: rawURL), let host = url.host?.lowercased(),
          host == "apple.com.cn" || host.hasSuffix(".apple.com.cn") else { return false }
    let path = url.path.lowercased()
    return path.hasPrefix("/shop/account") || path.hasPrefix("/shop/signin") || path.hasPrefix("/shop/login")
}

func managedStoreURL(_ raw: String) -> Bool {
    guard let u = URL(string: raw), u.scheme == "https", u.user == nil, u.password == nil, u.port == nil,
          let host = u.host?.lowercased() else { return false }
    return host == "www.apple.com.cn" || host.range(of: "^secure[0-9]*\\.www\\.apple\\.com\\.cn$", options: .regularExpression) != nil
}

func defaultActions() -> [Action] { [Action(kind:"configure",label:"确认已选配置"),Action(kind:"add",label:"加入购物袋"),Action(kind:"checkout",label:"进入结账")] }
struct Plan: Codable {
    var id = UUID().uuidString
    var name: String
    var source: String
    var variant: Variant
    var catalogHash: String
    var capturedAt = Date()
    var releaseAt: Date
    var prepareSeconds: Double = 300
    var quietSeconds: Double = 60
    var executionSeconds: Double = 60
    // Optional for compatibility with previously saved plans.
    var recoverStalePage: Bool? = true
    var autoSubmit = false
    var maxTotal: Double = 0
    var actions = defaultActions()
    var version = 1
    func validate(now: Date) throws {
        guard releaseAt > now else { throw AppError("请选择未来的完整日期和时间") }
        guard officialProductURL(variant.url), officialProductURL(source) else { throw AppError("订单包必须使用 Apple 官方商品链接") }
        guard variant.partNumber.range(of: "^[A-Z0-9]+/A$", options: .regularExpression) != nil else { throw AppError("型号编号无效") }
        guard quietSeconds.isFinite, prepareSeconds.isFinite, executionSeconds.isFinite,
              quietSeconds >= 0, prepareSeconds >= quietSeconds, prepareSeconds <= 86400 else { throw AppError("准备时间须大于等于静默时间，且不超过一天") }
        guard executionSeconds >= 5, executionSeconds <= 300 else { throw AppError("执行窗口应在 5–300 秒之间") }
        guard !actions.isEmpty, actions.count <= 12 else { throw AppError("购买步骤应为 1–12 步") }
        if autoSubmit {
            guard maxTotal > 0, maxTotal.isFinite, actions.last?.kind == "submit" else { throw AppError("自动提交需设置价格上限，并在右侧订单确认页采集最终提交按钮") }
        }
        for (i, a) in actions.enumerated() {
            guard ["configure", "add", "checkout", "continue", "submit"].contains(a.kind) else { throw AppError("未知购买步骤") }
            if a.kind == "submit" && i != actions.count - 1 { throw AppError("提交订单必须是最后一步") }
            if ["continue", "submit"].contains(a.kind) {
                guard !a.selector.isEmpty, a.host.hasSuffix(".apple.com.cn") || a.host.hasSuffix(".apple.com") else { throw AppError("购买步骤缺少官方页面来源") }
            }
        }
    }
}

// A late arm still gets one configuration pass inside the quiet interval.
func managedPreparationInterval(remaining: Double, quietSeconds: Double, configurationReady: Bool) -> Double? {
    guard remaining > 0 else { return nil }
    // Observe the already-open page at every 100 ms scheduler tick in the
    // final five seconds. Purchasing still begins at the scheduled instant.
    if remaining <= 5 { return 0.05 }
    return remaining > quietSeconds ? 1.0 : (configurationReady ? nil : 0.2)
}

struct ManagedScheduleTimes {
    let preparationStarts: Date
    let quietStarts: Date
    let executionStarts: Date
    let executionEnds: Date
}

func managedScheduleTimes(releaseAt: Date, prepareSeconds: Double, quietSeconds: Double, executionSeconds: Double) -> ManagedScheduleTimes {
    ManagedScheduleTimes(
        preparationStarts: releaseAt.addingTimeInterval(-prepareSeconds),
        quietStarts: releaseAt.addingTimeInterval(-quietSeconds),
        executionStarts: releaseAt,
        executionEnds: releaseAt.addingTimeInterval(executionSeconds)
    )
}

// A negative DOM click result proves no add-to-bag event was dispatched.
func addAttemptWasNotIssued(_ state: String) -> Bool {
    state == "missing" || state == "disabled" || state == "hidden" || state == "mismatch"
}
struct RunRecord: Codable {
    var id = UUID().uuidString
    var plan: Plan
    var pickupSettings: PickupSettings? = nil
    var state = "armed"
    var step = 0
    var attempted: [Int] = []
    var firedAt: Date?
    var attemptedPath: String?
    var triggerDelayMS: Double?
    var automationPhase: String?
    var pendingAction: String?
    var orderNumber: String?
    var orderCreatedAt: Date?
    var paymentDeadline: Date?
    var updatedAt = Date()
}
// Saved product configurations have no execution schedule. Old Plan JSON is
// compatible: decoding ignores its former timing and automation fields.
struct ProductPlan: Codable {
    var id: String
    var name: String
    var source: String
    var variant: Variant
    var catalogHash: String
    var capturedAt: Date
    var version: Int

    init(_ plan: Plan) {
        id = plan.id; name = plan.name; source = plan.source; variant = plan.variant
        catalogHash = plan.catalogHash; capturedAt = plan.capturedAt; version = plan.version
    }

    init(id: String = UUID().uuidString, name: String, source: String, variant: Variant, catalogHash: String, capturedAt: Date = Date(), version: Int = 1) {
        self.id = id; self.name = name; self.source = source; self.variant = variant
        self.catalogHash = catalogHash; self.capturedAt = capturedAt; self.version = version
    }

    func validate() throws {
        guard officialProductURL(variant.url), officialProductURL(source) else { throw AppError("商品配置必须使用 Apple 官方商品链接") }
        guard variant.partNumber.range(of: "^[A-Z0-9]+/A$", options: .regularExpression) != nil else { throw AppError("型号编号无效") }
    }

    func executionPlan(releaseAt: Date) -> Plan {
        var task = Plan(name: name, source: source, variant: variant, catalogHash: catalogHash, releaseAt: releaseAt)
        task.id = id; task.capturedAt = capturedAt; task.version = version
        return task
    }
}
struct Saved: Codable { var plans: [ProductPlan] = []; var selectedID: String? }

// Kept as a small pure helper so menu-index handling can be regression-tested
// without starting AppKit. Index 0 is the non-plan placeholder.
func planIDForPresetIndex(_ selectedIndex: Int, orderedIDs: [String]) -> String? {
    guard selectedIndex > 0, orderedIDs.indices.contains(selectedIndex - 1) else { return nil }
    return orderedIDs[selectedIndex - 1]
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func officialProductURL(_ raw: String) -> Bool {
    guard let u = URLComponents(string: raw) else { return false }
    return u.scheme == "https" && u.host == "www.apple.com.cn" && u.user == nil && u.password == nil && u.port == nil && u.path.hasPrefix("/shop/") && u.query == nil && u.fragment == nil
}
final class Storage {
    let root: URL
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func write<T: Encodable>(_ value: T, _ file: String) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(value).write(to: root.appendingPathComponent(file), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(file).path)
    }
    func read<T: Decodable>(_ file: String, as type: T.Type) throws -> T? {
        let url = root.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: Data(contentsOf: url))
    }
}
