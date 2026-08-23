import Foundation
import Security

/// One way in and one way out for every credential, whatever provider wants it.
///
/// A key the user types into the Accounts window goes into the login keychain,
/// never into config.json - the settings file is plain text and gets copied
/// around, so a pasted key must not live there.
/// Keychain reads are cached for the life of the process.
///
/// Reading another application's keychain item is what makes macOS put up its
/// authorisation panel. Re-reading on every 60-second refresh multiplies the
/// chances of that panel appearing; once per launch is enough, and a 401 clears
/// the entry so a token refreshed by the owning app is picked up next time.
private final class TokenCache: @unchecked Sendable {
    static let shared = TokenCache()
    private var store: [String: String] = [:]
    private let lock = NSLock()

    func value(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func set(_ key: String, _ value: String) {
        lock.lock(); store[key] = value; lock.unlock()
    }

    func clear(_ key: String) {
        lock.lock(); store[key] = nil; lock.unlock()
    }
}

enum Credential {
    /// Drops a cached keychain read so the next fetch goes back to the keychain.
    static func invalidate(_ a: AccountSpec) {
        if let svc = a.keychainService { TokenCache.shared.clear(svc) }
    }

    /// Keychain service name for a key this app stores itself.
    static func service(provider: String, account: String) -> String {
        "AIMeter · \(provider) · \(account)"
    }

    /// Resolves an account's credential from wherever it lives: our keychain
    /// item, another app's keychain item, a file, or an environment variable.
    /// A JSON blob is unwrapped to the field that looks like the key.
    static func read(_ a: AccountSpec) -> Result<String, Fail> {
        var blob: String?
        if let svc = a.keychainService {
            if let cached = TokenCache.shared.value(svc) {
                blob = cached
            } else {
                switch Keychain.genericPassword(service: svc) {
                case .success(let s):
                    blob = s
                    TokenCache.shared.set(svc, s)
                case .failure(let e):
                    return .failure(e)
                }
            }
        } else if let file = a.keyFile {
            blob = readKey(file: file, jsonField: nil)
        }
        guard var value = blob?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return .failure(Fail(message: L.t("e.notoken")))
        }
        if value.hasPrefix("{") || value.hasPrefix("["),
           let obj = try? JSONSerialization.jsonObject(with: Data(value.utf8)) {
            let node: Any = a.keyJSONField.flatMap { (obj as? [String: Any])?[$0] } ?? obj
            if let s = node as? String {
                value = s
            } else if let found = findString(in: node, names: ["accessToken", "access_token",
                                                               "api_key", "key", "token", "secret"]) {
                value = found
            } else {
                return .failure(Fail(message: L.t("e.notoken")))
            }
        }
        return .success(value)
    }

    /// The destination a pasted credential was approved for.
    ///
    /// Kept in the keychain beside the key, deliberately not in the settings
    /// file: the file is the untrusted input here, so a destination read from it
    /// could be rewritten to an attacker's host. Whoever can edit the file
    /// cannot edit this.
    static func approvedBase(_ a: AccountSpec) -> String? {
        guard let svc = a.keychainService, svc.hasPrefix("AIMeter · "),
              case .success(let blob)? = Optional(Keychain.genericPassword(service: svc)),
              let obj = try? JSONSerialization.jsonObject(with: Data(blob.utf8)),
              let base = findString(in: obj, names: ["base", "baseURL"]) else { return nil }
        return base
    }

    @discardableResult
    static func store(_ key: String, service: String, base: String? = nil) -> Bool {
        guard let base else { return store(raw: key, service: service) }
        // Key and destination travel together, so neither can be swapped for
        // the other's without the keychain.
        let blob = ["key": key, "base": base]
        guard let data = try? JSONSerialization.data(withJSONObject: blob),
              let text = String(data: data, encoding: .utf8) else { return false }
        return store(raw: text, service: service)
    }

    @discardableResult
    private static func store(raw key: String, service: String) -> Bool {
        delete(service: service)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "AIMeter",
            kSecValueData as String: Data(key.utf8)
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }

    /// A short human-readable description of where an account's credential lives,
    /// for the Accounts list. Never shows the credential itself.
    static func describe(_ a: AccountSpec) -> String {
        if let h = a.home { return abbreviate(h) }
        if let s = a.keychainService {
            return s.hasPrefix("AIMeter · ") ? L.t("w.auth.keychain") : "\(L.t("w.keychainsvc")): \(s)"
        }
        if let f = a.keyFile {
            return f.hasPrefix("env:") ? "$" + f.dropFirst(4) : abbreviate(f)
        }
        return "—"
    }

    private static func abbreviate(_ path: String) -> String {
        let home = expand("~")
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
