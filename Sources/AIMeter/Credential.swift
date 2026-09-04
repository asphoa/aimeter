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
///
/// Entries are stamped with the keychain item's own modification date, which
/// `Keychain.modified` can read without authorisation and therefore without a
/// panel. That turns "is this cached copy still current?" from a guess into a
/// question with an answer: unchanged stamp, unchanged token, no read. It also
/// gives a refusal somewhere to live. Before this, a denied read left nothing
/// behind, so the next timer tick asked again, and again - one dismissed panel
/// became a panel a minute for as long as the app stayed open. A refusal is now
/// remembered against the stamp it was refused for, and reconsidered when the
/// item next changes or when a person presses "Check now".
///
/// Internal rather than private so the test suite can plant a refusal without
/// putting a real panel in front of whoever runs the tests.
final class TokenCache: @unchecked Sendable {
    static let shared = TokenCache()
    private var store: [String: (value: String, stamp: Date?)] = [:]
    private var denials: [String: Date?] = [:]
    private let lock = NSLock()

    /// The cached token, but only if it was read from the item as it stands now.
    /// A nil `stamp` means the modification date could not be established, and
    /// nothing may be served from cache on a guess.
    func value(_ key: String, stamp: Date?) -> String? {
        guard let stamp else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let hit = store[key], hit.stamp == stamp else { return nil }
        return hit.value
    }

    func set(_ key: String, _ value: String, stamp: Date?) {
        lock.lock(); store[key] = (value, stamp); denials[key] = nil; lock.unlock()
    }

    /// True when this exact version of the item has already been refused, so
    /// asking again would only put the same panel in front of the same person.
    func refused(_ key: String, stamp: Date?) -> Bool {
        guard let stamp else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let d = denials[key] else { return false }
        return d == stamp
    }

    func refuse(_ key: String, stamp: Date?) {
        guard let stamp else { return }
        lock.lock(); denials[key] = stamp; lock.unlock()
    }

    func clear(_ key: String) {
        lock.lock(); store[key] = nil; denials[key] = nil; lock.unlock()
    }

    /// Drops a remembered refusal and nothing else. A token that was read
    /// successfully stays cached: forgetting a "no" must not cost a fresh read
    /// - and a fresh panel - of an item that was never refused.
    func forgive(_ key: String) {
        lock.lock(); denials[key] = nil; lock.unlock()
    }
}

enum Credential {
    /// Drops a cached keychain read, and any remembered refusal, so the next
    /// fetch goes back to the keychain. This is the "a person asked for it"
    /// door: it is what makes "Check now" able to put the authorisation panel
    /// back up after one was dismissed, which nothing on a timer may do.
    static func invalidate(_ a: AccountSpec) {
        if let svc = a.keychainService { TokenCache.shared.clear(svc) }
    }

    /// Forgets a remembered refusal, keeping any cached token. This is what a
    /// manual check calls before reading: the "not now" the user gave a timer
    /// tick does not answer the question they are now asking by hand.
    ///
    /// Shipped missing in v1.0.21. The refusal memory was added there so that
    /// one dismissed panel did not become a panel a minute, and the row's own
    /// text promised that "Check now" would put the panel back - but nothing
    /// on the manual path ever cleared the memory, so after one "Deny" the
    /// button re-read the remembered refusal and did nothing, until the CLI
    /// next rewrote the item or the app was relaunched.
    static func forgetRefusal(_ a: AccountSpec) {
        if let svc = a.keychainService { TokenCache.shared.forgive(svc) }
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
        guard value.hasPrefix("{") || value.hasPrefix("[") else {
            return .success(value)
        }
        // A value that looks like JSON but fails to parse - a truncated or
        // half-written key file - must not fall through to being read as a
        // literal key: the whole blob, secrets and all, would go out as the
        // credential in an Authorization header.
        guard let obj = try? JSONSerialization.jsonObject(with: Data(value.utf8)) else {
            return .failure(Fail(message: L.t("e.notoken")))
        }
        guard let found = unwrap(json: obj, field: a.keyJSONField) else {
            // Two different things arrive here. A blob with no token field at
            // all is a shape this app does not understand. A blob whose token
            // field is there and empty is a shape it understands perfectly:
            // the item holds no token right now. Observed on 2026-09-02 - the
            // keychain item read fine, the panel said "could not obtain an
            // access token", and this app's first read of `claude auth
            // status` (run without `USER` set) said `loggedIn: false`, which
            // was later found to be a false negative - see `Fail.blank`'s
            // doc comment for the corrected account. The blank shape must not
            // be reported in the words of "could not obtain a token" either
            // way: it is a real thing to act on, worded as itself.
            if holdsBlankToken(json: obj, field: a.keyJSONField) {
                return .failure(Fail(message: L.t("e.blanktoken"), blank: true))
            }
            return .failure(Fail(message: L.t("e.notoken")))
        }
        return .success(found)
    }

    /// True when the narrowed blob carries a token field whose value is the
    /// empty string. Pure, so the shape Claude Code leaves behind on sign-out
    /// can be pinned by test without a keychain.
    static func holdsBlankToken(json obj: Any, field: String?) -> Bool {
        guard let d = container(obj, field: field) as? [String: Any] else { return false }
        let wanted = Set(tokenFields.map { $0.lowercased().replacingOccurrences(of: "_", with: "") })
        return d.contains { k, v in
            wanted.contains(k.lowercased().replacingOccurrences(of: "_", with: ""))
                && (v as? String)?.isEmpty == true
        }
    }

    /// The stored blob for an account, cached, before anything is pulled out of
    /// it. Shared by `read` and `expiry` so a blob is fetched - and its keychain
    /// dialog risked - once, not once per question asked about it.
    ///
    /// The item's modification date is established first, for nothing: it is an
    /// attribute, so reading it decrypts no data and needs no authorisation.
    /// Everything else here hangs off that one free fact. An unchanged item is
    /// served from cache without a read, and an item this app has just been
    /// refused is not asked for again until it changes. See `Keychain.modified`
    /// for the measurements behind both.
    private static func blob(_ a: AccountSpec) -> Result<String, Fail> {
        if let svc = a.keychainService {
            let stamp = Keychain.modified(service: svc)
            if let cached = TokenCache.shared.value(svc, stamp: stamp) { return .success(cached) }
            if TokenCache.shared.refused(svc, stamp: stamp) {
                return .failure(Fail(message: L.t("k.denied"), denied: true))
            }
            switch Keychain.read(service: svc) {
            case .success(let s):
                TokenCache.shared.set(svc, s, stamp: stamp)
                return .success(s)
            case .failure(let e):
                if e.denied { TokenCache.shared.refuse(svc, stamp: stamp) }
                return .failure(e)
            }
        }
        if let file = a.keyFile, let s = readKey(file: file) {
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
