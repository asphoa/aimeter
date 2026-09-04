import CryptoKit
import Foundation

/// The destination approved by a person pressing Save. Pins live outside the
/// untrusted settings file in AIMeter's own keychain item.
enum RecipePin {
    struct Pin: Codable, Equatable {
        var host: String?
        var binary: String?
        var argsHash: String?
        var authName: String?
        var folder: String?
    }

    static func service(_ id: String) -> String { "AIMeter · recipe · \(id)" }

    @discardableResult
    static func write(_ recipe: Recipe) -> Bool {
        guard let pin = proposed(recipe), let data = try? JSONEncoder().encode(pin),
              let text = String(data: data, encoding: .utf8) else { return false }
        return Credential.store(text, service: service(recipe.id))
    }

    static func read(_ id: String) -> Pin? {
        func field(_ name: String) -> String? {
            let account = AccountSpec(name: id, keychainService: service(id), keyJSONField: name)
            guard case .success(let value) = Credential.read(account) else { return nil }
            return value
        }
        let host = field("host"), binary = field("binary"), folder = field("folder")
        guard host != nil || binary != nil || folder != nil else { return nil }
        return Pin(host: host, binary: binary, argsHash: field("argsHash"),
                   authName: field("authName"), folder: folder)
    }

    static func delete(_ id: String) { Credential.delete(service: service(id)) }

    static func matches(_ recipe: Recipe, _ pin: Pin) -> Bool {
        guard let proposed = proposed(recipe) else { return false }
        switch recipe.fetch.method {
        case "http":
            return proposed.host == pin.host && proposed.authName == pin.authName
        case "cli":
            return proposed.binary == pin.binary && proposed.argsHash == pin.argsHash
                && proposed.authName == pin.authName
        case "file": return proposed.folder == pin.folder
        case "none": return true
        default: return false
        }
    }

    static func proposed(_ recipe: Recipe) -> Pin? {
        switch recipe.fetch.method {
        case "http":
            guard let base = recipe.fetch.baseURL,
                  let approved = RecipeURL.approvedDestination(from: base) else { return nil }
            return Pin(host: approved.comps.string, binary: nil, argsHash: nil,
                       authName: recipe.fetch.authName, folder: nil)
        case "cli":
            guard let binary = recipe.fetch.binary,
                  let safe = CommandRun.allowedBinary(binary) else { return nil }
            return Pin(host: nil, binary: safe, argsHash: argsHash(recipe.fetch.args),
                       authName: recipe.fetch.authName, folder: nil)
        case "file":
            guard let folder = recipe.fetch.folder else { return nil }
            let fixed = URL(fileURLWithPath: expand(folder)).standardizedFileURL.path
            return Pin(host: nil, binary: nil, argsHash: nil, authName: nil, folder: fixed)
        case "none": return Pin()
        default: return nil
        }
    }

    static func argsHash(_ args: [String]) -> String {
        let data = (try? JSONEncoder().encode(args)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
