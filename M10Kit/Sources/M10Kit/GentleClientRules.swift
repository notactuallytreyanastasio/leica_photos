import Foundation

/// Hard safety rules for talking to the M10.
///
/// Context (see research/RESEARCH_LOG.md, incident log): the M10's PTP/IP
/// server is fragile. Two aborted connection cycles can wedge it; a
/// malformed session-open makes it block forever; a wedged server can spin
/// (camera heats up and freezes). Every rule here exists because we
/// watched the camera misbehave without it.
public struct GentleClientRules: Sendable {
    /// Absolute wall-clock cap on a session. When it passes, the next
    /// operation throws instead of running.
    public var maxSessionDuration: TimeInterval = 120

    /// Per-operation timeout.
    public var operationTimeout: TimeInterval = 10

    /// Pause between consecutive object-level queries (ObjectInfo,
    /// GetThumb...) to keep the camera cool.
    public var interQueryPause: TimeInterval = 0.05

    public init() {}
}

public enum M10Error: Error, Sendable {
    case cameraUnreachable(String)
    case initFailed(reason: UInt32)
    case unexpectedPacket(String)
    case cameraErrorResponse(UInt16, opcode: UInt16)
    case timeout(opcode: UInt16)
    case sessionExpired
    case cameraWedged           // connect refused repeatedly — needs WiFi cycle
    case parse(String)
}
