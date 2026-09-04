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

    static func run(_ recipe: Recipe, account: AccountSpec,
                    pin suppliedPin: RecipePin.Pin? = nil) async -> Result<Output, Fail> {
        let start = Date()
        let pin: RecipePin.Pin
        if recipe.fetch.method == "none" { pin = RecipePin.Pin() }
        else if let suppliedPin { pin = suppliedPin }
        else if let stored = RecipePin.read(recipe.id) { pin = stored }
        else { return .failure(Fail(message: L.t("rc.reapprove"))) }
        guard recipe.legacy || RecipePin.matches(recipe, pin) else {
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
            var reading = RecipeMap.apply(recipe.map, to: output.data)
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

        let delegate = Net.SameHostRedirectDelegate(expectedHost: approved.host)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(Fail(message: L.t("e.nothttp")))
            }
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

    private static func file(_ recipe: Recipe, pin: RecipePin.Pin,
                             start: Date) -> Result<Output, Fail> {
        guard let folder = pin.folder, let glob = recipe.fetch.glob, fileGlobIsSafe(glob),
              let path = newestFile(in: folder, glob: glob) else {
            return .failure(Fail(message: L.t("rc.file.failed")))
        }
        let root = URL(fileURLWithPath: folder).standardizedFileURL.path + "/"
        let fixed = URL(fileURLWithPath: path).standardizedFileURL.path
        guard fixed.hasPrefix(root), let data = FileManager.default.contents(atPath: fixed) else {
            return .failure(Fail(message: L.t("rc.file.failed")))
        }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: fixed)[.modificationDate]) as? Date
        return .success((data, RecipeFetchMeta(request: "READ \(fixed)", status: nil,
            bytes: data.count, elapsed: Date().timeIntervalSince(start),
            contentType: "application/json", snapshotAt: stamp)))
    }

    private static func credential(_ recipe: Recipe, account: AccountSpec) -> Result<String?, Fail> {
        switch recipe.credential.source {
        case "none": return .success(nil)
        case "keychain":
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
            guard let service = recipe.credential.service, !Keychain.readsViaSecurityTool(service) else {
                return .failure(Fail(message: L.t("rc.forbidden.keychain")))
            }
            switch Keychain.genericPassword(service: service) {
            case .failure(let fail): return .failure(fail)
            case .success(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
                   let found = Credential.unwrap(json: obj, field: recipe.credential.jsonField) {
                    return .success(found)
                }
                return trimmed.isEmpty ? .failure(Fail(message: L.t("e.notoken"))) : .success(trimmed)
            }
        default: return .failure(Fail(message: L.t("rc.bad.credential")))
        }
    }

    private static func newestFile(in folder: String, glob: String) -> String? {
        let root = URL(fileURLWithPath: folder).standardizedFileURL
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let regex = globRegex(glob)
        var best: (String, Date)?
        for case let url as URL in e {
            let relative = String(url.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
            let range = NSRange(relative.startIndex..<relative.endIndex, in: relative)
            guard regex?.firstMatch(in: relative, range: range) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if best == nil || date > best!.1 { best = (url.path, date) }
        }
        return best?.0
    }

    private static func globRegex(_ glob: String) -> NSRegularExpression? {
        var pattern = "^", i = glob.startIndex
        while i < glob.endIndex {
            let ch = glob[i]
            if ch == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" { pattern += ".*"; i = glob.index(after: next) }
                else { pattern += "[^/]*"; i = next }
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
