import Foundation
import Security

struct Fail: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Keychain {
    /// Reads a generic-password item. The first read of another app's item makes
    /// macOS show an authorisation dialog - click "Always Allow" once and the
    /// ad-hoc code signature keeps this app's identity stable across launches.
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
        case errSecUserCanceled, errSecAuthFailed:
            return .failure(Fail(message: L.t("k.denied")))
        default:
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return .failure(Fail(message: L.t("k.error", "\(status)", msg)))
        }
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
