#!/usr/bin/env python3
"""
parse_pcap.py — reassemble PTP/IP TCP streams from a pcap and produce a
readable transcript of the whole camera conversation.

Usage: python3 parse_pcap.py <pcapfile> [outfile]
"""

import struct
import sys

TYPE_NAMES = {1: "InitCommandReq", 2: "InitCommandAck", 3: "InitEventReq",
              4: "InitEventAck", 5: "InitFail", 6: "CmdRequest", 7: "CmdResponse",
              8: "Event", 9: "StartData", 10: "Data", 11: "Cancel", 12: "EndData",
              13: "Ping", 14: "Pong"}

OPS = {0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession",
       0x1004: "GetStorageIDs", 0x1005: "GetStorageInfo", 0x1006: "GetNumObjects",
       0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo", 0x1009: "GetObject",
       0x100A: "GetThumb", 0x100B: "DeleteObject", 0x1014: "GetDevicePropDesc",
       0x1015: "GetDevicePropValue", 0x1016: "SetDevicePropValue",
       0x101B: "GetPartialObject", 0x9801: "GetObjectPropsSupported",
       0x9802: "GetObjectPropDesc", 0x9803: "GetObjectPropValue",
       0x9805: "GetObjectPropList", 0x9005: "LE_OpenSession", 0x9006: "LE_CloseSession",
       0x9007: "LE_RequestObjectTransferReady", 0x9037: "LE_GetObjectPropListPaginated"}

RC = {0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen",
      0x2004: "InvalidTransactionID", 0x2005: "OperationNotSupported",
      0x2006: "ParameterNotSupported", 0x2008: "SessionAlreadyOpen",
      0x2013: "DeviceBusy", 0xA006: "AccessDenied"}


def read_pcap(path):
    with open(path, "rb") as f:
        data = f.read()
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian = "<"
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian = ">"
    elif magic == b"\x4d\x3c\xb2\xa1":
        endian = "<"  # nanosecond pcap
    else:
        raise ValueError(f"not a classic pcap (magic {magic.hex()})")
    _, _, _, _, _, _, linktype = struct.unpack(endian + "IHHiIII", data[:24])
    if linktype != 1:
        raise ValueError(f"link type {linktype}, want Ethernet(1)")
    off = 24
    pkts = []
    while off < len(data):
        ts_sec, ts_usec, incl, orig = struct.unpack(endian + "IIII", data[off:off + 16])
        off += 16
        pkts.append((ts_sec + ts_usec / 1e6, data[off:off + incl]))
        off += incl
    return pkts


def parse_tcp(payload):
    """Ethernet+IPv4+TCP -> (sport, dport, seq, flags, tcp_payload) or None"""
    if len(payload) < 34:
        return None
    etype = struct.unpack(">H", payload[12:14])[0]
    if etype != 0x0800:
        return None
    ihl = (payload[14] & 0x0F) * 4
    proto = payload[14 + 9]
    if proto != 6:
        return None
    total_len = struct.unpack(">H", payload[16:18])[0]
    src = ".".join(str(b) for b in payload[26:30])
    dst = ".".join(str(b) for b in payload[30:34])
    tcp = payload[14 + ihl:14 + total_len]
    sport, dport, seq = struct.unpack(">HHI", tcp[:8])
    off_flags = struct.unpack(">H", tcp[12:14])[0]
    doff = (off_flags >> 12) * 4
    flags = off_flags & 0x01FF
    return sport, dport, seq, flags, src, dst, tcp[doff:]


def reassemble(pkts, host_a="192.168.1.188", host_b="192.168.1.2", port=15740):
    """Return dict {(src,sport,dst,dport) -> ordered payload bytes} per connection."""
    streams = {}  # (src, sport, dst, dport) -> list of (seq, data)
    for ts, frame in pkts:
        t = parse_tcp(frame)
        if not t:
            continue
        sport, dport, seq, flags, src, dst, payload = t
        if port not in (sport, dport):
            continue
        if src not in (host_a, host_b) or dst not in (host_a, host_b):
            continue
        if payload:
            streams.setdefault((src, sport, dst, dport), []).append((seq, payload))
    out = {}
    for key, chunks in streams.items():
        chunks.sort(key=lambda c: c[0])
        buf = bytearray()
        expect = None
        for seq, payload in chunks:
            if expect is None:
                expect = seq
            if seq == expect:
                buf += payload
                expect = seq + len(payload)
            elif seq < expect:
                pass  # overlap; ignore
            else:
                # gap — insert placeholder
                buf += b"\x00" * (seq - expect) + payload
                expect = seq + len(payload)
        out[key] = bytes(buf)
    return out


def decode_packets(blob):
    """Split a reassembled stream into PTP/IP packets."""
    pkts = []
    off = 0
    while off + 8 <= len(blob):
        length, ptype = struct.unpack("<II", blob[off:off + 8])
        if length < 8 or off + length > len(blob):
            break
        pkts.append((ptype, blob[off + 8:off + length]))
        off += length
    return pkts


def fmt_ptp(ptype, payload):
    t = TYPE_NAMES.get(ptype, f"type{ptype}")
    if ptype == 6 and len(payload) >= 14:  # CmdRequest
        phase, opcode, txid = struct.unpack("<IHI", payload[:10])
        params = struct.unpack("<5I", payload[10:30]) if len(payload) >= 30 else \
            struct.unpack(f"<{(len(payload)-10)//4}I", payload[10:])
        return (f"CmdRequest  op={OPS.get(opcode, hex(opcode)):30} txid={txid} "
                f"phase={phase} params={[hex(p) for p in params]}")
    if ptype == 7 and len(payload) >= 6:  # CmdResponse
        code, txid = struct.unpack("<HI", payload[:6])
        params = struct.unpack(f"<{(len(payload)-6)//4}I", payload[6:]) if len(payload) > 6 else ()
        return (f"CmdResponse code={RC.get(code, hex(code)):22} txid={txid} "
                f"params={[hex(p) for p in params]}")
    if ptype == 8 and len(payload) >= 6:  # Event
        ev, txid = struct.unpack("<HI", payload[:6])
        return f"Event       code={hex(ev)} txid={txid}"
    if ptype == 9 and len(payload) >= 12:
        txid, total = struct.unpack("<IQ", payload[:12])
        return f"StartData   txid={txid} total={total} bytes"
    if ptype == 2 and len(payload) >= 20:
        conn = struct.unpack("<I", payload[:4])[0]
        end = payload.find(b"\x00\x00", 20)
        if end == -1:
            end = len(payload) - 2
        if (end - 20) % 2:
            end += 1
        name = payload[20:end].decode("utf-16-le", "replace")
        return f"InitCommandAck conn={conn} name={name!r}"
    if ptype in (10, 12):
        txid = struct.unpack("<I", payload[:4])[0]
        return f"{'Data' if ptype == 10 else 'EndData'}    txid={txid} ({len(payload)-4} bytes)"
    if ptype == 1:
        return f"InitCommandReq guid={payload[:16].hex()} name={payload[16:-4].decode('utf-16-le','replace')!r} ver={hex(struct.unpack('<I', payload[-4:])[0])}"
    if ptype == 3:
        return f"InitEventReq conn={struct.unpack('<I', payload[:4])[0]}"
    if ptype == 5:
        return f"InitFail    reason={hex(struct.unpack('<I', payload[:4])[0])}"
    return f"{t:12} ({len(payload)} bytes) {payload[:32].hex()}"


def main():
    pcap = sys.argv[1]
    out = open(sys.argv[2], "w") if len(sys.argv) > 2 else sys.stdout
    pkts = read_pcap(pcap)
    streams = reassemble(pkts)
    print(f"# {len(pkts)} frames, {len(streams)} streams", file=out)
    for key in sorted(streams):
        src, sport, dst, dport = key
        direction = "CLIENT ->" if src == "192.168.1.188" else "CAMERA ->"
        print(f"\n===== {src}:{sport} -> {dst}:{dport} ({direction}) =====", file=out)
        for ptype, payload in decode_packets(streams[key]):
            print(f"  {fmt_ptp(ptype, payload)}", file=out)
    if out is not sys.stdout:
        out.close()
        print(f"written {sys.argv[2]}")


if __name__ == "__main__":
    main()
