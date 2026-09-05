import CryptoKit
import Foundation

/// The destination approved by a person pressing Save. Pins live outside the
/// untrusted settings file in AIMeter's own keychain item.
enum RecipePin {
    struct CredentialRef: Codable, Equatable {
        var source: String
        var identifier: String?
        var keyJSONField: String?
        var authMode: String?
        var authName: String?
    }

    struct Pin: Codable, Equatable {
        var host: String?
        var binary: String?
        var argsHash: String?
        var authName: String?
        var folder: String?
        var envHash: String?
        var homeMode: String?
        var credentialRef: CredentialRef?
        var method: String?
        var pathPolicy: String?
        var bodyHash: String?
    }

    static func service(_ id: String) -> String { "AIMeter · recipe · \(id)" }

    @discardableResult
    static func write(_ recipe: Recipe, account: AccountSpec? = nil) -> Bool {
        guard let pin = proposed(recipe, account: account), let data = try? JSONEncoder().encode(pin),
              let text = String(data: data, encoding: .utf8) else { return false }
        return Credential.store(text, service: service(recipe.id))
    }

    static func read(_ id: String) -> Pin? {
        guard case .success(let raw) = Keychain.genericPassword(service: service(id)),
              let data = raw.data(using: .utf8),
              let pin = try? JSONDecoder().decode(Pin.self, from: data) else { return nil }
        guard pin.host != nil || pin.binary != nil || pin.folder != nil else { return nil }
        return pin
    }

    static func delete(_ id: String) { Credential.delete(service: service(id)) }

    static func matches(_ recipe: Recipe, _ pin: Pin, account: AccountSpec? = nil) -> Bool {
        guard let proposed = proposed(recipe, account: account) else { return false }
        switch recipe.fetch.method {
        case "http":
            return proposed.host == pin.host
                && proposed.method == pin.method
                && proposed.pathPolicy == pin.pathPolicy
                && proposed.bodyHash == pin.bodyHash
                && credentialRefMatches(proposed.credentialRef, pin.credentialRef)
        case "cli":
            return proposed.binary == pin.binary && proposed.argsHash == pin.argsHash
                && proposed.envHash == pin.envHash && proposed.homeMode == pin.homeMode
                && credentialRefMatches(proposed.credentialRef, pin.credentialRef)
        case "file":
            return proposed.folder == pin.folder
                && credentialRefMatches(proposed.credentialRef, pin.credentialRef)
        case "none": return true
        default: return false
        }
    }

    static func proposed(_ recipe: Recipe, account: AccountSpec? = nil) -> Pin? {
        let credRef = credentialRef(recipe: recipe, account: account)
        switch recipe.fetch.method {
        case "http":
            guard let base = recipe.fetch.baseURL,
                  let approved = RecipeURL.approvedDestination(from: base) else { return nil }
            return Pin(host: approved.comps.string, binary: nil, argsHash: nil,
                       authName: nil, folder: nil, envHash: nil, homeMode: nil,
                       credentialRef: credRef,
                       method: recipe.fetch.verb.uppercased(),
                       pathPolicy: pathPolicy(recipe.fetch.path),
                       bodyHash: bodyHash(recipe.fetch.body))
        case "cli":
            guard let binary = recipe.fetch.binary,
                  let safe = CommandRun.allowedBinary(binary) else { return nil }
            guard CommandRun.validateEnvironment(recipe.fetch.environment) else { return nil }
            return Pin(host: nil, binary: safe, argsHash: argsHash(recipe.fetch.args),
                       authName: nil, folder: nil,
                       envHash: envHash(recipe.fetch.environment),
                       homeMode: homeMode(recipe.fetch, accountHome: account?.home),
                       credentialRef: credRef, method: nil, pathPolicy: nil, bodyHash: nil)
        case "file":
            guard let folder = recipe.fetch.folder else { return nil }
            let fixed = URL(fileURLWithPath: expand(folder)).standardizedFileURL.path
            return Pin(host: nil, binary: nil, argsHash: nil, authName: nil, folder: fixed,
                       envHash: nil, homeMode: nil, credentialRef: credRef,
                       method: nil, pathPolicy: nil, bodyHash: nil)
        case "none": return Pin()
        default: return nil
        }
    }

    static func credentialRef(recipe: Recipe, account: AccountSpec?) -> CredentialRef {
        let cred = recipe.credential
        var identifier: String?
        switch cred.source {
        case "keychain":
            identifier = account?.keychainService ?? (service(recipe.id) + " · credential")
        case "keyFile":
            identifier = account?.keyFile ?? cred.path
        case "env":
            identifier = cred.name
        case "appKeychain":
            identifier = cred.service
        default:
            identifier = nil
        }
        let authMode = recipe.fetch.method == "http" ? recipe.fetch.auth : nil
        return CredentialRef(source: cred.source, identifier: identifier,
                             keyJSONField: cred.jsonField,
                             authMode: authMode, authName: recipe.fetch.authName)
    }

    private static func credentialRefMatches(_ a: CredentialRef?, _ b: CredentialRef?) -> Bool {
        a == b
    }

    static func pathPolicy(_ path: String?) -> String {
        guard let path else { return "" }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(parts[0])
        guard parts.count > 1 else { return base }
        let keys = String(parts[1]).split(separator: "&").compactMap { item -> String? in
            let key = item.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return key.isEmpty ? nil : key
        }.sorted()
        return keys.isEmpty ? base : base + "?" + keys.joined(separator: ",")
    }

    static func bodyHash(_ body: JSONValue?) -> String {
        guard let body else { return "" }
        return canonicalJSONHash(body)
    }

    static func envHash(_ environment: [String: String]) -> String {
        guard !environment.isEmpty else { return "" }
        let lines = environment.keys.sorted().map { key in "\(key)=\(environment[key] ?? "")" }
        return sha256(Data(lines.joined(separator: "\n").utf8))
    }

    static func homeMode(_ fetch: FetchSpec, accountHome: String?) -> String {
        if fetch.homeFromAccount {
            let home = CommandRun.validHome(accountHome ?? "~") ?? expand(accountHome ?? "~")
            return "account:\(home)"
        }
        return "default:\(CommandRun.validHome("~") ?? expand("~"))"
    }

    static func argsHash(_ args: [String]) -> String {
        canonicalJSONHash(args)
    }

    /// Canonical JSON for pin hashes: sorted object keys so insertion order
    /// cannot drift across process restarts.
    private static func canonicalJSONHash<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(value) else { return "" }
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}
