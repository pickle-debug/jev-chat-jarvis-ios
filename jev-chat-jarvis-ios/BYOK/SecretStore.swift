import Foundation

/// BYOK 密钥存储。按用户要求使用 UserDefaults 而非 Keychain。
///
/// 注意：UserDefaults 是沙盒内的明文 plist，会随设备备份导出。
/// 换回 Keychain 时只需替换本文件的 read/write 实现，调用方不受影响。
struct SecretStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func key(for route: APIRoute) -> String {
        defaults.string(forKey: Self.storageKey(route)) ?? ""
    }

    func setKey(_ value: String, for route: APIRoute) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.storageKey(route))
        } else {
            defaults.set(trimmed, forKey: Self.storageKey(route))
        }
    }

    func hasKey(for route: APIRoute) -> Bool {
        !key(for: route).isEmpty
    }

    private static func storageKey(_ route: APIRoute) -> String {
        "jarvis.secret.\(route.rawValue)"
    }
}
