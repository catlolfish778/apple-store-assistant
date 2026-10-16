import Foundation
import Security

enum AppleInvoiceType: String, CaseIterable, Codable {
    case personal
    case company
    case vatSpecial

    var title: String {
        switch self {
        case .personal: return "电子发票 · 个人"
        case .company: return "电子发票 · 公司/其他"
        case .vatSpecial: return "电子发票 · 增值税专用发票"
        }
    }
}

struct SecureCheckoutProfile: Codable, Equatable {
    var surname = ""
    var givenName = ""
    var email = ""
    var phone = ""
    var nationalIDLastFour = ""
    var rememberNationalIDLastFour = false
    var contactNameConfirmed = false

    var personalInvoiceHeader = ""

    var companyName = ""
    var companyTaxpayerID = ""
    var companyHasNoTaxpayerID = false

    var vatCompanyName = ""
    var vatTaxpayerID = ""
    var vatBankName = ""
    var vatBankAccount = ""
    var vatTermsAuthorized = false

    private enum CodingKeys: String, CodingKey {
        case surname, givenName, email, phone, nationalIDLastFour, rememberNationalIDLastFour, contactNameConfirmed
        case personalInvoiceHeader, companyName, companyTaxpayerID, companyHasNoTaxpayerID
        case vatCompanyName, vatTaxpayerID, vatBankName, vatBankAccount, vatTermsAuthorized
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        surname = try values.decodeIfPresent(String.self, forKey: .surname) ?? ""
        givenName = try values.decodeIfPresent(String.self, forKey: .givenName) ?? ""
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        phone = try values.decodeIfPresent(String.self, forKey: .phone) ?? ""
        nationalIDLastFour = try values.decodeIfPresent(String.self, forKey: .nationalIDLastFour) ?? ""
        rememberNationalIDLastFour = try values.decodeIfPresent(Bool.self, forKey: .rememberNationalIDLastFour) ?? false
        contactNameConfirmed = try values.decodeIfPresent(Bool.self, forKey: .contactNameConfirmed) ?? false
        personalInvoiceHeader = try values.decodeIfPresent(String.self, forKey: .personalInvoiceHeader) ?? ""
        companyName = try values.decodeIfPresent(String.self, forKey: .companyName) ?? ""
        companyTaxpayerID = try values.decodeIfPresent(String.self, forKey: .companyTaxpayerID) ?? ""
        companyHasNoTaxpayerID = try values.decodeIfPresent(Bool.self, forKey: .companyHasNoTaxpayerID) ?? false
        vatCompanyName = try values.decodeIfPresent(String.self, forKey: .vatCompanyName) ?? ""
        vatTaxpayerID = try values.decodeIfPresent(String.self, forKey: .vatTaxpayerID) ?? ""
        vatBankName = try values.decodeIfPresent(String.self, forKey: .vatBankName) ?? ""
        vatBankAccount = try values.decodeIfPresent(String.self, forKey: .vatBankAccount) ?? ""
        vatTermsAuthorized = try values.decodeIfPresent(Bool.self, forKey: .vatTermsAuthorized) ?? false
    }
}

enum CheckoutProfileLaunchPolicy {
    static func load(isolated: Bool, from saved: () throws -> SecureCheckoutProfile) rethrows -> SecureCheckoutProfile {
        guard !isolated else { return SecureCheckoutProfile() }
        return try saved()
    }
}

struct CheckoutProfileKeychain {
    private let service = "local.applestore.assistant.native.checkout-profile"
    private let account = "primary"

    func load() throws -> SecureCheckoutProfile {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return SecureCheckoutProfile() }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError("无法从 macOS 钥匙串读取结账资料（错误 \(status)）")
        }
        do { return try JSONDecoder().decode(SecureCheckoutProfile.self, from: data) }
        catch { throw AppError("钥匙串中的结账资料无法读取；原资料未改动。\(error.localizedDescription)") }
    }

    func save(_ profile: SecureCheckoutProfile) throws {
        let data: Data
        do { data = try JSONEncoder().encode(profile) }
        catch { throw AppError("无法编码结账资料：\(error.localizedDescription)") }

        let query = baseQuery
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AppError("无法安全更新 macOS 钥匙串中的结账资料（错误 \(updateStatus)）")
        }

        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AppError("无法安全保存结账资料到 macOS 钥匙串（错误 \(addStatus)）")
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError("无法从 macOS 钥匙串删除结账资料（错误 \(status)）")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
