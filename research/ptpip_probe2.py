#!/usr/bin/env python3
"""
ptpip_probe2.py — resilient PTP/IP prober for the Leica M10.

v1 made first contact (InitCommand/InitEvent handshake works, camera
identified as 'LEICA M10' at 192.168.1.2:15740) but OpenSession(0x1002)
was met with silence. This version:

  - logs EVERY packet received (type + hexdump), including events
  - reads the event channel on a background thread
  - lenient reader: if a partial packet stalls, dumps what arrived
  - tries a matrix of session-open strategies on fresh connections:
      1. GetDeviceInfo sessionless
      2. OpenSession(session=1) + GetDeviceInfo
      3. OpenSession(txid=0, session=0) + GetDeviceInfo
      4. Leica vendor LEOpenSession 0x9005(param 0) + GetDeviceInfo
      5. OpenSession(dataphase=0) + GetDeviceInfo

Usage: python3 ptpip_probe2.py <host> [port]
"""

import socket
import struct
import sys
import threading
import time
import uuid

INIT_CMD_REQ, INIT_CMD_ACK, INIT_EVENT_REQ, INIT_EVENT_ACK, INIT_FAIL = 1, 2, 3, 4, 5
CMD_REQUEST, CMD_RESPONSE, EVENT, START_DATA, DATA, CANCEL, END_DATA = 6, 7, 8, 9, 10, 11, 12

TYPE_NAMES = {1: "InitCommandReq", 2: "InitCommandAck", 3: "InitEventReq", 4: "InitEventAck",
              5: "InitFail", 6: "CmdRequest", 7: "CmdResponse", 8: "Event",
              9: "StartData", 10: "Data", 11: "Cancel", 12: "EndData"}

OC_GetDeviceInfo = 0x1001
OC_OpenSession = 0x1002
OC_CloseSession = 0x1003
RC_OK = 0x2001


def hexdump(b, limit=64):
    if len(b) > limit:
        return b[:limit].hex() + f"... ({len(b)} bytes total)"
    return b.hex() + (f" ({len(b)} bytes)" if b else " (empty)")


def utf16z(s):
    return s.encode("utf-16-le") + b"\x00\x00"


class Camera:
    def __init__(self, host, port=15740):
        self.host, self.port = host, port
        self.guid = uuid.uuid4().bytes
        self.conn = None
        self.txid = 0
        self.log = print

    def _send(self, sock, ptype, payload=b""):
        sock.sendall(struct.pack("<II", 8 + len(payload), ptype) + payload)

    def _recv_packet(self, sock, timeout=5.0):
        """Full packet or ('PARTIAL'/None, raw-bytes). Raises socket.timeout if nothing."""
        deadline = time.time() + timeout
        buf = b""
        got_some = False
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            sock.settimeout(remaining if not got_some else min(2.0, remaining))
            try:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
                got_some = True
                if len(buf) >= 8:
                    length, ptype = struct.unpack("<II", buf[:8])
                    if 8 <= length <= len(buf):
                        return ptype, buf[8:length]
                    if length < 8 or length > 50_000_000:
                        return None, buf  # nonsense length; dump raw
            except socket.timeout:
                if got_some:
                    break
                raise
        if buf:
            return "PARTIAL", buf
        raise socket.timeout("no data at all")

    def _report(self, arrow, ptype, payload):
        name = TYPE_NAMES.get(ptype, f"type-{ptype}")
        print(f"    {arrow} {name} len={8 + len(payload)}")
        if ptype == 2 and len(payload) >= 4:
            end = payload.index(b"\x00\x00", 4) if b"\x00\x00" in payload[4:] else len(payload)
            if (end - 4) % 2:
                end += 1
            print(f"       camera name: {payload[4:end].decode('utf-16-le', 'replace')!r}")
        elif ptype == 7 and len(payload) >= 6:
            code, tx = struct.unpack("<HI", payload[:6])
            print(f"       respcode={code:#06x} txid={tx} params={payload[6:].hex()}")
        elif ptype == 8 and len(payload) >= 6:
            ev, tx = struct.unpack("<HI", payload[:2] + payload[2:6])
            print(f"       eventcode={ev:#06x} txid={tx}")
        else:
            print(f"       {hexdump(payload)}")

    def _event_thread(self):
        while True:
            try:
                ptype, payload = self._recv_packet(self.evt, timeout=30.0)
            except (socket.timeout, OSError, ConnectionError):
                return
            self._report("<<E", ptype, payload)

    def connect(self):
        print(f"  [connect {self.host}:{self.port}]")
        self.cmd = socket.create_connection((self.host, self.port), timeout=10)
        self._send(self.cmd, INIT_CMD_REQ,
                   self.guid + utf16z("glm-funk-probe2") + struct.pack("<I", 0x00010000))
        ptype, payload = self._recv_packet(self.cmd)
        self._report("<<C", ptype, payload)
        if ptype != INIT_CMD_ACK:
            raise RuntimeError(f"InitCommand failed (type {ptype})")
        self.conn = struct.unpack("<I", payload[:4])[0]
        self.evt = socket.create_connection((self.host, self.port), timeout=10)
        self._send(self.evt, INIT_EVENT_REQ, struct.pack("<I", self.conn))
        ptype, payload = self._recv_packet(self.evt)
        self._report("<<E", ptype, payload)
        if ptype != INIT_EVENT_ACK:
            raise RuntimeError(f"InitEvent failed (type {ptype})")
        threading.Thread(target=self._event_thread, daemon=True).start()
        print("  [handshake OK]")

    def command(self, opcode, params=(), dataphase=1, tag=""):
        self.txid += 1
        tx = self.txid
        payload = struct.pack("<I", dataphase) + struct.pack("<H", opcode) \
            + struct.pack("<I", tx) + struct.pack(f"<{len(params)}I", *params)
        print(f"  >> CmdRequest op={opcode:#06x} txid={tx} phase={dataphase} params={[hex(p) for p in params]} {tag}")
        self._send(self.cmd, CMD_REQUEST, payload)
        return tx

    def wait_response(self, tx, timeout=6.0):
        """Waits for CmdResponse for tx; returns (code, params) or None."""
        try:
            while True:
                ptype, payload = self._recv_packet(self.cmd, timeout=timeout)
                self._report("<<C", ptype, payload)
                if ptype == 7 and len(payload) >= 6:
                    code, rtx = struct.unpack("<HI", payload[:6])
                    if rtx == tx:
                        rest = payload[6:]
                        rp = struct.unpack(f"<{len(rest) // 4}I", rest) if rest else ()
                        return code, rp
                if ptype == 9:  # StartData — data follows; gather
                    chunks = []
                    while True:
                        p2, pl2 = self._recv_packet(self.cmd, timeout=timeout)
                        self._report("<<C", p2, pl2)
                        if p2 in (10, 12):
                            chunks.append(pl2[4:])
                        if p2 == 12:
                            blob = b"".join(chunks)
                            print(f"       [collected {len(blob)} bytes of data]")
                            p3, pl3 = self._recv_packet(self.cmd, timeout=timeout)
                            self._report("<<C", p3, pl3)
                            if p3 == 7 and len(pl3) >= 6:
                                code, rtx = struct.unpack("<HI", pl3[:6])
                                if rtx == tx:
                                    return code, blob
                            return None, blob
        except socket.timeout:
            print(f"  .. no response within {timeout}s")
            return None, None

    def close(self):
        for s in ("cmd", "evt"):
            try:
                getattr(self, s).close()
            except Exception:
                pass


def parse_deviceinfo(d):
    off = 0
    out = {}
    def u16():
        nonlocal off
        v = struct.unpack_from("<H", d, off)[0]; off += 2; return v
    def u32():
        nonlocal off
        v = struct.unpack_from("<I", d, off)[0]; off += 4; return v
    def zstr():
        nonlocal off
        end = d.index(b"\x00", off)
        s = d[off:end].decode("ascii", "replace"); off = end + 1; return s
    def vec16():
        n = u16()
        return [u16() for _ in range(n)]
    try:
        out["standard_version"] = f"{u16():#06x}"
        out["vendor_extension_id"] = f"{u32():#010x}"
        out["vendor_extension_version"] = f"{u16():#06x}"
        out["vendor_extension_desc"] = zstr()
        out["functional_mode"] = f"{u16():#06x}"
        out["operations"] = vec16()
        out["events_supported"] = vec16()
        out["device_props"] = vec16()
        out["capture_formats"] = vec16()
        out["image_formats"] = vec16()
        out["manufacturer"] = zstr()
        out["model"] = zstr()
        out["device_version"] = zstr()
        try:
            out["serial"] = zstr()
        except ValueError:
            out["serial"] = "(none)"
    except Exception as e:
        out["parse_error"] = str(e)
    return out


def show_deviceinfo(blob):
    info = parse_deviceinfo(blob)
    print("\n  ================ M10 DEVICE INFO ================")
    for k, v in info.items():
        if isinstance(v, list):
            print(f"  {k:26} {len(v)} entries: " + " ".join(f"{x:#06x}" for x in v))
        else:
            print(f"  {k:26} {v}")
    print("  =================================================\n")
    with open("deviceinfo_raw.bin", "wb") as f:
        f.write(blob)
    print("  [saved deviceinfo_raw.bin]")


def attempt(name, host, port, opener):
    """opener: function(cam) -> None, raises on failure. Runs on fresh connection."""
    print(f"\n===== STRATEGY: {name} =====")
    cam = Camera(host, port)
    try:
        cam.connect()
        opener(cam)
    except Exception as e:
        print(f"  [strategy failed: {type(e).__name__}: {e}]")
    finally:
        try:
            cam.command(OC_CloseSession)
            cam.wait_response(cam.txid, timeout=3.0)
        except Exception:
            pass
        cam.close()
    time.sleep(1.0)  # let the camera drop the old connection


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.2"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 15740

    def after_session(cam):
        print("  >> GetDeviceInfo")
        cam.command(OC_GetDeviceInfo)
        code, data = cam.wait_response(cam.txid)
        if code == RC_OK and isinstance(data, (bytes, bytearray)) and data:
            show_deviceinfo(data)
        else:
            print(f"  [GetDeviceInfo result: code={code} data={None if data is None else type(data)}]")

    attempt("A: sessionless GetDeviceInfo", host, port,
            lambda cam: after_session(cam))

    def open_then_info(sid, tx_start=0, phase=1, opcode=OC_OpenSession):
        def f(cam):
            cam.txid = tx_start
            print(f"  >> session open op={opcode:#06x} sid={sid} phase={phase}")
            cam.command(opcode, [sid], dataphase=phase)
            code, params = cam.wait_response(cam.txid)
            print(f"  [session open response: {None if code is None else hex(code)}]")
            if code is not None:
                after_session(cam)
        return f

    attempt("B: OpenSession(sid=1) [gphoto2 style]", host, port, open_then_info(1, tx_start=0))
    attempt("C: OpenSession(sid=0, txid=0)", host, port, open_then_info(0, tx_start=0))
    attempt("D: Leica LEOpenSession 0x9005(param 0)", host, port, open_then_info(0, tx_start=0, opcode=0x9005))
    attempt("E: OpenSession(dataphase=0)", host, port, open_then_info(1, tx_start=0, phase=0))

    print("\n===== ALL STRATEGIES TRIED =====")


if __name__ == "__main__":
    main()
