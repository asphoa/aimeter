import Foundation

enum Net {
    static let maxResponseBytes = 2 * 1024 * 1024
    static let resourceTimeout: TimeInterval = 60
    static let requestTimeout: TimeInterval = 20

    final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let originalURL: URL?
        let rejectAll: Bool
        init(originalURL: URL? = nil, rejectAll: Bool = false) {
            self.originalURL = originalURL
            self.rejectAll = rejectAll
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            if rejectAll { completionHandler(nil); return }
            let original = originalURL ?? task.originalRequest?.url
            completionHandler(Net.redirectTarget(originalURL: original, proposed: request))
        }
    }

    static func redirectTarget(originalURL: URL?, proposed request: URLRequest) -> URLRequest? {
        guard let originalURL, let proposedURL = request.url else { return nil }
        guard sameOrigin(originalURL, proposedURL) else { return nil }
        if originalURL.scheme?.lowercased() == "https",
           proposedURL.scheme?.lowercased() == "http" { return nil }
        return request
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let aHost = a.host, let bHost = b.host,
              aHost.caseInsensitiveCompare(bHost) == .orderedSame else { return false }
        let aScheme = (a.scheme ?? "https").lowercased()
        let bScheme = (b.scheme ?? "https").lowercased()
        return aScheme == bScheme && effectivePort(a) == effectivePort(b)
    }

    static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return (url.scheme ?? "https").lowercased() == "https" ? 443 : 80
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = resourceTimeout
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: SameHostRedirectDelegate(), delegateQueue: nil)
    }()

    enum JSONError: Error {
        case tooLarge
        case invalid
        case notHTTP
    }

    static func json(_ req: URLRequest, timeout: TimeInterval = requestTimeout) async throws -> (Any, HTTPURLResponse) {
        var request = req
        request.timeoutInterval = timeout
        let (data, resp) = try await limitedData(for: request, session: session)
        guard let http = resp as? HTTPURLResponse else { throw JSONError.notHTTP }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw JSONError.invalid }
        return (obj, http)
    }

    /// Accumulates response bytes up to `maxResponseBytes`; aborts with `.tooLarge`.
    static func limitedData(for request: URLRequest,
                            session: URLSession = Net.session,
                            maxBytes: Int = maxResponseBytes) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var collected = Data()
        collected.reserveCapacity(min(maxBytes, 64 * 1024))
        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                if collected.count + buffer.count > maxBytes { throw JSONError.tooLarge }
                collected.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if collected.count + buffer.count > maxBytes { throw JSONError.tooLarge }
        collected.append(contentsOf: buffer)
        return (collected, response)
    }

    static func get(_ url: String, bearer: String? = nil, timeout: TimeInterval = requestTimeout) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        return get(u, bearer: bearer, timeout: timeout)
    }

    static func get(_ url: URL, bearer: String? = nil, timeout: TimeInterval = requestTimeout) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        if let b = bearer { r.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        return r
    }
}
