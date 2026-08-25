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
        let raw: String
        switch blob(a) {
        case .success(let s): raw = s
        case .failure(let e): return .failure(e)
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failure(Fail(message: L.t("e.notoken"))) }
        guard value.hasPrefix("{") || value.hasPrefix("["),
              let obj = try? JSONSerialization.jsonObject(with: Data(value.utf8)) else {
            return .success(value)
        }
        guard let found = unwrap(json: obj, field: a.keyJSONField) else {
            return .failure(Fail(message: L.t("e.notoken")))
        }
        return .success(found)
    }

    /// The stored blob for an account, cached, before anything is pulled out of
    /// it. Shared by `read` and `expiry` so a blob is fetched - and its keychain
    /// dialog risked - once, not once per question asked about it.
    private static func blob(_ a: AccountSpec) -> Result<String, Fail> {
        if let svc = a.keychainService {
            if let cached = TokenCache.shared.value(svc) { return .success(cached) }
            switch Keychain.genericPassword(service: svc) {
            case .success(let s):
                TokenCache.shared.set(svc, s)
                return .success(s)
            case .failure(let e):
                return .failure(e)
            }
        }
        if let file = a.keyFile, let s = readKey(file: file, jsonField: nil) {
            return .success(s)
        }
        return .failure(Fail(message: L.t("e.notoken")))
    }

    /// Field names a credential might be filed under, across the blob shapes
    /// this app meets. Pure, and internal rather than private, so the test
    /// suite can hold it against a real blob's structure.
    static let tokenFields = ["accessToken", "access_token", "api_key", "key", "token", "secret"]

    /// Pulls the credential out of a parsed JSON blob.
    static func unwrap(json obj: Any, field: String?) -> String? {
        let node = container(obj, field: field)
        if let s = node as? String { return s.isEmpty ? nil : s }
        return findString(in: node, names: tokenFields)
    }

    /// Narrows a blob to the object holding *this* account's own credential,
    /// before any search by field name runs over it.
    ///
    /// `Claude Code-credentials` is not one credential. Beside the
    /// subscription's own OAuth under `claudeAiOauth` it carries an `mcpOAuth`
    /// directory with one entry per configured MCP server - forty of them on
    /// the machine this was written on - and every one of those entries has an
    /// `accessToken` field of its own. Searching the whole blob by field name
    /// can therefore return some MCP server's token instead of the
    /// subscription's, which would not merely give a wrong reading: it would
    /// send a third party's OAuth token to api.anthropic.com, a host it was
    /// never issued for, and the 401 that came back would be reported to the
    /// user as their Claude sign-in having expired.
    ///
    /// Today every one of those entries holds an empty string, and the
    /// non-empty check in `findString` is the only thing standing between this
    /// app and that bug - it fires the day the user authorises one MCP server.
    /// Narrowing first is the fix; the sorted traversal in `findString` only
    /// makes the failure reproducible, it does not prevent it.
    static func container(_ obj: Any, field: String?) -> Any {
        guard let d = obj as? [String: Any] else { return obj }
        if let field { return d[field] ?? obj }
        if let own = d["claudeAiOauth"] { return own }
        return obj
    }

    /// When an account's stored OAuth tokens stop being accepted.
    ///
    /// Claude Code records both halves: `expiresAt` for the access token it
    /// hands out, and `refreshTokenExpiresAt` for the credential that mints the
    /// next access token. The gap between the two is the whole story behind a
    /// menu reading "expired" while the account behind it is perfectly fine.
    struct Expiry: Sendable {
        var access: Date?
        var refresh: Date?
        /// False when there is no expiry recorded at all: a pasted API key does
        /// not expire on a clock, and must not be treated as though it had.
        var accessExpired: Bool { access.map { $0 <= Date() } ?? false }
        var refreshAlive: Bool { refresh.map { $0 > Date() } ?? false }
    }

    static func expiry(_ a: AccountSpec) -> Expiry {
        guard case .success(let raw) = blob(a),
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else { return Expiry() }
        return expiry(json: obj, field: a.keyJSONField)
    }

    static func expiry(json obj: Any, field: String?) -> Expiry {
        let node = container(obj, field: field)
        return Expiry(access: stamp(findNumber(in: node, names: ["expiresAt", "expires_at"])),
                      refresh: stamp(findNumber(in: node, names: ["refreshTokenExpiresAt",
                                                                  "refresh_token_expires_at"])))
    }

    /// Claude Code writes these in milliseconds; plenty of other things write
    /// seconds. Told apart by magnitude rather than by which app wrote the blob:
    /// a seconds stamp this side of the year 5000 is under 1e11, a milliseconds
    /// stamp for any date since 1973 is over it.
    private static func stamp(_ n: Double?) -> Date? {
        guard let n, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
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
