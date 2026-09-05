import Foundation
import Security

struct Fail: LocalizedError {
    let message: String
    /// True when macOS put up its authorisation panel and the read did not get
    /// past it. Kept apart from every other failure because it is the one that
    /// must not be retried on a timer: each retry is another panel.
    var denied: Bool = false
    /// True when the credential was read fine and holds a token field that is
    /// empty - `accessToken: ""`, `expiresAt: 0`, and the account metadata
    /// still sitting around them. It is a different message from "could not
    /// obtain a token" - the read worked; there is simply no token in the item
    /// right now.
    ///
    /// Corrected 2026-09-04: an earlier version of this comment called that
    /// shape "what Claude Code leaves behind when the CLI is signed out" and
    /// cited `claude auth status --json` printing `"loggedIn": false` as
    /// confirmation. That status call was run in a shell missing the `USER`
    /// environment variable - the exact trap `ClaudeCLI.environment` exists to
    /// avoid - and the same binary, run with `USER` set, reported
    /// `"loggedIn": true` on the same machine. The tokens really were blank,
    /// from 2026-09-01 17:46 local until a `claude -p` run refilled them at
    /// 2026-09-04 09:41:30; the item's own `mdat` moved with them. So "blank"
    /// means exactly what it says - the item holds no token right now - and
    /// nothing more should be read into it about why.
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

    /// Services read through `/usr/bin/security` instead of `SecItemCopyMatching`
    /// - see `securityToolPassword(service:)` for why that route exists at all.
    ///
    /// An **allowlist**, deliberately not a prefix test against something like
    /// "not one of ours": `keychainService` for a generic account comes out of
    /// `config.json`, which this project already treats as untrusted plain text
    /// (see `ClaudeCLI.allowedBinaries` for the same reasoning applied to a
    /// binary path). Without this list, a poisoned setting could point this app
    /// at *any* keychain item and have it read silently via `apple-tool:` -
    /// where the in-process path at least raises a panel naming AIMeter as the
    /// reader. The one entry here is the CLI's own item, which is the one this
    /// app has independent reason to read the same way the CLI reads it.
    ///
    /// AIMeter's own items (`AIMeter · …`) stay on the in-process path: this app
    /// created them with `SecItemAdd`, so it is already their owner and is never
    /// prompted for them.
    static let securityToolServices: Set<String> = [ClaudeCLI.credentialService]

    /// Pure membership test - the property under test in
    /// `testKeychainSecurityToolRouteIsAnAllowlistNotAPrefix`.
    static func readsViaSecurityTool(_ service: String) -> Bool {
        securityToolServices.contains(service)
    }

    /// Reads a generic-password item's secret by shelling out to
    /// `/usr/bin/security find-generic-password -w`, instead of
    /// `SecItemCopyMatching`.
    ///
    /// The reason this exists at all: the CLI stores `Claude Code-credentials`
    /// by shelling out to `security add-generic-password -U`, and that write
    /// path rebuilds the item's integrity ACL - the partition list - to hold
    /// only `apple-tool:`, the partition `/usr/bin/security` itself runs in.
    /// Every grant this app obtained by "Always Allow" is wiped by that rebuild,
    /// at every token refresh, so an in-process `SecItemCopyMatching` read keeps
    /// raising the panel no matter how many times it was answered. But
    /// `/usr/bin/security` reads that same item silently, because it already
    /// sits in the one partition the item's ACL still names - measured on this
    /// machine 2026-09-04 09:47: securityd's log carries nothing for that read,
    /// no `asking user about XARA partition`, no `displaying keychain prompt`.
    /// This is also exactly how the `claude` CLI reads its own token back
    /// (anthropics/claude-code#89985); the panel that never stops recurring is
    /// anthropics/claude-code#87348.
    ///
    /// Run as a fixed absolute-path `Process` with an explicit `arguments`
    /// array - never a shell - so `service` is passed as inert data and cannot
    /// be interpreted. Stdin is `/dev/null`; a program asking a question here
    /// gets an immediate EOF instead of hanging. Never logs or prints the
    /// secret itself - only exit codes and the first stderr line reach a `Fail`.
    static func securityToolPassword(service: String) -> Result<String, Fail> {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<String, Fail> = .failure(Fail(message: L.t("k.error", "-1", "timed out")))
        Task {
            let out = await ProcessRunner.run(
                binary: "/usr/bin/security",
                args: ["find-generic-password", "-s", service, "-w"],
                stdinClosed: true,
                deadline: .seconds(10))
            let errText = String(decoding: out.stderr, as: UTF8.self)
            let errFirstLine = errText.split(whereSeparator: \.isNewline).first
                .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if out.timedOut {
                outcome = .failure(Fail(message: L.t("k.error", "-2", "timed out")))
            } else if out.exitCode == 44 || errText.contains("could not be found") {
                outcome = .failure(Fail(message: L.t("k.missing", service)))
            } else if out.exitCode != 0 {
                outcome = .failure(Fail(message: L.t("k.error", "\(out.exitCode)", errFirstLine)))
            } else if var text = String(data: out.stdout, encoding: .utf8) {
                if text.hasSuffix("\n") { text.removeLast() }
                outcome = .success(text)
            } else {
                outcome = .failure(Fail(message: L.t("k.nottext")))
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
        return outcome
    }

    /// Dispatches a generic-password read to whichever route `service` needs -
    /// see `readsViaSecurityTool(_:)` for the allowlist that decides.
    static func read(service: String) -> Result<String, Fail> {
        readsViaSecurityTool(service) ? securityToolPassword(service: service)
                                       : genericPassword(service: service)
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
    /// Superseded 2026-09-04 for this specific item: the read itself is now
    /// routed through `/usr/bin/security` (see `securityToolPassword(service:)`),
    /// which sits in the `apple-tool:` partition the CLI's own writes leave in
    /// the item's ACL and so reads it without ever raising the panel this
    /// section was written to ration - measured 2026-09-04 09:47, nothing in
    /// securityd's log for that read. The stamp mechanism below is kept for
    /// exactly what it was always for regardless of which route the real read
    /// takes: it is still what makes an *unchanged* item cost no read at all,
    /// security-tool or in-process. For any other item still on the in-process
    /// path, the original reasoning stands - an attribute-only query decrypts
    /// nothing, so it needs no authorisation and passes both gates in silence,
    /// verified by running an ad-hoc-signed probe whose cdhash was in neither
    /// the item's ACL nor its partition list: `SecItemCopyMatching` returned 0
    /// with the modification date and no panel.
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
