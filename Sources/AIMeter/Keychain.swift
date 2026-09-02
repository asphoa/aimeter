import Foundation
import Security

struct Fail: LocalizedError {
    let message: String
    /// True when macOS put up its authorisation panel and the read did not get
    /// past it. Kept apart from every other failure because it is the one that
    /// must not be retried on a timer: each retry is another panel.
    var denied: Bool = false
    /// True when the credential was read fine and holds a token field that is
    /// empty. That is what Claude Code leaves in its keychain item when the CLI
    /// is signed out: the item stays, with `accessToken: ""`, `expiresAt: 0`,
    /// and the account metadata around them. It is a different message from
    /// "could not obtain a token" - the read worked; there is no sign-in behind
    /// it - and it is the one the user can act on.
    var blank: Bool = false
    var errorDescription: String? { message }
}

enum Keychain {
    /// Reads a generic-password item. Reading another application's item makes
    /// macOS show an authorisation panel; the grant obtained by clicking
    /// "Always Allow" is what this app's stable signing identity keeps valid
    /// across rebuilds. It does not survive the *owning* application rewriting
    /// the item - see `modified(service:)` for why that matters and what is
    /// done about it.
    static func genericPassword(service: String) -> Result<String, Fail> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let s = String(data: data, encoding: .utf8) else {
                return .failure(Fail(message: L.t("k.nottext")))
            }
            return .success(s)
        case errSecItemNotFound:
            return .failure(Fail(message: L.t("k.missing", service)))
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .failure(Fail(message: L.t("k.denied"), denied: true))
        default:
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return .failure(Fail(message: L.t("k.error", "\(status)", msg)))
        }
    }

    /// When the item was last written, asked for **without asking for the item**.
    ///
    /// This is the whole of this app's answer to a fault that is not its own to
    /// fix. `Claude Code-credentials` belongs to the Claude Code CLI, and the
    /// CLI stores it by shelling out to `security add-generic-password -U`,
    /// which goes through the pre-partition `SecKeychainItemModifyContent` API.
    /// Measured on this machine on 2026-08-30, straight out of securityd's own
    /// log, 1.8 seconds apart:
    ///
    ///     security[70817]  SecKeychainItemModifyContent
    ///     security[70817]  integrity: no previous integrity acl exists; making a new one
    ///     securityd        integrity: ACL partition mismatch: client cdhash:4021dab6…
    ///     securityd        integrity: asking user about XARA partition for 'cdhash:4021dab6…'
    ///     securityd        displaying keychain prompt for /Applications/AIMeter.app
    ///
    /// That middle line is the bug: every token refresh throws away the item's
    /// integrity ACL - the list of partitions allowed to decrypt it - and builds
    /// a fresh one holding only the writer's own. Whatever the user granted this
    /// app is gone, and the next read raises the password panel again. It is not
    /// reachable from here: a reader cannot keep another application's write
    /// from resetting the item's own access control, and the trusted-application
    /// ACL this app's signing certificate does keep valid is a different list,
    /// checked and passed (`kcacl: client is valid, proceeding`) immediately
    /// before the partition check refuses.
    ///
    /// What *is* reachable is how often this app asks. An attribute-only query
    /// decrypts nothing, so it needs no authorisation and passes both gates in
    /// silence - verified by running an ad-hoc-signed probe whose cdhash was in
    /// neither the item's ACL nor its partition list: `SecItemCopyMatching`
    /// returned 0 with the modification date and no panel. So the modification
    /// date can be polled for free, and the read that *can* raise a panel is
    /// spent only when the item has actually changed since the last one that
    /// succeeded.
    ///
    /// Nil where there is no such item, or where the attribute query itself
    /// fails - callers must then fall through to the real read rather than
    /// treat "unknown" as "unchanged".
    static func modified(service: String) -> Date? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let attrs = out as? [String: Any] else { return nil }
        return attrs[kSecAttrModificationDate as String] as? Date
    }
}

/// Depth-first search for the first value whose key matches any of `names`
/// (case/underscore insensitive). Credential blobs change shape between
/// versions; matching on the key name survives that better than a fixed path.
///
/// Keys are visited in sorted order, not in the order a Swift dictionary
/// happens to hash them. That matters where a blob holds more than one
/// matching key: an unordered search returns a different one on different
/// launches of the same binary, so a bug in what it picks would surface as an
/// intermittent fault rather than a reproducible one. Callers should still
/// narrow the blob before searching it - see `Credential.container`.
func findString(in obj: Any, names: [String]) -> String? {
    let wanted = normalised(names)
    func walk(_ o: Any) -> String? {
        if let d = o as? [String: Any] {
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                if wanted.contains(norm(k)), let s = v as? String, !s.isEmpty { return s }
            }
            for (_, v) in d.sorted(by: { $0.key < $1.key }) { if let r = walk(v) { return r } }
        } else if let a = o as? [Any] {
            for v in a { if let r = walk(v) { return r } }
        }
        return nil
    }
    return walk(obj)
}

func findNumber(in obj: Any, names: [String]) -> Double? {
    let wanted = normalised(names)
    func walk(_ o: Any) -> Double? {
        if let d = o as? [String: Any] {
            for (k, v) in d.sorted(by: { $0.key < $1.key }) where wanted.contains(norm(k)) {
                if let n = v as? Double { return n }
                if let n = v as? Int { return Double(n) }
                if let s = v as? String, let n = Double(s) { return n }
            }
            for (_, v) in d.sorted(by: { $0.key < $1.key }) { if let r = walk(v) { return r } }
        } else if let a = o as? [Any] {
            for v in a { if let r = walk(v) { return r } }
        }
        return nil
    }
    return walk(obj)
}

private func norm(_ k: String) -> String {
    k.lowercased().replacingOccurrences(of: "_", with: "")
}

private func normalised(_ names: [String]) -> Set<String> { Set(names.map(norm)) }
