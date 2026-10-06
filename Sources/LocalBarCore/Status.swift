import Foundation

public enum ServiceState: String, Sendable {
    case checking = "Checking", off = "Off", running = "Running", external = "Elsewhere"
    case starting = "Starting…", stopping = "Stopping…", restarting = "Restarting…"
    case failed = "Failed", unresponsive = "No response", unknown = "Unknown"
}

public struct Snapshot: Sendable, Equatable {
    public var state: ServiceState
    public var managed: Bool
    public var pid: Int32?
    public var detail: String
    public var routeWarning: Bool
    public var proxyResponded: Bool
    public var caddyDetected: Bool
    public init(state: ServiceState = .checking, managed: Bool = false, pid: Int32? = nil,
                detail: String = "Checking service status…", routeWarning: Bool = false,
                proxyResponded: Bool = false, caddyDetected: Bool = false) {
        self.state = state; self.managed = managed; self.pid = pid; self.detail = detail
        self.routeWarning = routeWarning; self.proxyResponded = proxyResponded; self.caddyDetected = caddyDetected
    }

    public static func evaluate(job: Job, portOpen: Bool, direct: HTTPResult, proxy: HTTPResult,
                                hasHealthCheck: Bool, configurationChanged: Bool = false) -> Snapshot {
        let healthy = hasHealthCheck ? direct.code.map { (200..<300).contains($0) } == true
            : direct.code.map { (100..<500).contains($0) } == true
        let routingFailed = !proxy.responded || proxy.code.map { $0 >= 500 } == true
        let state: ServiceState
        let detail: String
        if job.loaded {
            if job.pid == nil {
                state = .failed
                detail = "The process exited\(job.exitCode.map { " with code \($0)" } ?? ""). Open its logs for details."
            } else if !healthy {
                state = .unresponsive
                detail = direct.code.map { "The server returned HTTP \($0)." }
                    ?? "The process is running, but HTTP on its local port is not responding. \(direct.error ?? "")"
            } else {
                state = .running
                detail = routingFailed ? "The server responds directly, but its domain is unavailable. Check Caddy."
                    : "The server and its domain respond."
            }
        } else if portOpen {
            state = .external
            detail = "This port is in use outside Local Bar. Stop the server in its terminal, then start it here. Local Bar will not stop an unowned process."
        } else {
            state = .off; detail = "Stopped."
        }
        return Snapshot(state: state, managed: job.loaded, pid: job.pid,
                        detail: detail + (configurationChanged ? " Configuration changed. Restart to apply it." : ""),
                        routeWarning: state == .running && routingFailed,
                        proxyResponded: proxy.responded,
                        caddyDetected: proxy.server?.lowercased().contains("caddy") == true)
    }
}

public enum Monitor {
    public static func inspect(_ service: Service, using manager: Launchd) async -> Snapshot {
        do {
            let job = try await manager.job(service)
            let active = job.loaded ? await manager.recordedService(service) : service
            let open = await Probes.portOpen(active.port)
            guard active.healthPath != nil else {
                if job.loaded && job.pid == nil {
                    return Snapshot(state: .failed, managed: true, detail: "The process exited. Open its logs for details.")
                }
                if job.loaded {
                    return Snapshot(state: open ? .running : .unresponsive, managed: true, pid: job.pid,
                        detail: open ? "The process is running and its port is accepting connections. HTTP routing is not checked." : "The process is running, but its port is not accepting connections.")
                }
                return Snapshot(state: open ? .external : .off,
                    detail: open ? "This port is in use outside Local Bar. Stop the server in its terminal before starting it here." : "Stopped.")
            }
            guard open else {
                return Snapshot.evaluate(job: job, portOpen: false, direct: HTTPResult(code: nil, server: nil),
                    proxy: HTTPResult(code: nil, server: nil), hasHealthCheck: true)
            }
            async let direct = Probes.direct(active)
            var address = URLComponents(string: active.url)!
            address.path = active.healthPath!
            let healthURL = address.url!
            async let proxy = Probes.proxy(healthURL)
            return await Snapshot.evaluate(job: job, portOpen: open, direct: direct, proxy: proxy,
                                           hasHealthCheck: true, configurationChanged: active != service)
        } catch { return Snapshot(state: .unknown, detail: error.localizedDescription) }
    }
}
