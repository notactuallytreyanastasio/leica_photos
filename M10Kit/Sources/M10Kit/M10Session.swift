import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A PTP/IP session with a Leica M10, implementing the exact protocol
/// captured from a real camera (research/protocol-notes.md).
///
/// Safety posture (non-negotiable, see GentleClientRules):
/// - first timeout aborts the session and closes cleanly — no retries
/// - hard session duration cap
/// - pauses between object queries
/// - clean close: LE_CloseSession + CloseSession, then sockets
public final class M10Session: @unchecked Sendable {

    private let queue = DispatchQueue(label: "m10.session")   // all camera I/O
    private var rules: GentleClientRules
    private let host: String
    private let port: UInt16

    // state (queue only)
    private var cmdFD: Int32 = -1
    private var evtFD: Int32 = -1
    private var transactionID: UInt32 = 0
    private var sessionStart: Date?
    private var rxBuffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private(set) public var cameraName: String = ""
    private(set) public var connectionID: UInt32 = 0

    public init(host: String, port: UInt16 = 15740,
                rules: GentleClientRules = GentleClientRules()) {
        self.host = host
        self.port = port
        self.rules = rules
    }

    // MARK: - Connection & session

    /// Connect + handshake + dual session open (the M10's required
    /// choreography: OpenSession(0xFFFF) then LE vendor OpenSession(0xFF55)).
    public func connectAndOpenSession() throws {
        try queue.sync {
            try connectSockets()
            try handshake()
            try openSession()
            sessionStart = Date()
            startPingLoop()
        }
    }

    private func connectSockets() throws {
        cmdFD = try tcpConnect(host: host, port: port)
        evtFD = try tcpConnect(host: host, port: port)
    }

    private func handshake() throws {
        // Init Command Request: GUID + hostname (UTF16+NUL) + version 1.0
        let hostName = ProcessInfo.processInfo.hostName
        var payload = Data(UUID().uuidString.utf16.prefix(16).map { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8(unit >> 8)]
        }.flatMap { $0 })
        payload.append(contentsOf: [0, 0])
        var ver = Data(); ver.appendLE(UInt32(0x00010000))
        payload.append(ver)
        try send(cmdFD, PtpIpCodec.encode(.initCommandRequest, payload: payload))

        let ack = try recvPacket(cmdFD, timeout: rules.operationTimeout)
        switch ack.type {
        case .initFail:
            throw M10Error.initFailed(reason: ack.payload.withUnsafeBytes { $0.load(as: UInt32.self) })
        case .initCommandAck:
            var r = LEReader(ack.payload)
            connectionID = (try? r.u32()) ?? 0
            cameraName = (try? r.utf16z()) ?? ""
        default:
            throw M10Error.unexpectedPacket("wanted InitCommandAck, got \(ack.type)")
        }

        // Init Event Request on the second connection
        var evt = Data(); evt.appendLE(connectionID)
        try send(evtFD, PtpIpCodec.encode(.initEventRequest, payload: evt))
        let evtAck = try recvPacket(evtFD, timeout: rules.operationTimeout)
        guard evtAck.type == .initEventAck else {
            throw M10Error.unexpectedPacket("wanted InitEventAck, got \(evtAck.type)")
        }
    }

    private func openSession() throws {
        _ = try transactNoData(PtpOpcode.openSession, params: [0xFFFF])
        _ = try transactNoData(PtpOpcode.leOpenSession, params: [0xFF55])
    }

    /// Clean close: vendor close, standard close, then sockets down.
    /// Never throws — best effort by design.
    public func close() {
        queue.sync {
            if cmdFD >= 0 {
                _ = try? transactNoData(PtpOpcode.leCloseSession, params: [0xFF55])
                _ = try? transactNoData(PtpOpcode.closeSession, params: [])
            }
            teardown()
        }
    }

    private func teardown() {
        pingTimer?.cancel(); pingTimer = nil
        if cmdFD >= 0 { Darwin.close(cmdFD); cmdFD = -1 }
        if evtFD >= 0 { Darwin.close(evtFD); evtFD = -1 }
    }

    private func startPingLoop() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self, self.evtFD >= 0 else { return }
            try? self.send(self.evtFD, PtpIpCodec.encode(.ping))
        }
        t.resume()
        pingTimer = t
    }

    // MARK: - Operations

    public func deviceInfo() throws -> DeviceInfo {
        let blob = try queue.sync { try transactData(PtpOpcode.getDeviceInfo) }
        return try DeviceInfo(data: blob)
    }

    public func batteryPercent() throws -> Int {
        let raw = try queue.sync { try transactData(PtpOpcode.getDevicePropValue, params: [0x5001, 0]) }
        return raw.first.map(Int.init) ?? -1
    }

    public func objectHandles(storage: UInt32 = 0xFFFF_FFFF, format: UInt16 = 0) throws -> [UInt32] {
        let blob = try queue.sync { try transactData(PtpOpcode.getObjectHandles, params: [storage, UInt32(format), 0]) }
        var r = LEReader(blob)
        guard let n = try? r.u32(), n <= 100_000,
              let handles = try? (0..<n).map({ _ in try r.u32() }) else {
            throw M10Error.parse("object handles")
        }
        return handles
    }

    public func objectInfo(handle: UInt32) throws -> ObjectInfo {
        defer { Thread.sleep(forTimeInterval: rules.interQueryPause) }
        let blob = try queue.sync { try transactData(PtpOpcode.getObjectInfo, params: [handle]) }
        return try ObjectInfo(data: blob, handle: handle)
    }

    public func thumbnail(handle: UInt32) throws -> Data {
        defer { Thread.sleep(forTimeInterval: rules.interQueryPause) }
        return try queue.sync { try transactData(PtpOpcode.getThumb, params: [handle]) }
    }

    public func download(handle: UInt32,
                         progress: ((Int, Int) -> Void)? = nil) throws -> Data {
        try queue.sync { try transactData(PtpOpcode.getObject, params: [handle], progress: progress) }
    }

    // MARK: - Transaction engine (queue only)

    private func checkBudget() throws {
        if let start = sessionStart,
           Date().timeIntervalSince(start) > rules.maxSessionDuration {
            teardown()
            throw M10Error.sessionExpired
        }
    }

    private func nextTransaction() -> UInt32 {
        transactionID += 1
        return transactionID
    }

    private func transactNoData(_ opcode: UInt16, params: [UInt32]) throws -> CommandResponse {
        let tx = nextTransaction()
        try send(cmdFD, PtpIpCodec.commandRequest(opcode: opcode, transactionID: tx, params: params))
        while true {
            let pkt = try recvPacket(cmdFD, timeout: rules.operationTimeout)
            if let resp = parseResponse(pkt, wantTx: tx) { return resp }
        }
    }

    private func transactData(_ opcode: UInt16, params: [UInt32] = [],
                              progress: ((Int, Int) -> Void)? = nil) throws -> Data {
        try checkBudget()
        let tx = nextTransaction()
        try send(cmdFD, PtpIpCodec.commandRequest(opcode: opcode, transactionID: tx, params: params))
        var chunks: [Data] = []
        var total: Int = 0
        while true {
            let pkt = try recvPacket(cmdFD, timeout: rules.operationTimeout)
            switch pkt.type {
            case .startData:
                var r = LEReader(pkt.payload)
                _ = try? r.u32()
                total = Int(try r.u64())
            case .data:
                chunks.append(pkt.payload.dropFirst(4))
                if let progress, total > 0 {
                    progress(chunks.reduce(0) { $0 + $1.count }, total)
                }
            case .commandResponse:
                if let resp = parseResponse(pkt, wantTx: tx, strict: false) {
                    if resp.code != PtpResponseCode.ok.rawValue {
                        throw M10Error.cameraErrorResponse(resp.code, opcode: opcode)
                    }
                    guard pktWasForTransaction(pkt, tx: tx) else { continue }
                    return chunks.reduce(Data(), +)
                }
            default:
                break // events & friends arrive on the event socket anyway
            }
        }
    }

    private func pktWasForTransaction(_ pkt: PtpIpPacket, tx: UInt32) -> Bool {
        guard pkt.type == .commandResponse, pkt.payload.count >= 6 else { return false }
        let rtx = UInt32(leBytes: [UInt8](pkt.payload), at: 2)
        return rtx == tx
    }

    private func parseResponse(_ pkt: PtpIpPacket, wantTx: UInt32, strict: Bool = true) -> CommandResponse? {
        guard pkt.type == .commandResponse, pkt.payload.count >= 6 else { return nil }
        var r = LEReader(pkt.payload)
        guard let code = try? r.u16(), let rtx = try? r.u32() else { return nil }
        if strict && rtx != wantTx { return nil }
        var params: [UInt32] = []
        while let p = try? r.u32() { params.append(p) }
        return CommandResponse(code: code, transactionID: rtx, params: params)
    }

    // MARK: - Socket plumbing

    private func tcpConnect(host: String, port: UInt16) throws -> Int32 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw M10Error.cameraUnreachable("bad host \(host)")
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw M10Error.cameraUnreachable("socket() failed") }
        var connected = false
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connected = Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else {
            Darwin.close(fd)
            throw M10Error.cameraUnreachable("connect to \(host):\(port) failed")
        }
        return fd
    }

    private func send(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { throw M10Error.cameraUnreachable("write failed") }
                sent += n
            }
        }
    }

    /// Blocking read of one packet with timeout. Throws on timeout —
    /// callers treat that as fatal (first-timeout-abort rule).
    private func recvPacket(_ fd: Int32, timeout: TimeInterval) throws -> PtpIpPacket {
        let deadline = Date().addingTimeInterval(timeout)
        // header
        var header = Data(capacity: 8)
        while header.count < 8 {
            let chunk = try recvSome(fd, deadline: deadline)
            header.append(chunk)
        }
        let length = Int(UInt32(leBytes: [UInt8](header), at: 0))
        guard length >= 8, length < 64 * 1024 * 1024 else {
            throw M10Error.parse("packet length \(length)")
        }
        var payload = header.count > 8 ? header.subdata(in: 8..<header.count) : Data()
        while payload.count < length - 8 {
            let chunk = try recvSome(fd, deadline: deadline)
            payload.append(chunk)
        }
        let typeRaw = UInt32(leBytes: [UInt8](header), at: 4)
        guard let type = PtpIpPacketType(rawValue: typeRaw) else {
            throw M10Error.parse("packet type \(typeRaw)")
        }
        return PtpIpPacket(type: type, payload: payload)
    }

    private func recvSome(_ fd: Int32, deadline: Date) throws -> Data {
        var pollfd = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        let rc = poll(&pollfd, 1, remaining)
        if rc == 0 { throw M10Error.timeout(opcode: 0) }
        guard rc > 0 else { throw M10Error.cameraUnreachable("poll error") }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n == 0 { throw M10Error.cameraUnreachable("connection closed by camera") }
        if n < 0 { throw M10Error.cameraUnreachable("read error") }
        return Data(buf[0..<n])
    }
}
