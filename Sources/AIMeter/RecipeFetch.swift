import Foundation

enum RecipeURL {
    /// Moved unchanged from GenericProvider: HTTPS and a real host are the
    /// approved public-network shape.
    static func approvedHost(from base: String) -> (comps: URLComponents, host: String)? {
        guard let comps = URLComponents(string: base),
              comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty else { return nil }
        return (comps, host)
    }

    /// Moved unchanged from GenericProvider. A settings-file path can never
    /// replace the authority approved in the keychain.
    static func safeURL(comps: URLComponents, host: String, path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("@"), !path.contains("//"),
              !path.lowercased().contains("://"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        var c = comps
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        c.path = String(parts[0])
        c.query = parts.count > 1 ? String(parts[1]) : nil
        guard let url = c.url, url.host == host else { return nil }
        return url
    }

    /// Recipes additionally admit plain HTTP only for loopback services.
    static func approvedDestination(from base: String) -> (comps: URLComponents, host: String)? {
        if let approved = approvedHost(from: base) { return canonical(approved.comps, approved.host) }
        guard let comps = URLComponents(string: base), comps.scheme?.lowercased() == "http",
              let host = comps.host?.lowercased(), ["127.0.0.1", "localhost"].contains(host) else { return nil }
        return canonical(comps, host)
    }

    private static func canonical(_ source: URLComponents, _ host: String)
        -> (comps: URLComponents, host: String)? {
        var c = URLComponents()
        c.scheme = source.scheme?.lowercased(); c.host = host.lowercased(); c.port = source.port
        guard c.url != nil else { return nil }
        return (c, host.lowercased())
    }
}

struct RecipeFetchMeta: Sendable {
    var request: String
    var status: Int?
    var bytes: Int
    var elapsed: TimeInterval
    var contentType: String?
    var snapshotAt: Date?
}

struct RecipeTestResult {
    var reading: Reading
    var meta: RecipeFetchMeta
    var rawPreview: String
    var suggestions: [String]
}

enum RecipeFetch {
    typealias Output = (data: Data, meta: RecipeFetchMeta)

    /// Injected by tests to count HTTP attempts without network I/O.
    static var httpTestHook: ((URLRequest) -> Result<(Data, HTTPURLResponse), Fail>)?
    /// Injected by tests for the appKeychain credential branch.
    static var appKeychainTestHook: ((String) -> Result<String, Fail>)?

    static func run(_ recipe: Recipe, account: AccountSpec,
                    pin suppliedPin: RecipePin.Pin? = nil) async -> Result<Output, Fail> {
        let start = Date()
        if let message = Credential.validateRecipeCredential(recipe, account: account) {
            return .failure(Fail(message: message))
        }
        let pin: RecipePin.Pin
        if recipe.fetch.method == "none" { pin = RecipePin.Pin() }
        else if let suppliedPin { pin = suppliedPin }
        else if let stored = RecipePin.read(recipe.id) { pin = stored }
        else { return .failure(Fail(message: L.t("rc.reapprove"))) }
        guard recipe.legacy || RecipePin.matches(recipe, pin, account: account) else {
            return .failure(Fail(message: L.t("rc.reapprove")))
        }

        switch recipe.fetch.method {
        case "http": return await http(recipe, account: account, pin: pin, start: start)
        case "cli": return await command(recipe, account: account, pin: pin, start: start)
        case "file": return file(recipe, pin: pin, start: start)
        case "none":
            return .success((Data("{}".utf8), RecipeFetchMeta(request: L.t("rc.no.request"),
                status: nil, bytes: 2, elapsed: Date().timeIntervalSince(start),
                contentType: "application/json", snapshotAt: nil)))
        default: return .failure(Fail(message: L.t("rc.bad.method")))
        }
    }

    static func test(_ recipe: Recipe, account: AccountSpec,
                     pin: RecipePin.Pin) async -> Result<RecipeTestResult, Fail> {
        switch await run(recipe, account: account, pin: pin) {
        case .failure(let fail): return .failure(fail)
        case .success(let output):
            var reading = RecipeMap.apply(recipe.map, to: output.data, pick: recipe.fetch.pick)
            reading.id = recipe.id; reading.title = recipe.name; reading.account = account.name
            if let stamp = output.meta.snapshotAt { reading.snapshotAt = stamp }
            let key = credential(recipe, account: account).successValue.flatMap { $0 }
            return .success(RecipeTestResult(
                reading: reading, meta: output.meta,
                rawPreview: redactRawPreview(output.data, credential: key),
                suggestions: RecipeMap.unmappedTopLevelKeys(recipe.map, in: output.data)))
        }
    }

    static func redactRawPreview(_ data: Data, credential: String?) -> String {
        var text = String(decoding: data.prefix(600), as: UTF8.self)
        if let credential, !credential.isEmpty {
            text = text.replacingOccurrences(of: credential, with: "••••")
        }
        return text
    }

    static func fileGlobIsSafe(_ glob: String) -> Bool {
        !glob.isEmpty && !glob.components(separatedBy: "/").contains("..")
            && !glob.hasPrefix("/") && glob.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func http(_ recipe: Recipe, account: AccountSpec, pin: RecipePin.Pin,
                             start: Date) async -> Result<Output, Fail> {
        guard let pinned = pin.host,
              let approved = RecipeURL.approvedDestination(from: pinned),
              let path = recipe.fetch.path,
              var url = RecipeURL.safeURL(comps: approved.comps, host: approved.host, path: path) else {
            return .failure(Fail(message: L.t("e.badpath")))
        }
        let secretResult = credential(recipe, account: account)
        let secret: String?
        switch secretResult {
        case .success(let value): secret = value
        case .failure(let fail): return .failure(fail)
        }
        if recipe.fetch.auth == "query" {
            guard let name = recipe.fetch.authName, !name.isEmpty, let secret else {
                return .failure(Fail(message: L.t("rc.bad.auth")))
            }
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = c?.queryItems ?? []
            c?.queryItems = queryItems + [URLQueryItem(name: name, value: secret)]
            guard let withQuery = c?.url, withQuery.host == approved.host else {
                return .failure(Fail(message: L.t("e.badpath")))
            }
            url = withQuery
        }
        var request = URLRequest(url: url)
        let verb = recipe.fetch.verb.uppercased()
        guard verb == "GET" || verb == "POST" else {
            return .failure(Fail(message: L.t("rc.bad.verb")))
        }
        request.httpMethod = verb
        request.timeoutInterval = min(max(recipe.fetch.timeout, 0.1), 30)
        switch recipe.fetch.auth {
        case "bearer": if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        case "header":
            guard let name = recipe.fetch.authName, !name.isEmpty, let secret else {
                return .failure(Fail(message: L.t("rc.bad.auth")))
            }
            request.setValue(secret, forHTTPHeaderField: name)
        case "query", "none": break
        default: return .failure(Fail(message: L.t("rc.bad.auth")))
        }
        if verb == "POST", let body = recipe.fetch.body {
            guard let data = try? JSONEncoder().encode(body) else {
                return .failure(Fail(message: L.t("rc.bad.body")))
            }
            request.httpBody = data; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let delegate = Net.SameHostRedirectDelegate(originalURL: url, rejectAll: true)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response): (Data, HTTPURLResponse)
            if let hook = httpTestHook {
                switch hook(request) {
                case .success(let pair): (data, response) = pair
                case .failure(let fail): return .failure(fail)
                }
            } else {
                let pair = try await session.data(for: request)
                guard let http = pair.1 as? HTTPURLResponse else {
                    return .failure(Fail(message: L.t("e.nothttp")))
                }
                (data, response) = (pair.0, http)
            }
            let http = response
            let shownURL = url.absoluteString.replacingOccurrences(of: secret ?? "\u{0}", with: "••••")
            let meta = RecipeFetchMeta(request: "\(verb) \(shownURL)", status: http.statusCode,
                bytes: data.count, elapsed: Date().timeIntervalSince(start),
                contentType: http.value(forHTTPHeaderField: "Content-Type"), snapshotAt: nil)
            guard (200..<300).contains(http.statusCode) else {
                return .failure(Fail(message: L.t("e.http", "\(http.statusCode)")))
            }
            return .success((data, meta))
        } catch {
            return .failure(Fail(message: error.localizedDescription))
        }
    }

    private static func command(_ recipe: Recipe, account: AccountSpec, pin: RecipePin.Pin,
                                start: Date) async -> Result<Output, Fail> {
        guard CommandRun.validateEnvironment(recipe.fetch.environment) else {
            return .failure(Fail(message: L.t("rc.envdenied")))
        }
        guard let binary = pin.binary, let home = CommandRun.validHome(
            recipe.fetch.homeFromAccount ? (account.home ?? "~") : "~") else {
            return .failure(Fail(message: L.t("rc.reapprove")))
        }
        let attempt = await Task.detached(priority: .utility) {
            CommandRun.attempt(binary: binary, args: recipe.fetch.args, home: home,
                               timeout: recipe.fetch.timeout,
                               environment: recipe.fetch.environment)
        }.value
        guard attempt.exitCode == 0 else {
            return .failure(Fail(message: attempt.stderr.isEmpty ? L.t("rc.command.failed") : attempt.stderr))
        }
        let meta = RecipeFetchMeta(request: ([binary] + recipe.fetch.args).joined(separator: " "),
            status: Int(attempt.exitCode ?? 0), bytes: attempt.stdout.count,
            elapsed: Date().timeIntervalSince(start), contentType: "application/json", snapshotAt: nil)
        return .success((attempt.stdout, meta))
    }

    private static let maxFileBytes = 8 * 1024 * 1024

    private static func file(_ recipe: Recipe, pin: RecipePin.Pin,
                             start: Date) -> Result<Output, Fail> {
        guard let folder = pin.folder, let glob = recipe.fetch.glob, fileGlobIsSafe(glob),
              let path = pickFile(in: folder, glob: glob, pick: recipe.fetch.pick,
                                  format: recipe.map.format) else {
            return .failure(Fail(message: L.t("rc.file.failed")))
        }
        let root = URL(fileURLWithPath: folder).standardizedFileURL.path + "/"
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root) else {
            return .failure(Fail(message: L.t("rc.file.failed")))
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= maxFileBytes,
              let data = FileManager.default.contents(atPath: resolved) else {
            return .failure(Fail(message: L.t("rc.file.failed")))
        }
        let stamp = attrs?[.modificationDate] as? Date
        let contentType = recipe.map.format == "jsonl" ? "application/x-ndjson" : "application/json"
        return .success((data, RecipeFetchMeta(request: "READ \(resolved)", status: nil,
            bytes: data.count, elapsed: Date().timeIntervalSince(start),
            contentType: contentType, snapshotAt: stamp)))
    }

    private static func credential(_ recipe: Recipe, account: AccountSpec) -> Result<String?, Fail> {
        if let message = Credential.validateRecipeCredential(recipe, account: account) {
            return .failure(Fail(message: message))
        }
        switch recipe.credential.source {
        case "none": return .success(nil)
        case "keychain":
            if Credential.isForbiddenForRecipes(service: account.keychainService) {
                return .failure(Fail(message: L.t("rc.forbidden.keychain")))
            }
            return Credential.read(account).map(Optional.some)
        case "keyFile":
            var source = account
            source.keyFile = account.keyFile ?? recipe.credential.path
            source.keyJSONField = account.keyJSONField ?? recipe.credential.jsonField
            return Credential.read(source).map(Optional.some)
        case "env":
            guard let name = recipe.credential.name, !name.isEmpty else {
                return .failure(Fail(message: L.t("e.notoken")))
            }
            var source = account; source.keychainService = nil; source.keyFile = "env:\(name)"
            return Credential.read(source).map(Optional.some)
        case "appKeychain":
            guard let service = recipe.credential.service,
                  !Credential.isForbiddenForRecipes(service: service),
                  !Keychain.readsViaSecurityTool(service) else {
                return .failure(Fail(message: L.t("rc.forbidden.keychain")))
            }
            let rawResult: Result<String, Fail>
            if let hook = appKeychainTestHook {
                rawResult = hook(service)
            } else {
                rawResult = Keychain.genericPassword(service: service)
            }
            switch rawResult {
            case .failure(let fail): return .failure(fail)
            case .success(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
                    return .failure(Fail(message: L.t("e.notoken")))
                }
                if let field = recipe.credential.jsonField, !field.isEmpty {
                    guard let found = Credential.unwrap(json: obj, field: field) else {
                        return .failure(Fail(message: L.t("k.field.missing")))
                    }
                    return .success(found)
                }
                guard let found = Credential.unwrap(json: obj, field: nil) else {
                    return .failure(Fail(message: L.t("k.field.missing")))
                }
                return .success(found)
            }
        default: return .failure(Fail(message: L.t("rc.bad.credential")))
        }
    }

    private static func pickFile(in folder: String, glob: String, pick: String,
                                 format: String) -> String? {
        let matches = matchingFiles(in: folder, glob: glob)
        guard !matches.isEmpty else { return nil }
        switch pick {
        case "first":
            return matches.sorted { $0.path < $1.path }.first?.path
        case "last":
            return matches.sorted { $0.path < $1.path }.last?.path
        case let p where p.hasPrefix("newestBy:"):
            let path = String(p.dropFirst("newestBy:".count))
            var best: (FileMatch, Double)?
            for match in matches {
                guard let stamp = fileSortKey(match.path, path: path, format: format) else { continue }
                if best == nil || stamp > best!.1 { best = (match, stamp) }
            }
            return best?.0.path ?? matches.max(by: { $0.modified < $1.modified })?.path
        default:
            return matches.max(by: { $0.modified < $1.modified })?.path
        }
    }

    private struct FileMatch {
        var path: String
        var modified: Date
    }

    private static func matchingFiles(in folder: String, glob: String) -> [FileMatch] {
        let root = URL(fileURLWithPath: folder).standardizedFileURL
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let regex = globRegex(glob)
        var out: [FileMatch] = []
        for case let url as URL in e {
            let relative = String(url.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
            let range = NSRange(relative.startIndex..<relative.endIndex, in: relative)
            guard regex?.firstMatch(in: relative, range: range) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maxFileBytes else { continue }
            out.append(FileMatch(path: url.path, modified: values.contentModificationDate ?? .distantPast))
        }
        return out
    }

    private static func fileSortKey(_ path: String, path jsonPath: String, format: String) -> Double? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if format == "jsonl" {
            return pickRecordField(data, pick: "newestBy:\(jsonPath)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let raw = RecipeMap.value(at: jsonPath, in: obj) else { return nil }
        switch Parse.number(raw) {
        case .value(let n): return n
        case .missing, .invalid:
            if let text = raw as? String { return ISO8601DateFormatter().date(from: text)?.timeIntervalSince1970 }
            return nil
        }
    }

    private static func pickRecordField(_ data: Data, pick: String) -> Double? {
        guard pick.hasPrefix("newestBy:") else { return nil }
        let jsonPath = String(pick.dropFirst("newestBy:".count))
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var best: Double?
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let raw = RecipeMap.value(at: jsonPath, in: obj) else { continue }
            let stamp: Double?
            switch Parse.number(raw) {
            case .value(let n): stamp = n
            case .missing, .invalid:
                stamp = (raw as? String).flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }
            }
            guard let stamp else { continue }
            if best == nil || stamp > best! { best = stamp }
        }
        return best
    }

    private static func globRegex(_ glob: String) -> NSRegularExpression? {
        var pattern = "^", i = glob.startIndex
        while i < glob.endIndex {
            let ch = glob[i]
            if ch == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    let afterStar = glob.index(after: next)
                    if afterStar < glob.endIndex, glob[afterStar] == "/" {
                        pattern += "(?:.*/)?"
                        i = glob.index(after: afterStar)
                    } else {
                        pattern += ".*"
                        i = afterStar
                    }
                } else {
                    pattern += "[^/]*"
                    i = next
                }
            } else if ch == "?" { pattern += "[^/]"; i = glob.index(after: i) }
            else { pattern += NSRegularExpression.escapedPattern(for: String(ch)); i = glob.index(after: i) }
        }
        return try? NSRegularExpression(pattern: pattern + "$")
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
