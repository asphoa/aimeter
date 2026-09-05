import Foundation

/// A deliberately small, declarative description of one usage source. The
/// settings file is untrusted: these values describe data, never executable
/// Swift, interpolation, or shell text. RecipePin supplies the separately
/// approved destination at run time.
struct Recipe: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var colour: String
    var symbol: String?
    var credential: CredentialSource
    var fetch: FetchSpec
    var map: MapSpec
    var interval: Int

    /// Runtime-only marker for accounts.generic compatibility. It is not part
    /// of config.json and therefore cannot be enabled by editing that file.
    var legacy = false

    static let reservedIDs: Set<String> = [
        "claude", "codex", "agy", "openrouter", "deepseek", "local", "cursor", "generic"
    ]

    init(id: String, name: String, colour: String = "#6B7280", symbol: String? = nil,
         credential: CredentialSource = CredentialSource(), fetch: FetchSpec = FetchSpec(),
         map: MapSpec = MapSpec(), interval: Int = 900, legacy: Bool = false) {
        self.id = id; self.name = name; self.colour = colour; self.symbol = symbol
        self.credential = credential; self.fetch = fetch; self.map = map
        self.interval = interval; self.legacy = legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        colour = (try? c.decode(String.self, forKey: .colour)) ?? "#6B7280"
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        credential = (try? c.decode(CredentialSource.self, forKey: .credential)) ?? CredentialSource()
        fetch = (try? c.decode(FetchSpec.self, forKey: .fetch)) ?? FetchSpec()
        map = (try? c.decode(MapSpec.self, forKey: .map)) ?? MapSpec()
        interval = (try? c.decode(Int.self, forKey: .interval)) ?? 900
        legacy = false
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colour, symbol, credential, fetch, map, interval
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#,
                                options: .regularExpression) != nil
    }

    /// The old generic account becomes a recipe in memory only. Its approved
    /// base still comes from the old keychain item in RecipeProvider; no
    /// existing account or keychain item is migrated or rewritten.
    static func legacy(_ spec: AccountSpec) -> Recipe {
        Recipe(id: "generic", name: spec.name, colour: "#6B7280", symbol: nil,
               credential: CredentialSource(source: "keychain"),
               fetch: FetchSpec(method: "http", verb: "GET", baseURL: spec.baseURL,
                                path: spec.balancePath ?? "/", auth: "bearer"),
               map: MapSpec(gauges: [
                    GaugeSpec(label: L.t("g.balance", ""),
                              value: "balance,total_balance,credits,credit,remaining,amount",
                              unit: "usd", window: "other")
               ]), interval: 900, legacy: true)
    }
}

struct CredentialSource: Codable, Sendable, Equatable {
    var source: String
    var path: String?
    var jsonField: String?
    var name: String?
    var service: String?

    init(source: String = "none", path: String? = nil, jsonField: String? = nil,
         name: String? = nil, service: String? = nil) {
        self.source = source; self.path = path; self.jsonField = jsonField
        self.name = name; self.service = service
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decode(String.self, forKey: .source)) ?? "none"
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        jsonField = try? c.decodeIfPresent(String.self, forKey: .jsonField)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        service = try? c.decodeIfPresent(String.self, forKey: .service)
    }
}

struct FetchSpec: Codable, Sendable, Equatable {
    var method: String
    var verb: String
    /// The proposed destination remains visible in config for editing, but is
    /// never trusted. Save copies it into RecipePin; every run compares it to
    /// that pin and builds the URL from the pinned authority.
    var baseURL: String?
    var path: String?
    var auth: String
    var authName: String?
    var body: JSONValue?

    var binary: String?
    var args: [String]
    var homeFromAccount: Bool
    var timeout: Double
    var environment: [String: String]

    var folder: String?
    var glob: String?
    var pick: String

    init(method: String = "none", verb: String = "GET", baseURL: String? = nil,
         path: String? = nil, auth: String = "none", authName: String? = nil,
         body: JSONValue? = nil, binary: String? = nil, args: [String] = [],
         homeFromAccount: Bool = false, timeout: Double = 30,
         environment: [String: String] = [:], folder: String? = nil,
         glob: String? = nil, pick: String = "newest") {
        self.method = method; self.verb = verb; self.baseURL = baseURL; self.path = path
        self.auth = auth; self.authName = authName; self.body = body
        self.binary = binary; self.args = args; self.homeFromAccount = homeFromAccount
        self.timeout = timeout; self.environment = environment
        self.folder = folder; self.glob = glob; self.pick = pick
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FetchSpec()
        method = (try? c.decode(String.self, forKey: .method)) ?? d.method
        verb = (try? c.decode(String.self, forKey: .verb)) ?? d.verb
        baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL))
            ?? (try? c.decodeIfPresent(String.self, forKey: .base))
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        auth = (try? c.decode(String.self, forKey: .auth)) ?? d.auth
        authName = try? c.decodeIfPresent(String.self, forKey: .authName)
        body = try? c.decodeIfPresent(JSONValue.self, forKey: .body)
        binary = try? c.decodeIfPresent(String.self, forKey: .binary)
        args = (try? c.decode([String].self, forKey: .args)) ?? d.args
        homeFromAccount = (try? c.decode(Bool.self, forKey: .homeFromAccount)) ?? d.homeFromAccount
        timeout = (try? c.decode(Double.self, forKey: .timeout)) ?? d.timeout
        environment = (try? c.decode([String: String].self, forKey: .environment)) ?? d.environment
        folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        glob = try? c.decodeIfPresent(String.self, forKey: .glob)
        pick = (try? c.decode(String.self, forKey: .pick)) ?? d.pick
    }

    enum CodingKeys: String, CodingKey {
        case method, verb, baseURL, base, path, auth, authName, body
        case binary, args, homeFromAccount, timeout, environment, folder, glob, pick
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method, forKey: .method); try c.encode(verb, forKey: .verb)
        try c.encodeIfPresent(baseURL, forKey: .baseURL); try c.encodeIfPresent(path, forKey: .path)
        try c.encode(auth, forKey: .auth); try c.encodeIfPresent(authName, forKey: .authName)
        try c.encodeIfPresent(body, forKey: .body); try c.encodeIfPresent(binary, forKey: .binary)
        if !args.isEmpty { try c.encode(args, forKey: .args) }
        if homeFromAccount { try c.encode(homeFromAccount, forKey: .homeFromAccount) }
        try c.encode(timeout, forKey: .timeout)
        if !environment.isEmpty { try c.encode(environment, forKey: .environment) }
        try c.encodeIfPresent(folder, forKey: .folder); try c.encodeIfPresent(glob, forKey: .glob)
        try c.encode(pick, forKey: .pick)
    }
}

struct MapSpec: Codable, Sendable, Equatable {
    var format: String
    var gauges: [GaugeSpec]
    var lines: [LineSpec]
    var snapshotAt: String?

    init(format: String = "json", gauges: [GaugeSpec] = [], lines: [LineSpec] = [],
         snapshotAt: String? = nil) {
        self.format = format; self.gauges = gauges; self.lines = lines; self.snapshotAt = snapshotAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decode(String.self, forKey: .format)) ?? "json"
        gauges = (try? c.decode([GaugeSpec].self, forKey: .gauges)) ?? []
        lines = (try? c.decode([LineSpec].self, forKey: .lines)) ?? []
        snapshotAt = try? c.decodeIfPresent(String.self, forKey: .snapshotAt)
    }
}

struct GaugeSpec: Codable, Sendable, Equatable {
    var label: String
    var value: String?
    var used: String?
    var limit: String?
    var remaining: String?
    var unit: String
    var window: String
    var resetsAt: String?

    init(label: String, value: String? = nil, used: String? = nil, limit: String? = nil,
         remaining: String? = nil, unit: String = "percent", window: String = "other",
         resetsAt: String? = nil) {
        self.label = label; self.value = value; self.used = used; self.limit = limit
        self.remaining = remaining; self.unit = unit; self.window = window
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? "?"
        value = try? c.decodeIfPresent(String.self, forKey: .value)
        used = try? c.decodeIfPresent(String.self, forKey: .used)
        limit = try? c.decodeIfPresent(String.self, forKey: .limit)
        remaining = try? c.decodeIfPresent(String.self, forKey: .remaining)
        unit = (try? c.decode(String.self, forKey: .unit)) ?? "percent"
        window = (try? c.decode(String.self, forKey: .window)) ?? "other"
        resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

struct LineSpec: Codable, Sendable, Equatable {
    var value: String
    var prefix: String

    init(value: String, prefix: String = "") { self.value = value; self.prefix = prefix }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
        prefix = (try? c.decode(String.self, forKey: .prefix)) ?? ""
    }
}

/// Codable JSON for a fixed POST body. It is encoded exactly as entered and
/// supports no interpolation of credentials or other strings.
enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct RecipeDraft {
    var id = ""
    var name = ""
    var colour = "#3A8DDE"
    var symbol = "bolt"
    var credentialSource = "keychain"
    var credential = ""
    var credentialPath = ""
    var credentialName = ""
    var appKeychainService = ""
    var jsonField = ""
    var method = "http"
    var baseURL = ""
    var verb = "GET"
    var path = "/v1/credits"
    var auth = "bearer"
    var authName = ""
    var bodyJSON = ""
    var binary = ""
    var args = ""
    var environmentLines = ""
    var folder = ""
    var glob = "**/*.jsonl"
    var gaugeLabel = "Balance"
    var mapMode = "value"
    var gaugePath = "$.credits"
    var usedPath = ""
    var limitPath = ""
    var remainingPath = ""
    var unit = "usd"
    var window = "other"
    var resetsAt = ""
    var linePath = ""
    var linePrefix = ""
    var interval = 900
    var tested: RecipeTestResult?

    func recipe() -> Recipe {
        let cred = CredentialSource(source: credentialSource,
                                    path: credentialPath.isEmpty ? nil : credentialPath,
                                    jsonField: jsonField.isEmpty ? nil : jsonField,
                                    name: credentialName.isEmpty ? nil : credentialName,
                                    service: appKeychainService.isEmpty ? nil : appKeychainService)
        let argv = args.split(whereSeparator: \.isWhitespace).map(String.init)
        var environment: [String: String] = [:]
        for line in environmentLines.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            environment[parts[0]] = parts[1]
        }
        let body = bodyJSON.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self,
                                                                      from: Data(bodyJSON.utf8))
        let fetch = FetchSpec(method: method, verb: verb,
                              baseURL: baseURL.isEmpty ? nil : baseURL,
                              path: path.isEmpty ? nil : path, auth: auth,
                              authName: authName.isEmpty ? nil : authName,
                              body: body,
                              binary: binary.isEmpty ? nil : binary, args: argv,
                              homeFromAccount: true,
                              environment: environment,
                              folder: folder.isEmpty ? nil : folder,
                              glob: glob.isEmpty ? nil : glob)
        let gauge: GaugeSpec
        switch mapMode {
        case "usedLimit": gauge = GaugeSpec(label: gaugeLabel, used: usedPath, limit: limitPath,
                                              unit: unit, window: window, resetsAt: resetsAt.isEmpty ? nil : resetsAt)
        case "remainingLimit": gauge = GaugeSpec(label: gaugeLabel, limit: limitPath,
                                                   remaining: remainingPath, unit: unit, window: window,
                                                   resetsAt: resetsAt.isEmpty ? nil : resetsAt)
        case "remaining": gauge = GaugeSpec(label: gaugeLabel, remaining: remainingPath,
                                              unit: "fraction", window: window,
                                              resetsAt: resetsAt.isEmpty ? nil : resetsAt)
        default: gauge = GaugeSpec(label: gaugeLabel, value: gaugePath, unit: unit,
                                    window: window, resetsAt: resetsAt.isEmpty ? nil : resetsAt)
        }
        let lines = linePath.isEmpty ? [] : [LineSpec(value: linePath, prefix: linePrefix)]
        return Recipe(id: id, name: name, colour: colour,
                      symbol: symbol.isEmpty ? nil : symbol, credential: cred, fetch: fetch,
                      map: MapSpec(gauges: [gauge], lines: lines), interval: interval)
    }

    /// True when env/method/path/body differ from an approved baseline draft.
    func needsReapproval(comparedTo baseline: RecipeDraft) -> Bool {
        if method != baseline.method { return true }
        switch method {
        case "http":
            return verb != baseline.verb || path != baseline.path || bodyJSON != baseline.bodyJSON
        case "cli":
            return binary != baseline.binary || args != baseline.args
                || environmentLines != baseline.environmentLines
        default:
            return false
        }
    }
}
