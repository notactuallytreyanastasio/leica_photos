#!/usr/bin/env python3
"""
m10.py — Leica M10 PTP/IP client (prototype).

Implements the ground-truth protocol from research/protocol-notes.md
(captured from a real M10 via Leica Sync session, 2026-09-03):

  - framing: [u32 len][u32 type][payload], little-endian
  - CmdRequest: dataphase=0 ALWAYS, u16 opcode, u32 txid (from 1),
    ALWAYS 5 x u32 params (zero-padded)
  - session open: OpenSession(0xFFFF) THEN LE vendor OpenSession(0x9005, 0xFF55)
  - data-in: StartData(u32 txid + u64 total) -> Data chunk(s) -> Response
    (M10 never sends EndData)
  - event channel: second TCP connection; Ping (type 13) every 1s
  - be gentle: the camera wedges after ~2 aborted cycles

CLI:
  python3 m10.py validate              full tour, saves results to files
  python3 m10.py info                  device info summary
  python3 m10.py battery               battery level
  python3 m10.py count                 object count
  python3 m10.py list [-n 20]          newest-first photo list (info only)
  python3 m10.py thumb <handle> <out>  download thumbnail
  python3 m10.py download <handle> <out>
  python3 m10.py proplist <handle>     MTP object props (rating hunt!)
"""

import argparse
import socket
import struct
import sys
import threading
import time
import uuid

HOST = "192.168.1.2"
PORT = 15740

# packet types
INIT_CMD_REQ, INIT_CMD_ACK, INIT_EVENT_REQ, INIT_EVENT_ACK, INIT_FAIL = 1, 2, 3, 4, 5
CMD_REQUEST, CMD_RESPONSE, EVENT, START_DATA, DATA, CANCEL, END_DATA = 6, 7, 8, 9, 10, 11, 12
PING = 13

# opcodes
OC_GetDeviceInfo = 0x1001
OC_OpenSession = 0x1002
OC_CloseSession = 0x1003
OC_GetStorageIDs = 0x1004
OC_GetNumObjects = 0x1006
OC_GetObjectHandles = 0x1007
OC_GetObjectInfo = 0x1008
OC_GetObject = 0x1009
OC_GetThumb = 0x100A
OC_GetDevicePropValue = 0x1015
OC_GetObjectPropValue = 0x9803
OC_GetObjectPropsSupported = 0x9801
OC_LE_OpenSession = 0x9005
OC_LE_CloseSession = 0x9006

RC_OK = 0x2001
RC_NAMES = {0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen",
            0x2005: "OperationNotSupported", 0x2006: "ParameterNotSupported",
            0x2008: "SessionAlreadyOpen", 0x2013: "DeviceBusy",
            0xA006: "AccessDenied", 0xA802: "InvalidObjectHandle"}

# object formats
FMT_NAMES = {0x3001: "folder", 0x300d: "meta", 0x3801: "JPEG",
             0x3802: "DNG", 0x3808: "BMP", 0xb000: "RAW?",
             0x3811: "thumb-JPEG"}


class M10Error(Exception):
    pass


class M10:
    def __init__(self, host=HOST, port=PORT, verbose=True):
        self.host, self.port = host, port
        self.verbose = verbose
        self.txid = 0
        self.sid = 0xFFFF
        self._ping_stop = threading.Event()

    def log(self, *a):
        if self.verbose:
            print(*a)

    # ---------- framing ----------
    def _send(self, sock, ptype, payload=b""):
        sock.sendall(struct.pack("<II", 8 + len(payload), ptype) + payload)

    def _recv_exact(self, sock, n, timeout=10.0):
        sock.settimeout(timeout)
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("camera closed connection")
            buf += chunk
        return buf

    def _recv(self, sock, timeout=10.0):
        length, ptype = struct.unpack("<II", self._recv_exact(sock, 8, timeout))
        if length < 8:
            raise M10Error(f"bad packet length {length}")
        return ptype, self._recv_exact(sock, length - 8, timeout)

    # ---------- connection ----------
    def connect(self):
        self.log(f"[connect {self.host}:{self.port}]")
        self.cmd = socket.create_connection((self.host, self.port), timeout=10)
        guid = uuid.uuid4().bytes
        name = socket.gethostname().encode("utf-16-le") + b"\x00\x00"
        self._send(self.cmd, INIT_CMD_REQ, guid + name + struct.pack("<I", 0x00010000))
        ptype, payload = self._recv(self.cmd)
        if ptype == INIT_FAIL:
            raise M10Error(f"InitFail (reason {struct.unpack('<I', payload)[0]:#x})")
        if ptype != INIT_CMD_ACK:
            raise M10Error(f"expected InitCommandAck, got type {ptype}")
        self.conn = struct.unpack("<I", payload[:4])[0]
        end = payload.find(b"\x00\x00", 20)
        if end == -1:
            end = len(payload) - 2
        if (end - 20) % 2:
            end += 1
        self.camera_name = payload[20:end].decode("utf-16-le", "replace")
        self.log(f"[camera: {self.camera_name!r}, conn {self.conn}]")

        self.evt = socket.create_connection((self.host, self.port), timeout=10)
        self._send(self.evt, INIT_EVENT_REQ, struct.pack("<I", self.conn))
        ptype, payload = self._recv(self.evt)
        if ptype != INIT_EVENT_ACK:
            raise M10Error(f"expected InitEventAck, got type {ptype}")
        self._ping_thread = threading.Thread(target=self._ping_loop, daemon=True)
        self._ping_thread.start()
        self.log("[event channel up, pinging every 1s]")

    def _ping_loop(self):
        while not self._ping_stop.is_set():
            try:
                self._send(self.evt, PING)
            except OSError:
                return
            self._ping_stop.wait(1.0)

    # ---------- transactions ----------
    def _command(self, opcode, params=()):
        assert len(params) <= 5
        padded = list(params) + [0] * (5 - len(params))
        self.txid += 1
        tx = self.txid
        payload = struct.pack("<IHI", 0, opcode, tx) + struct.pack("<5I", *padded)
        self._send(self.cmd, CMD_REQUEST, payload)
        return tx

    def _drain_events(self):
        """Non-blocking: read + report any pending event packets."""
        try:
            self.evt.setblocking(False)
            while True:
                try:
                    hdr = self.evt.recv(8)
                    if not hdr or len(hdr) < 8:
                        break
                    length, ptype = struct.unpack("<II", hdr)
                    if length > 8:
                        rest = self.evt.recv(length - 8)
                    if ptype == EVENT:
                        self.log("[event received]")
                except (BlockingIOError, socket.timeout):
                    break
        finally:
            self.evt.setblocking(True)

    def transact(self, opcode, params=(), timeout=10.0):
        tx = self._command(opcode, params)
        while True:
            ptype, payload = self._recv(self.cmd, timeout)
            if ptype == CMD_RESPONSE and len(payload) >= 6:
                code, rtx = struct.unpack("<HI", payload[:6])
                if rtx != tx:
                    continue
                rest = payload[6:]
                rp = struct.unpack(f"<{len(rest) // 4}I", rest) if rest else ()
                if code != RC_OK:
                    raise M10Error(f"op {opcode:#06x} -> {RC_NAMES.get(code, hex(code))}")
                return rp
            self._drain_events()

    def transact_data(self, opcode, params=(), timeout=15.0, progress=None):
        tx = self._command(opcode, params)
        chunks, total = [], None
        while True:
            ptype, payload = self._recv(self.cmd, timeout)
            if ptype == START_DATA:
                total = struct.unpack("<Q", payload[4:12])[0]
            elif ptype == DATA:
                chunks.append(payload[4:])
                if progress and total:
                    progress(sum(len(c) for c in chunks), total)
            elif ptype == CMD_RESPONSE and len(payload) >= 6:
                code, rtx = struct.unpack("<HI", payload[:6])
                if rtx == tx:
                    if code != RC_OK:
                        raise M10Error(f"op {opcode:#06x} -> {RC_NAMES.get(code, hex(code))}")
                    return b"".join(chunks)
            self._drain_events()

    # ---------- session ----------
    def open_session(self):
        self.log("[open session: OpenSession(0xFFFF) + LE_OpenSession(0xFF55)]")
        self.transact(OC_OpenSession, [self.sid])
        time.sleep(0.2)
        self.transact(OC_LE_OpenSession, [0xFF55])
        self.log("[session open]")

    def close_session(self):
        for opcode, params, what in ((OC_LE_CloseSession, [0xFF55], "LE_CloseSession"),
                                     (OC_CloseSession, [], "CloseSession")):
            try:
                self.transact(opcode, params, timeout=5.0)
                self.log(f"[{what} OK]")
            except Exception as e:
                self.log(f"[{what}: {e}]")
        self._ping_stop.set()
        try:
            self.cmd.close()
            self.evt.close()
        except OSError:
            pass
        self.log("[disconnected]")

    # ---------- high-level ----------
    def device_info(self):
        d = self.transact_data(OC_GetDeviceInfo)
        off = 0

        def u16():
            nonlocal off
            v = struct.unpack_from("<H", d, off)[0]; off += 2; return v

        def u32():
            nonlocal off
            v = struct.unpack_from("<I", d, off)[0]; off += 4; return v

        def pstr():
            nonlocal off
            n = d[off]; off += 1
            s = d[off:off + 2 * n].decode("utf-16-le", "replace").rstrip("\x00")
            off += 2 * n
            return s

        def arr():
            n = u32()
            return [u16() for _ in range(n)]

        info = {
            "standard_version": hex(u16()),
            "vendor_extension_id": hex(u32()),
            "vendor_extension_version": hex(u16()),
            "vendor_extension_desc": pstr(),
            "functional_mode": hex(u16()),
            "operations": arr(),
            "events": arr(),
            "device_props": arr(),
            "capture_formats": arr(),
            "image_formats": arr(),
            "manufacturer": pstr(),
            "model": pstr(),
            "device_version": pstr(),
            "serial": pstr(),
        }
        return info

    def device_prop(self, code):
        return self.transact_data(OC_GetDevicePropValue, [code, 0])

    def storage_ids(self):
        d = self.transact_data(OC_GetStorageIDs)
        n = struct.unpack("<I", d[:4])[0]
        return list(struct.unpack(f"<{n}I", d[4:4 + 4 * n]))

    def object_handles(self, storage=0xFFFFFFFF, fmt=0):
        d = self.transact_data(OC_GetObjectHandles, [storage, fmt, 0])
        n = struct.unpack("<I", d[:4])[0]
        return list(struct.unpack(f"<{n}I", d[4:4 + 4 * n]))

    def object_info(self, handle):
        d = self.transact_data(OC_GetObjectInfo, [handle])
        off = 0

        def u16():
            nonlocal off
            v = struct.unpack_from("<H", d, off)[0]; off += 2; return v

        def u32():
            nonlocal off
            v = struct.unpack_from("<I", d, off)[0]; off += 4; return v

        def pstr():
            nonlocal off
            n = d[off]; off += 1
            s = d[off:off + 2 * n].decode("utf-16-le", "replace").rstrip("\x00")
            off += 2 * n
            return s

        storage = u32(); fmt = u16(); prot = u16(); size = u32()
        tfmt = u16(); tsize = u32(); tw = u32(); th = u32()
        iw = u32(); ih = u32(); depth = u32(); parent = u32()
        atype = u16(); adesc = u32(); seq = u32()
        filename = pstr(); cdate = pstr(); mdate = pstr()
        return {
            "handle": handle, "storage": hex(storage), "format": FMT_NAMES.get(fmt, hex(fmt)),
            "format_code": hex(fmt), "size": size, "thumb_size": tsize,
            "thumb_wxh": (tw, th), "pixels": (iw, ih), "parent": hex(parent),
            "filename": filename, "captured": cdate, "modified": mdate,
        }

    def thumb(self, handle):
        return self.transact_data(OC_GetThumb, [handle], timeout=20.0)

    def download(self, handle, out_path, progress=None):
        data = self.transact_data(OC_GetObject, [handle], timeout=60.0, progress=progress)
        with open(out_path, "wb") as f:
            f.write(data)
        return len(data), data[:12]

    def object_props_supported(self, handle):
        """MTP: which object properties exist for this object."""
        return self.transact_data(OC_GetObjectPropsSupported, [handle, 0])

    def object_prop(self, handle, prop):
        return self.transact_data(OC_GetObjectPropValue, [handle, prop, 0])


def print_obj(oi):
    print(f"  {oi['handle']:#010x}  {oi['filename']:24} {oi['format']:6} "
          f"{oi['size'] / 1e6:7.1f}MB  {oi['pixels'][0]}x{oi['pixels'][1]}  {oi['captured']}")


def cmd_validate(cam):
    """Full validation tour. Saves everything to files. Gentle pacing."""
    results = []

    def step(name, fn):
        print(f"\n=== {name} ===")
        try:
            out = fn()
            results.append((name, "OK"))
            return out
        except Exception as e:
            print(f"  FAILED: {type(e).__name__}: {e}")
            results.append((name, f"FAIL: {e}"))
            return None

    cam.connect()
    step("session open", cam.open_session)

    info = step("device info", cam.device_info)
    if info:
        print(f"  {info['manufacturer']} {info['model']} fw={info['device_version']} "
              f"serial={info['serial']}")
        print(f"  {len(info['operations'])} ops, {len(info['device_props'])} device props")
        with open("proto_deviceinfo.txt", "w") as f:
            for k, v in info.items():
                f.write(f"{k}: {v}\n")
        print("  [saved proto_deviceinfo.txt]")

    def battery():
        raw = cam.device_prop(0x5001)
        # battery level is usually u8 or u16; print raw + guess
        val = struct.unpack("<B", raw[:1])[0] if raw else -1
        print(f"  raw={raw.hex()} -> battery {val}%")
        return val

    step("battery (0x5001)", battery)

    storages = step("storage ids", cam.storage_ids)
    if storages:
        print(f"  {[hex(s) for s in storages]}")

    handles = step("object handles (all)", lambda: cam.object_handles())
    photos = []
    if handles is not None:
        print(f"  {len(handles)} objects total")
        # newest-first: photo handles are the highest, ascending by capture
        # folders: 0x80000000 (root), 0x81900000; photos above that
        photo_handles = sorted((h for h in handles if h > 0x81900000), reverse=True)
        print(f"  {len(photo_handles)} photo-like handles; examining newest 10...")
        for h in photo_handles[:10]:
            try:
                oi = cam.object_info(h)
                print_obj(oi)
                photos.append(oi)
                time.sleep(0.1)
            except Exception as e:
                print(f"  {h:#x}: {e}")
        with open("proto_newest_photos.txt", "w") as f:
            for oi in photos:
                f.write(repr(oi) + "\n")

    if photos:
        newest = photos[0]
        step("thumbnail of newest photo",
             lambda: open("proto_thumb.jpg", "wb").write(cam.thumb(newest["handle"]))
             or print(f"  [saved proto_thumb.jpg {newest['filename']}]"))
        # download the newest JPEG (skip 30MB DNGs for speed)
        jpeg = next((p for p in photos if p["format"] == "JPEG"), None)
        if jpeg:
            def dl():
                n, magic = cam.download(jpeg["handle"], "proto_download.jpg",
                                        progress=lambda d, t: print(f"\r  {d / t * 100:5.1f}%", end=""))
                print(f"\n  [saved proto_download.jpg: {n} bytes, magic {magic.hex()}]")

            step(f"download {jpeg['filename']}", dl)
        else:
            print("  [no JPEG among newest 10 — skipping download test]")

    # MTP object props on newest photo: the rating hunt
    if photos:
        def props():
            raw = cam.object_props_supported(photos[0]["handle"])
            n = struct.unpack("<I", raw[:4])[0]
            codes = list(struct.unpack(f"<{n}H", raw[4:4 + 2 * n]))
            print(f"  {n} object properties supported: {[hex(c) for c in codes]}")
            with open("proto_objprops.txt", "w") as f:
                f.write("\n".join(hex(c) for c in codes))
            return codes

        codes = step("MTP object props supported", props)
        if codes:
            def rating_probe():
                out = []
                for code in codes:
                    try:
                        raw = cam.object_prop(photos[0]["handle"], code)
                        out.append((hex(code), raw.hex()))
                        print(f"  prop {code:#06x} -> {raw.hex()[:40]}")
                    except Exception as e:
                        out.append((hex(code), f"err {e}"))
                    time.sleep(0.1)
                with open("proto_propvalues.txt", "w") as f:
                    for c, v in out:
                        f.write(f"{c} {v}\n")
                return out

            step("object prop values (rating hunt)", rating_probe)

    step("clean close", cam.close_session)

    # health check: can we reconnect right away?
    print("\n=== post-close health check (reconnect) ===")
    try:
        cam2 = M10(verbose=True)
        time.sleep(2)
        cam2.connect()
        cam2.open_session()
        cam2.close_session()
        print("  [camera healthy after clean close — reconnect works]")
        results.append(("reconnect after close", "OK"))
    except Exception as e:
        print(f"  [reconnect failed: {e} — camera may need WiFi cycle]")
        results.append(("reconnect after close", f"FAIL: {e}"))

    print("\n===== VALIDATION SUMMARY =====")
    for name, status in results:
        print(f"  {'OK  ' if status == 'OK' else 'FAIL'} {name}")
    ok = sum(1 for _, s in results if s == "OK")
    print(f"===== {ok}/{len(results)} steps OK =====")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["validate", "info", "battery", "count",
                                        "list", "thumb", "download"])
    ap.add_argument("args", nargs="*", help="handle / output path")
    ap.add_argument("-n", type=int, default=20)
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    ns = ap.parse_args()

    cam = M10(ns.host, ns.port)
    if ns.command == "validate":
        cmd_validate(cam)
        return
    cam.connect()
    cam.open_session()
    try:
        if ns.command == "info":
            info = cam.device_info()
            print(f"{info['manufacturer']} {info['model']} fw={info['device_version']}")
            print(f"serial={info['serial']} ops={len(info['operations'])} "
                  f"props={len(info['device_props'])}")
        elif ns.command == "battery":
            raw = cam.device_prop(0x5001)
            print(f"battery raw={raw.hex()}")
        elif ns.command == "count":
            handles = cam.object_handles()
            print(f"{len(handles)} objects")
        elif ns.command == "list":
            handles = sorted(cam.object_handles(), reverse=True)
            shown = 0
            for h in handles:
                if h <= 0x81900000:
                    continue
                oi = cam.object_info(h)
                print_obj(oi)
                shown += 1
                if shown >= ns.n:
                    break
        elif ns.command == "thumb":
            handle = int(ns.args[0], 0)
            data = cam.thumb(handle)
            open(ns.args[1], "wb").write(data)
            print(f"saved {len(data)} bytes -> {ns.args[1]}")
        elif ns.command == "download":
            handle = int(ns.args[0], 0)
            n, _ = cam.download(handle, ns.args[1],
                                progress=lambda d, t: print(f"\r{d / t * 100:5.1f}%", end=""))
            print(f"\nsaved {n} bytes -> {ns.args[1]}")
    finally:
        cam.close_session()


if __name__ == "__main__":
    main()
