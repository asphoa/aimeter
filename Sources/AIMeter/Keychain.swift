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
func findString(in obj: Any, names: [String]) -> String? {
    let wanted = Set(names.map { $0.lowercased().replacingOccurrences(of: "_", with: "") })
    func walk(_ o: Any) -> String? {
        if let d = o as? [String: Any] {
            for (k, v) in d {
                let norm = k.lowercased().replacingOccurrences(of: "_", with: "")
                if wanted.contains(norm), let s = v as? String, !s.isEmpty { return s }
            }
            for (_, v) in d { if let r = walk(v) { return r } }
        } else if let a = o as? [Any] {
            for v in a { if let r = walk(v) { return r } }
        }
        return nil
    }
    return walk(obj)
}

func findNumber(in obj: Any, names: [String]) -> Double? {
    let wanted = Set(names.map { $0.lowercased().replacingOccurrences(of: "_", with: "") })
    func walk(_ o: Any) -> Double? {
        if let d = o as? [String: Any] {
            for (k, v) in d {
                let norm = k.lowercased().replacingOccurrences(of: "_", with: "")
                if wanted.contains(norm) {
                    if let n = v as? Double { return n }
                    if let n = v as? Int { return Double(n) }
                    if let s = v as? String, let n = Double(s) { return n }
                }
            }
            for (_, v) in d { if let r = walk(v) { return r } }
        } else if let a = o as? [Any] {
            for v in a { if let r = walk(v) { return r } }
        }
        return nil
    }
    return walk(obj)
}
