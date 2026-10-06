import Foundation
import Network

public struct HTTPResult: Sendable {
    public let code: Int?
    public let server: String?
    public let error: String?
    public init(code: Int?, server: String?, error: String? = nil) {
        self.code = code; self.server = server; self.error = error
    }
    public var responded: Bool { code != nil }
    public var successful: Bool { code.map { (200..<400).contains($0) } ?? false }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum Probes {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public static func http(_ url: URL, hostHeader: String? = nil, method: String = "GET") async -> HTTPResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = method
        if let hostHeader { request.setValue(hostHeader, forHTTPHeaderField: "Host") }
        do {
            // The streaming API checks headers without retaining a dev server's response body.
            let (_, response) = try await session.bytes(for: request)
            let http = response as? HTTPURLResponse
            let identity = [http?.value(forHTTPHeaderField: "Server"), http?.value(forHTTPHeaderField: "Via")]
                .compactMap { $0 }.joined(separator: " ")
            return HTTPResult(code: http?.statusCode, server: identity)
        } catch { return HTTPResult(code: nil, server: nil, error: error.localizedDescription) }
    }

    public static func proxy(_ url: URL) async -> HTTPResult {
        guard let hostname = url.host?.lowercased(), url.scheme == "http",
              hostname == "localhost" || hostname.hasSuffix(".localhost") else { return await http(url) }
        // Browsers resolve *.localhost themselves; macOS URLSession does not.
        // For HTTP, connect to loopback while retaining Caddy's original Host routing.
        // HTTPS is left intact so TLS identity and certificate checks are never bypassed.
        let hostHeader = hostname + (url.port.map { ":\($0)" } ?? "")
        var v4 = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        v4.host = "127.0.0.1"
        var v6 = v4; v6.host = "[::1]"
        let v4URL = v4.url!, v6URL = v6.url!
        let first = await http(v4URL, hostHeader: hostHeader)
        return first.responded ? first : await http(v6URL, hostHeader: hostHeader)
    }

    public static func portOpen(_ port: Int) async -> Bool {
        async let ipv4 = tcp(host: "127.0.0.1", port: port)
        async let ipv6 = tcp(host: "::1", port: port)
        let result = await (ipv4, ipv6)
        return result.0 || result.1
    }

    public static func direct(_ service: Service) async -> HTTPResult {
        let path = service.healthPath ?? "/"
        func url(_ host: String) -> URL {
            var components = URLComponents()
            components.scheme = "http"; components.host = host; components.port = service.port
            components.percentEncodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/"
            return components.url!
        }
        let ipv4URL = url("127.0.0.1")
        let ipv6URL = url("[::1]")
        let first = await http(ipv4URL)
        return first.responded ? first : await http(ipv6URL)
    }

    private static func tcp(host: String, port: Int) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else { return false }
        return await withCheckedContinuation { continuation in
            TCPProbe(host: host, port: endpointPort, continuation: continuation).start()
        }
    }
}

// Mutable state is confined to this probe's serial queue. The timeout retains the probe
// until completion, and clearing the connection handler breaks the callback cycle.
private final class TCPProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.localbar.probe")
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Bool, Never>
    private var finished = false
    init(host: String, port: NWEndpoint.Port, continuation: CheckedContinuation<Bool, Never>) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.continuation = continuation
    }
    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 0.8) { [self] in finish(false) }
    }
    private func finish(_ result: Bool) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}
