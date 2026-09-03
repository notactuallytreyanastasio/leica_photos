#!/usr/bin/env python3
"""
ptpip_probe3.py — clean PTP/IP client for the Leica M10, attempt #3.

Fix vs v1/v2: TRANSACTION IDS START AT 0 (gphoto2: ptp->Transaction_ID =
params->transaction_id++ with transaction_id initialized to 0). All our
previous fresh-camera attempts sent first txid=1 and got silence. The M10
appears to silently drop mis-sequenced transactions.

Also: single clean session only (the camera wedges after ~2 aborted
connection cycles), generous pacing, full tour on success:
  OpenSession -> GetDeviceInfo -> GetStorageIDs -> GetObjectHandles ->
  (count + first handles) -> CloseSession

Usage: python3 ptpip_probe3.py <host> [port]
"""

import socket
import struct
import sys
import time
import uuid

INIT_CMD_REQ, INIT_CMD_ACK, INIT_EVENT_REQ, INIT_EVENT_ACK = 1, 2, 3, 4
CMD_REQUEST, CMD_RESPONSE, START_DATA, DATA, END_DATA = 6, 7, 9, 10, 12

OC_GetDeviceInfo = 0x1001
OC_OpenSession = 0x1002
OC_CloseSession = 0x1003
OC_GetStorageIDs = 0x1004
OC_GetObjectHandles = 0x1007
RC_OK = 0x2001

TYPE_NAMES = {1: "InitCommandReq", 2: "InitCommandAck", 3: "InitEventReq",
              4: "InitEventAck", 5: "InitFail", 6: "CmdRequest", 7: "CmdResponse",
              8: "Event", 9: "StartData", 10: "Data", 11: "Cancel", 12: "EndData"}


def hexdump(b, limit=48):
    s = b[:limit].hex()
    return s + (f"... ({len(b)}B)" if len(b) > limit else f" ({len(b)}B)")


class Camera:
    def __init__(self, host, port=15740):
        self.host, self.port = host, port
        self.guid = uuid.uuid4().bytes
        self.conn = None
        self.txid = -1  # incremented BEFORE use -> first transaction id = 0

    def _send(self, sock, ptype, payload=b""):
        sock.sendall(struct.pack("<II", 8 + len(payload), ptype) + payload)

    def _recv_exact(self, sock, n, timeout=8.0):
        sock.settimeout(timeout)
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk
        return buf

    def _recv(self, sock, timeout=8.0):
        length, ptype = struct.unpack("<II", self._recv_exact(sock, 8, timeout))
        if length < 8:
            raise ValueError(f"bad length {length}")
        return ptype, self._recv_exact(sock, length - 8, timeout)

    def _report(self, arrow, ptype, payload):
        print(f"    {arrow} {TYPE_NAMES.get(ptype, f'type-{ptype}')} "
              f"len={8 + len(payload)} {hexdump(payload) if ptype not in (2,) else ''}")
        if ptype == 2 and len(payload) >= 20:
            end = payload.find(b"\x00\x00", 20)
            if end == -1:
                end = len(payload) - 2
            if (end - 20) % 2:
                end += 1
            print(f"       camera name: {payload[20:end].decode('utf-16-le', 'replace')!r}")

    def connect(self):
        print(f"  [connect {self.host}:{self.port}]")
        self.cmd = socket.create_connection((self.host, self.port), timeout=10)
        self._send(self.cmd, INIT_CMD_REQ,
                   self.guid + "glm-funk-probe3".encode("utf-16-le") + b"\x00\x00"
                   + struct.pack("<I", 0x00010000))
        ptype, payload = self._recv(self.cmd)
        self._report("<<C", ptype, payload)
        if ptype != INIT_CMD_ACK:
            raise RuntimeError(f"InitCommand failed (type {ptype})")
        self.conn = struct.unpack("<I", payload[:4])[0]
        print(f"       connection number: {self.conn}")
        time.sleep(0.3)
        self.evt = socket.create_connection((self.host, self.port), timeout=10)
        self._send(self.evt, INIT_EVENT_REQ, struct.pack("<I", self.conn))
        ptype, payload = self._recv(self.evt)
        self._report("<<E", ptype, payload)
        if ptype != INIT_EVENT_ACK:
            raise RuntimeError(f"InitEvent failed (type {ptype})")
        print("  [handshake OK]")

    def cmd_no_data(self, opcode, params=()):
        self.txid += 1
        tx = self.txid
        payload = struct.pack("<IH", 1, opcode) + struct.pack("<I", tx) \
            + struct.pack(f"<{len(params)}I", *params)
        print(f"  >> op={opcode:#06x} txid={tx} params={[hex(p) for p in params]}")
        self._send(self.cmd, CMD_REQUEST, payload)
        while True:
            ptype, payload = self._recv(self.cmd, timeout=8.0)
            self._report("<<C", ptype, payload)
            if ptype == CMD_RESPONSE and len(payload) >= 6:
                code, rtx = struct.unpack("<HI", payload[:6])
                if rtx == tx:
                    rest = payload[6:]
                    rp = struct.unpack(f"<{len(rest) // 4}I", rest) if rest else ()
                    return code, rp

    def cmd_data_in(self, opcode, params=()):
        self.txid += 1
        tx = self.txid
        payload = struct.pack("<IH", 1, opcode) + struct.pack("<I", tx) \
            + struct.pack(f"<{len(params)}I", *params)
        print(f"  >> op={opcode:#06x} txid={tx} params={[hex(p) for p in params]}")
        self._send(self.cmd, CMD_REQUEST, payload)
        chunks = []
        while True:
            ptype, payload = self._recv(self.cmd, timeout=8.0)
            self._report("<<C", ptype, payload)
            if ptype == START_DATA:
                total = struct.unpack("<Q", payload[4:12])[0]
                print(f"       (data phase: {total} bytes announced)")
            elif ptype in (DATA, END_DATA):
                chunks.append(payload[4:])
            elif ptype == CMD_RESPONSE and len(payload) >= 6:
                code, rtx = struct.unpack("<HI", payload[:6])
                if rtx == tx:
                    return code, b"".join(chunks)

    def close_clean(self):
        try:
            code, _ = self.cmd_no_data(OC_CloseSession)
            print(f"  [CloseSession -> {code:#06x}]")
        except Exception as e:
            print(f"  [CloseSession failed: {e}]")
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


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.2"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 15740
    cam = Camera(host, port)
    try:
        cam.connect()
        time.sleep(0.5)

        print("\n  === OpenSession (txid=0!) ===")
        code, params = cam.cmd_no_data(OC_OpenSession, [1])
        print(f"  [OpenSession -> {code:#06x} {params}]")
        if code != RC_OK:
            print("  [open failed — stopping to keep the camera healthy]")
            return

        print("\n  === GetDeviceInfo ===")
        code, blob = cam.cmd_data_in(OC_GetDeviceInfo)
        print(f"  [GetDeviceInfo -> {code:#06x}, {len(blob)} bytes]")
        if code == RC_OK and blob:
            info = parse_deviceinfo(blob)
            for k, v in info.items():
                if isinstance(v, list):
                    print(f"  {k:24} {len(v)} entries: " + " ".join(f"{x:#06x}" for x in v))
                else:
                    print(f"  {k:24} {v}")
            with open("deviceinfo_raw.bin", "wb") as f:
                f.write(blob)
            print("  [saved deviceinfo_raw.bin]")

        print("\n  === GetStorageIDs ===")
        code, blob = cam.cmd_data_in(OC_GetStorageIDs)
        if code == RC_OK and len(blob) >= 4:
            n = struct.unpack("<I", blob[:4])[0]
            sids = struct.unpack(f"<{n}I", blob[4:4 + 4 * n]) if n else ()
            print(f"  [storages: {n} -> {[hex(s) for s in sids]}]")
            sid = sids[0] if sids else 0
        else:
            print(f"  [GetStorageIDs -> {code:#06x}]")
            sid = 0

        print("\n  === GetObjectHandles (0=ALL) ===")
        code, blob = cam.cmd_data_in(OC_GetObjectHandles, [0xFFFFFFFF, 0, 0])
        if code == RC_OK and len(blob) >= 4:
            n = struct.unpack("<I", blob[:4])[0]
            handles = struct.unpack(f"<{min(n, 10)}I", blob[4:4 + 4 * min(n, 10)])
            print(f"  [TOTAL OBJECTS ON CAMERA: {n}]")
            print(f"  [first handles: {[hex(h) for h in handles]}]")
        else:
            print(f"  [GetObjectHandles -> {code:#06x}]")
    finally:
        print("\n  === CloseSession ===")
        cam.close_clean()
        print("\n  DONE (clean exit — camera should stay healthy)")


if __name__ == "__main__":
    main()
