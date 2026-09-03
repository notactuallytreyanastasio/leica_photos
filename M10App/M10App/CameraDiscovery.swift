import Foundation
import Network

/// Bonjour discovery of the camera's PTP/IP service (`_ptp._tcp`) on the
/// camera's WiFi network. The camera advertises as `LeicaM10-<serial>`.
enum CameraDiscovery {
    struct Endpoint: Sendable {
        let host: String
        let port: UInt16
    }

    static func findCamera(timeout: TimeInterval = 5) async throws -> Endpoint {
        // 1. browse for the service
        let serviceEndpoint = try await browse(timeout: timeout)
        // 2. resolve it by opening (and immediately closing) a connection —
        //    NWConnection performs the mDNS resolution for us and reports
        //    the concrete host/port in .ready state.
        return try await resolve(serviceEndpoint, timeout: timeout)
    }

    private static func browse(timeout: TimeInterval) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: "_ptp._tcp", domain: nil),
                                    using: .tcp)
            let state = ResolverState()
            browser.browseResultsChangedHandler = { results, _ in
                guard !state.done, let first = results.first else { return }
                state.done = true
                browser.cancel()
                continuation.resume(returning: first.endpoint)
            }
            browser.stateUpdateHandler = { s in
                if case .failed(let error) = s, !state.done {
                    state.done = true
                    continuation.resume(throwing: error)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !state.done {
                    state.done = true
                    browser.cancel()
                    continuation.resume(throwing: DiscoveryError.notFound)
                }
            }
            browser.start(queue: .global())
        }
    }

    private static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval) async throws -> Endpoint {
        try await withCheckedThrowingContinuation { continuation in
            let conn = NWConnection(to: endpoint, using: .tcp)
            let state = ResolverState()
            conn.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    guard !state.done else { return }
                    state.done = true
                    if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint ?? endpoint {
                        let hostStr: String
                        switch host {
                        case .ipv4(let a): hostStr = "\(a)"
                        case .ipv6(let a): hostStr = "\(a)"
                        case .name(let n, _): hostStr = n
                        @unknown default: hostStr = "\(host)"
                        }
                        conn.cancel()
                        continuation.resume(returning: Endpoint(host: hostStr, port: port.rawValue))
                    } else {
                        conn.cancel()
                        continuation.resume(throwing: DiscoveryError.notFound)
                    }
                case .failed(let error):
                    guard !state.done else { return }
                    state.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !state.done {
                    state.done = true
                    conn.cancel()
                    continuation.resume(throwing: DiscoveryError.notFound)
                }
            }
            conn.start(queue: .global())
        }
    }

    private final class ResolverState: @unchecked Sendable {
        var done = false
    }

    enum DiscoveryError: LocalizedError {
        case notFound
        var errorDescription: String? {
            "No Leica camera found. Are you joined to the camera's WiFi network?"
        }
    }
}
