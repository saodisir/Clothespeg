import Foundation
import Security
import CryptoKit
import LicenseKit

/// 打赏模块：核心功能永久免费，打赏只解锁下面几项非核心功能。
/// 源码是开放的，构建时去掉这道闸就能自己打包，不必打赏。
///
/// 发码走本地 CLI 与一份签发台账，每个产品各用一把 Ed25519 私钥。
/// 本 app 只认
/// `product == clothespeg` 且前缀为 `CPEG1` 的码，存储也用自己的
/// Keychain 槽位。签名有效只说明「开发者签过」，不说明
/// 「签给这个 app」，所以归属判定必须单独做一次。

// MARK: - 功能清单

/// 打赏解锁的小功能。以后加功能只往这里加一个 case、补一份文案与开关键，
/// 不用再动验签、状态或页面结构。
enum SmallFeature: String, CaseIterable, Identifiable {
    case hideFromCapture

    var id: String { rawValue }

    /// 复用功能原来的 UserDefaults 键。开关还是同一个开关，打赏只决定
    /// 它能不能被打开 —— 另造一份状态，就会出现「菜单和设置页显示两个值」
    /// 那种老毛病。
    var defaultsKey: String {
        switch self {
        case .hideFromCapture: WindowPrivacy.defaultsKey
        }
    }

    /// 用户把开关拨到哪，不管有没有解锁。
    var isWanted: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    func set(_ on: Bool) {
        switch self {
        case .hideFromCapture: WindowPrivacy.set(on)
        }
    }
}

// MARK: - 存储

/// 自己的 Keychain 槽位。两个 app 在同一台 Mac 上不能共用一个 service：
/// 读回时会各自清理自己认不出的存储内容，共槽等于互相删码。
private final class ClothespegLicenseStore: LicenseStoring {
    static let service = "com.vizwise.clothespeg.app.license"
    static let account = "small-features-key"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func loadLicenseKeys() -> [String] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return [] }
        if let keys = try? JSONDecoder().decode([String].self, from: data) { return keys }
        // 兼容单码裸串（手工调试 / 早期写入）
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? [] : [raw]
    }

    func saveLicenseKeys(_ keys: [String]) {
        clearLicenseKeys()
        guard !keys.isEmpty, let json = try? JSONEncoder().encode(keys) else { return }
        let attributes = baseQuery.merging(
            [kSecValueData as String: json,
             kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 }
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clearLicenseKeys() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 打赏没有试用期。`LicenseManager` 要的那个 trial 存储给个空实现：
/// 不传的话它会用默认实现，在别的产品目录下
/// 建目录写试用锚点 —— 那是别人的目录，不该被这个 app 碰。
private final class NoTrial: TrialStoring {
    func loadFirstLaunch() -> Date? { nil }
    func saveFirstLaunch(_ date: Date) {}
    func loadLastSeen() -> Date? { nil }
    func saveLastSeen(_ date: Date) {}
}

// MARK: - 许可

/// 一张码在设置页要显示的东西。SwiftUI 层不碰 `LicensePayload`，
/// 也不为「邮箱 · 序号」这行字再单独验一次签。
struct SmallFeaturesReceipt {
    let detail: String
    let perpetual: Bool
}


/// 无状态：每次都从存储读回重新验签，不留一个可能不同步的内存 Bool。
/// 内存标志一旦被绕过（或者刷新慢半拍），闸就形同虚设。
enum SmallFeaturesLicense {

    /// Only Clothespeg codes verify against this key. The private half is
    /// kept out of every repository; a public key is not a secret.
    private enum SigningKey {
        static let publicKeyBase64 = "1ArS3Hdl7c3+lBU9I039tsKSbZBdWnAJuxbVfnGicGI="
    }

    /// 收款页（2026-11-06 用户提供并换过一次地址，HTTP 200 验证过、无跳转）。
    /// 设成 nil 时设置页不显示打赏按钮，UI 不用跟着改。
    static let supportURL: URL? = URL(string: "https://cv4z8ffs.jsjform.com/f/RA3bcH")

    private static func makeManager(store: LicenseStoring = ClothespegLicenseStore()) -> LicenseManager {
        LicenseManager(publicKeyBase64: SigningKey.publicKeyBase64,
                       store: store,
                       trialStore: NoTrial(),
                       acceptedProduct: LicenseProduct.clothespeg,
                       keyPrefix: LicenseKey.clothespegPrefix)
    }

    /// 有没有一张属于本产品的有效码。
    ///
    /// 直接复用许可库的 `status()`：它的读回路径装了前缀 + `product` 两道闸，
    /// 且被许可库自带的测试覆盖。这里只取 `isPaid`，不展示试用期语义 ——
    /// 小功能打赏没有倒计时，没码就只是没解锁。
    static func isUnlocked() -> Bool {
        makeManager().status().isPaid
    }

    /// 已激活码的明细；没码、码不属于本产品时返回 nil。
    /// 只走 `status()` 的读回路径 —— 前缀与 product 两道闸都在里面。
    static func receipt() -> SmallFeaturesReceipt? {
        guard case .licensed(let payload) = makeManager().status() else { return nil }
        return SmallFeaturesReceipt(detail: "\(payload.subject) · #\(payload.serial)",
                                    perpetual: payload.kind == .perpetual)
    }

    /// 激活入口。`evaluate()` 带两道闸；`commit()` 也只在归属校验过了之后
    /// 才落盘，所以别家的码连存储都进不去。
    static func activate(_ rawKey: String) throws {
        let store = ClothespegLicenseStore()
        let manager = makeManager(store: store)
        let payload = try manager.evaluate(rawKey)
        manager.commit(rawKey, payload: payload)
    }

    static func deactivate() {
        makeManager().deactivate()
    }
}

// MARK: - 自检

/// `CLOTHESPEG_TIPS_PROBE=<path>` 时跑。用一把**临时生成的测试私钥**签四种
/// 码，喂给与 app 完全相同的判定逻辑，验证跨产品确实不通、老码确实不废。
/// 不碰正式私钥，也不碰真实 Keychain 槽位（round-trip 用独立的 probe 槽）。
enum SmallFeaturesProbe {

    private final class Box: LicenseStoring, TrialStoring {
        var keys: [String] = []
        func loadLicenseKeys() -> [String] { keys }
        func saveLicenseKeys(_ new: [String]) { keys = new }
        func clearLicenseKeys() { keys = [] }
        func loadFirstLaunch() -> Date? { nil }
        func saveFirstLaunch(_ date: Date) {}
        func loadLastSeen() -> Date? { nil }
        func saveLastSeen(_ date: Date) {}
    }

    /// 独立槽位，只用来验证这个二进制能不能读写 Keychain。
    private final class ProbeStore: LicenseStoring {
        static let service = "com.vizwise.clothespeg.app.license.probe"
        static let account = "probe"
        private var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: Self.service,
             kSecAttrAccount as String: Self.account]
        }
        func loadLicenseKeys() -> [String] {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return keys
        }
        func saveLicenseKeys(_ keys: [String]) {
            SecItemDelete(query as CFDictionary)
            guard let json = try? JSONEncoder().encode(keys) else { return }
            let attributes = query.merging(
                [kSecValueData as String: json,
                 kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 }
            SecItemAdd(attributes as CFDictionary, nil)
        }
        func clearLicenseKeys() { SecItemDelete(query as CFDictionary) }
    }

    static func run() -> String {
        let testPrivate = Curve25519.Signing.PrivateKey()
        let publicKeyBase64 = testPrivate.publicKey.rawRepresentation.base64EncodedString()

        func manager(_ product: String, _ prefix: String, _ box: Box) -> LicenseManager {
            LicenseManager(publicKeyBase64: publicKeyBase64,
                           store: box, trialStore: box,
                           acceptedProduct: product, keyPrefix: prefix)
        }
        func key(_ product: String?, _ prefix: String) -> String {
            (try? LicenseKey.issue(
                LicensePayload(kind: .perpetual, subject: "probe@example.com", product: product),
                privateKey: testPrivate, prefix: prefix)) ?? ""
        }
        /// 绕过激活框，直接把码塞进存储再读回 —— 这是最容易漏的那条路。
        func readbackAccepts(_ raw: String, product: String, prefix: String) -> Bool {
            let box = Box()
            box.saveLicenseKeys([raw])
            return manager(product, prefix, box).status().isPaid
        }

        // 探针用抽象的「另一个产品」前缀；真实两产品的隔离由许可库自带的
        // ProductIsolationTests 覆盖。legacyDefault 是老码折叠到的产品，
        // 用它才能验「payload 无 product 的历史码仍能在自己那侧通过」。
        let otherProduct = LicenseProduct.legacyDefault
        let clothespeg = LicenseProduct.clothespeg
        let otherPrefix = "OTHR1"
        let cpegPrefix = LicenseKey.clothespegPrefix

        let cpegKey = key(clothespeg, cpegPrefix)
        let otherKey = key(otherProduct, otherPrefix)
        let legacyKey = key(nil, otherPrefix)   // 老格式：payload 里没有 product
        // 前缀不参与签名，改完签名仍然有效 —— 只有 product 闸能挡住它
        let relabelled = otherPrefix + String(cpegKey.dropFirst(cpegPrefix.count))

        let cases: [(label: String, actual: Bool, expected: Bool)] = [
            ("cross-product: rejected — CPEG1 code in the other product's gate",
             readbackAccepts(cpegKey, product: otherProduct, prefix: otherPrefix), false),
            ("cross-product: rejected — relabelled CPEG1 code in the other product's gate",
             readbackAccepts(relabelled, product: otherProduct, prefix: otherPrefix), false),
            ("cross-product: rejected — other-product code in Clothespeg gate",
             readbackAccepts(otherKey, product: clothespeg, prefix: cpegPrefix), false),
            ("cross-product: rejected — legacy code in Clothespeg gate",
             readbackAccepts(legacyKey, product: clothespeg, prefix: cpegPrefix), false),
            ("legacy key: still licensed — other product's gate",
             readbackAccepts(legacyKey, product: otherProduct, prefix: otherPrefix), true),
            ("own key: accepted — Clothespeg gate",
             readbackAccepts(cpegKey, product: clothespeg, prefix: cpegPrefix), true),
        ]

        var lines = ["tips probe:"]
        for item in cases {
            lines.append("\(item.actual == item.expected ? "PASS" : "FAIL")  \(item.label) (got \(item.actual))")
        }

        // 这个二进制到底能不能读写 Keychain：ad-hoc 签名 historically 会
        // 在这里回 -34018（见 TranslationAPI.swift 的探针注释）。用独立槽位试，
        // 不碰用户已经激活的码。
        let probeStore = ProbeStore()
        probeStore.saveLicenseKeys(["round-trip"])
        let keychainOK = probeStore.loadLicenseKeys() == ["round-trip"]
        probeStore.clearLicenseKeys()
        lines.append("\(keychainOK ? "PASS" : "FAIL")  keychain: round-trip \(keychainOK ? "ok" : "FAILED")")

        return lines.joined(separator: "\n")
    }
}
