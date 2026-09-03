#!/usr/bin/env python3
"""
ptpip_probe.py — minimal PTP/IP client for the Leica M10.

Wire format cross-verified against:
  - Wireshark epan/dissectors/packet-ptpip.c (decodes real captures)
  - libgphoto2 camlibs/ptp2/ptpip.c (working Nikon PTP/IP client)

Does exactly what Leica FOTOS / Leica Sync do (standard client traffic):
  connect -> InitCommand -> InitEvent -> OpenSession -> GetDeviceInfo -> dump

Usage: python3 ptpip_probe.py <host> [port]   (default port 15740)
"""

import socket
import struct
import sys
import uuid

# ---- PTP/IP packet types (verified: Wireshark + libgphoto2 agree) ----
INIT_CMD_REQ   = 1   # -> GUID(16) + utf16z name + u32 version (major<<16|minor)
INIT_CMD_ACK   = 2   # <- u32 connection number + GUID(16) + utf16z name
INIT_EVENT_REQ = 3   # -> u32 connection number
INIT_EVENT_ACK = 4   # <- empty
INIT_FAIL      = 5
CMD_REQUEST    = 6   # -> u32 dataphase (1=no/recv, 2=send) + u16 opcode + u32 txid + params
CMD_RESPONSE   = 7   # <- u16 respcode + u32 txid + params (up to 5)
EVENT          = 8
START_DATA     = 9   # <- u32 txid + u64 total length
DATA           = 10  # <- u32 txid + chunk
CANCEL         = 11
END_DATA       = 12  # <- u32 txid + final chunk

# ---- PTP standard opcodes / response codes ----
OC_GetDeviceInfo = 0x1001
OC_OpenSession   = 0x1002
OC_CloseSession  = 0x1003
RC_OK            = 0x2001


def utf16z(s: str) -> bytes:
    return s.encode("utf-16-le") + b"\x00\x00"


class PtpIp:
    def __init__(self, host, port=15740):
        self.host, self.port = host, port
        self.guid = uuid.uuid4().bytes
        self.conn = None
        self.txid = 0

    # ---------- framing: u32 length (incl. header) then u32 type ----------
    def _send(self, sock, ptype, payload=b""):
        sock.sendall(struct.pack("<II", 8 + len(payload), ptype) + payload)

    def _recv_exact(self, sock, n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("connection closed by camera")
            buf += chunk
        return buf

    def _recv(self, sock):
        length, ptype = struct.unpack("<II", self._recv_exact(sock, 8))
        if length < 8:
            raise ValueError(f"bad length {length}")
        return ptype, self._recv_exact(sock, length - 8)

    # ---------- connection ----------
    def connect(self):
        self.cmd = socket.create_connection((self.host, self.port), timeout=10)
        # Init Command Request: GUID + name + version 1.0 = 0x00010000
        self._send(self.cmd, INIT_CMD_REQ,
                   self.guid + utf16z("glm-funk-mac") + struct.pack("<I", 0x00010000))
        ptype, data = self._recv(self.cmd)
        if ptype == INIT_FAIL:
            reason = struct.unpack("<I", data)[0] if data else 0
            raise RuntimeError(f"InitFail from camera (reason {reason:#x})")
        if ptype != INIT_CMD_ACK:
            raise RuntimeError(f"expected InitCommandAck, got type {ptype}")
        self.conn = struct.unpack("<I", data[:4])[0]
        cam_guid = data[4:20].hex()
        end = data.index(b"\x00\x00", 20)
        if (end - 20) % 2:
            end += 1
        cam_name = data[20:end].decode("utf-16-le", "replace")
        print(f"[+] command channel up: camera={cam_name!r} conn_id={self.conn} guid={cam_guid}")

        # Init Event Request on a second TCP connection
        self.evt = socket.create_connection((self.host, self.port), timeout=10)
        self._send(self.evt, INIT_EVENT_REQ, struct.pack("<I", self.conn))
        ptype, data = self._recv(self.evt)
        if ptype != INIT_EVENT_ACK:
            raise RuntimeError(f"expected InitEventAck, got type {ptype}")
        print("[+] event channel up")

    # ---------- transactions ----------
    def _cmd(self, opcode, params=(), dataphase=1):
        self.txid += 1
        tx = self.txid
        payload = struct.pack("<I", dataphase) + struct.pack("<H", opcode) \
            + struct.pack("<I", tx) + struct.pack(f"<{len(params)}I", *params)
        self._send(self.cmd, CMD_REQUEST, payload)
        return tx

    def _drain_events(self):
        try:
            self.evt.setblocking(False)
            while True:
                try:
                    ptype, data = self._recv(self.evt)
                except (BlockingIOError, socket.timeout):
                    break
                if ptype == EVENT and len(data) >= 6:
                    ev = struct.unpack("<H", data[:2])[0]
                    print(f"    [event] code {ev:#06x}")
        finally:
            self.evt.setblocking(True)

    def transact(self, opcode, params=()):
        """No-data-phase transaction. Returns (respcode, params)."""
        tx = self._cmd(opcode, params, dataphase=1)
        while True:
            ptype, data = self._recv(self.cmd)
            if ptype == CMD_RESPONSE:
                code = struct.unpack("<H", data[:2])[0]
                rtx = struct.unpack("<I", data[2:6])[0]
                if rtx != tx:
                    continue
                rest = data[6:]
                rparams = struct.unpack(f"<{len(rest)//4}I", rest) if rest else ()
                return code, rparams
            self._drain_events()

    def transact_data(self, opcode, params=()):
        """Data-in transaction. Returns (respcode, blob)."""
        tx = self._cmd(opcode, params, dataphase=1)
        chunks, total = [], None
        while True:
            ptype, data = self._recv(self.cmd)
            if ptype == START_DATA:
                total = struct.unpack("<Q", data[4:12])[0]
            elif ptype == DATA:
                chunks.append(data[4:])
            elif ptype == END_DATA:
                chunks.append(data[4:])
                blob = b"".join(chunks)
                if total is not None and len(blob) != total:
                    print(f"    [warn] data length {len(blob)} != announced {total}")
                # response packet follows
                ptype2, data2 = self._recv(self.cmd)
                if ptype2 != CMD_RESPONSE:
                    raise RuntimeError(f"expected response after data, got {ptype2}")
                code = struct.unpack("<H", data2[:2])[0]
                return code, blob
            elif ptype == CMD_RESPONSE:
                code = struct.unpack("<H", data[:2])[0]
                return code, b""  # error path: no data
            self._drain_events()


def parse_deviceinfo(d: bytes):
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
    return out


KNOWN_OPS = {
    0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession",
    0x1004: "GetStorageIDs", 0x1005: "GetStorageInfo", 0x1006: "GetNumObjects",
    0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo", 0x1009: "GetObject",
    0x100A: "GetThumb", 0x100B: "DeleteObject", 0x100C: "SendObjectInfo",
    0x100D: "SendObject", 0x100F: "InitiateCapture", 0x1014: "GetDevicePropDesc",
    0x1015: "GetDevicePropValue", 0x1016: "SetDevicePropValue", 0x101B: "GetPartialObject",
    # MTP object property ops
    0x9801: "GetObjectPropsSupported", 0x9802: "GetObjectPropDesc",
    0x9803: "GetObjectPropValue", 0x9804: "SetObjectPropValue",
    0x9805: "GetObjectPropList", 0x9806: "SetObjectPropList",
    0x9807: "GetInterdependentPropDesc", 0x9808: "SendObjectPropList",
    0x9809: "GetObjectReferences", 0x980A: "SetObjectReferences",
    # Leica vendor ops (from libgphoto2 ptp.h / Lightroom plugin analysis)
    0x9001: "LE_SetCameraSettings", 0x9002: "LE_GetCameraSettings",
    0x9003: "LE_GetLensParameter", 0x9004: "LE_LEReleaseStages",
    0x9005: "LE_LEOpenSession", 0x9006: "LE_LECloseSession",
    0x9007: "LE_RequestObjectTransferReady", 0x9008: "LE_GetGeoTrackingData",
    0x9016: "LE_LEControlAutoFocus", 0x9019: "LE_LEControlBulbExposure",
    0x901c: "LE_LEControlPhotoLiveView", 0x901d: "LE_LEKeepSessionActive",
    0x9025: "LE_LEGetStreamData", 0x9030: "LE_OpenLiveViewSession",
    0x9036: "LE_LESetDateTime", 0x9037: "LE_GetObjectPropListPaginated",
    0x9100: "LE_OpenProductionSession", 0x9102: "LE_UpdateFirmware",
}


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.2"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 15740
    c = PtpIp(host, port)
    c.connect()

    print("[*] OpenSession...")
    code, params = c.transact(OC_OpenSession, [0xC0FFEE])
    print(f"    -> {code:#06x} {params}")
    if code != RC_OK:
        print("[!] session open failed; trying sessionless GetDeviceInfo")

    print("[*] GetDeviceInfo...")
    code, blob = c.transact_data(OC_GetDeviceInfo)
    print(f"    -> {code:#06x}, {len(blob)} bytes")
    if code == RC_OK and blob:
        info = parse_deviceinfo(blob)
        print("\n================ M10 DEVICE INFO ================")
        for k in ("manufacturer", "model", "device_version", "serial",
                  "standard_version", "vendor_extension_id",
                  "vendor_extension_version", "vendor_extension_desc",
                  "functional_mode"):
            print(f"{k:26} {info[k]}")
        print("\n--- operations supported ---")
        for op in info["operations"]:
            print(f"  {op:#06x}  {KNOWN_OPS.get(op, '(unknown/vendor)')}")
        print(f"\n--- device properties ({len(info['device_props'])}) ---")
        print("  " + " ".join(f"{p:#06x}" for p in info["device_props"]))
        print("===================================================")
        with open("deviceinfo_raw.bin", "wb") as f:
            f.write(blob)
        print("[i] raw dump saved to research/deviceinfo_raw.bin")

    try:
        c.transact(OC_CloseSession)
        print("[+] session closed politely")
    except Exception as e:
        print(f"[-] CloseSession failed ({e}) — harmless")


if __name__ == "__main__":
    main()
