# Leica M10 — PTP/IP Protocol Spec (COMPLETE)

Ground truth: captured working session of Leica Sync 1.4 ↔ stock M10
(firmware 03.22.23.38, serial ...5230856), 2026-09-03, `leica_capture2.pcap`
(41MB, 1826 commands). Every fact below is observed, not guessed.

## 1. Network

- AP: SSID `LeicaM10-<serial>`, WPA2, 8-digit password (shown on camera)
- Camera: DHCP server, 192.168.1/24; camera = **192.168.1.2**
- Bonjour: `_ptp._tcp` instance `LeicaM10-<serial>` → port **15740**
- Camera accepts ONE PTP client; server wedges after ~2 aborted connection
  cycles (no watchdog). Recovery: cycle camera WiFi. Be a gentle client.

## 2. Framing (little-endian)

```
u32 length (incl. 8B header), u32 type, payload
types: 1 InitCmdReq, 2 InitCmdAck, 3 InitEvtReq, 4 InitEvtAck, 5 InitFail,
       6 CmdRequest, 7 CmdResponse, 8 Event, 9 StartData, 10 Data,
       11 Cancel, 12 EndData(unused by M10), 13 Ping, 14 Pong
```

- InitCmdReq: GUID(16) + hostname UTF16LE+NUL + u32 version 0x00010000
- InitCmdAck: u32 conn number + GUID(16) + name UTF16LE+NUL ('LEICA M10',
  camera GUID is all-zeros)
- InitEvtReq (2nd TCP connection!): u32 conn number → InitEvtAck (empty)
- **CmdRequest: u32 dataphase=0 (ALWAYS 0 — camera ignores/mishandles 1!)
  + u16 opcode + u32 txid + ALWAYS 5 × u32 params (zero-padded, 38 bytes
  total).** Txids start at 1. This 3-part rule (phase=0, 5 params, sid)
  is why naive clients get silence.
- CmdResponse: u16 respcode (0x2001 OK) + u32 txid + params
- StartData: u32 txid + **u64 total length**; then Data packet(s): u32 txid
  + chunk (small payloads arrive whole in one Data packet); then Response.
  **No EndData is ever sent.**
- Event channel: camera pushes Events (u16 code + u32 txid=0xFFFFFFFF +
  params; seen: 0x4006 DevicePropChanged, 0x4008 DeviceInfoChanged).
  Client sends **Ping (type 13, empty) every 1 second** on the event
  channel (keepalive; camera does not Pong).

## 3. Session-open choreography (exact, from capture)

```
connect cmd socket 15740 → InitCmdReq → InitCmdAck (note conn number)
connect evt socket 15740 → InitEvtReq(conn) → InitEvtAck
txid=1  OpenSession(0x1002)      params: sid=0x0000FFFF, 0,0,0,0
txid=2  LE_OpenSession(0x9005)   params: 0x0000FF55, 0,0,0,0   ← vendor session!
txid=3  GetDeviceInfo            → 607B (layout below)
txid=4  GetDevicePropValue(0xd652)  (Leica vendor prop, 4B value)
txid=5  GetDeviceInfo (again — Leica Sync quirk, probably optional)
txid=6  LE_GetLensParameter(0x9003) → 101B lens info
txid=7..10 GetDevicePropValue: 0x5001 (BatteryLevel), 0x501e, 0x501f, 0xd645
txid=11 GetObjectHandles(0xFFFFFFFF, 0, 0) → u32 count + count×u32 handles
txid=12+ GetObjectInfo(handle) per photo
... GetThumb(handle) per thumbnail; GetObject(handle) to download
end: LE_CloseSession(0x9006)? + CloseSession(0x1003) (capture ended
     before Leica Sync closed; follow-up: verify clean close on hardware)
```

## 4. DeviceInfo (PTP/IP variant — differs from USB!)

- Header 11 bytes: u16 stdVersion(0x006e), u32 vendorExtID(0xffffffff),
  u16 vendorExtVer, u8-prefixed UTF16 vendorExtDesc, u16 functionalMode,
  (+1 mystery byte — 11B total; brute-forced alignment fit is exact)
- **Array counts are u32** (not u16 as in USB)
- Five arrays: ops, events, devprops, captureFormats, imageFormats
- Strings: **u8 length (UTF16 units incl. NUL) + UTF16LE + NUL**:
  "Leica Camera AG", "LEICA M10", "03.22.23.38", "0000000005230856"

### Supported operations (48)

Standard: GetDeviceInfo, OpenSession, CloseSession, GetStorageIDs/Info,
GetNumObjects, GetObjectHandles, GetObjectInfo, GetObject, GetThumb,
DeleteObject, SendObjectInfo/Object(0x100c/0x100d/0x100e/0x100f/0x1010),
GetDevicePropDesc/Value, SetDevicePropValue, GetPartialObject, 0x1017, 0x1024

**MTP object props: 0x9801 GetObjectPropsSupported, 0x9802
GetObjectPropDesc, 0x9803 GetObjectPropValue, 0x9804 SetObjectPropValue,
0x9805 GetObjectPropList** ← the star-rating mechanism (query per object
without downloading; exact property code TBD via GetObjectPropsSupported)

Leica vendor: 0x1023?, 0x9003 GetLensParameter, 0x9004 LEReleaseStages,
0x9005 LEOpenSession, 0x9006 LECloseSession, 0x9007
RequestObjectTransferReady, 0x9008 GetGeoTrackingData, 0x9019/0x901a
exposure control, 0x901c PhotoLiveView, 0x901d KeepSessionActive,
0x901f, 0x9021, 0x9022, 0x9024, 0x9025 LEGetStreamData, 0x9027, 0x9029,
**0x9035 (unknown — rating candidate?)**, 0x9036 LESetDateTime,
**0x9037 GetObjectPropListPaginated**, 0x900f

### Events (15): 0x4002-0x4009, 0x400c + vendor 0xc801, 0xc002, 0xc006-0xc008, 0xc00a

### Device properties (159): standard 0x5001, 0x500b, 0x500e, 0x500f, 0x5010,
0x5013-0x5015, 0x501e, 0x501f, 0x5020-0x5022, 0x5025 + Leica 0xd0xx/d6xx
(incl. 0xd645, 0xd652 battery, 0xd660, 0xd677...)

### Formats: 0x3801 JPEG, 0x3802 TIFF/DNG(!), 0xb000, 0x3001 association,
0x300d — note: **DNG files report format 0x3802** (TIFF family)

## 5. ObjectInfo (per photo)

Fixed 52B (same as USB): StorageID u32 (0x20001), ObjectFormat u16,
ProtectionStatus u16, CompressedSize u32 (DNG ~30MB), ThumbFormat u16
(0x3801), ThumbSize u32 (~12KB), ThumbW/H u32 (160×120), ImageW/H u32
(5984×3992), BitDepth u32, ParentObject u32 (folder handle), AssocType
u16, AssocDesc u32, SequenceNumber u32. Then 3 × (u8 prefix + UTF16LE +
NUL): **Filename ("L1003477.DNG"), CaptureDate ("20260820T181641.0"),
ModificationDate (same)**.

Handles: increment by 0x10 per photo (capture order). Root=0x80000000,
folder(s)=0x81900000, photos 0x8190d951... **Newest photos = highest
handles — walk the list in reverse for newest-first browsing.**
(1522 objects on this camera as of capture.)

## 6. ObjectHandles payload

u32 count + count × u32 handles (6088B = 1522 handles).

## 7. Reference client behavior notes

- Leica Sync fetched ALL ObjectInfos + thumbs oldest-first (slow); our app
  should go newest-first + lazy thumbnails (user decision)
- 1s Ping on event channel
- Two GetDeviceInfo calls at start (probably optional)
- Device props read each session: battery (0x5001/0xd652), versions,
  0xd645 (unknown), lens parameter via 0x9003

## 8. The star/favorite flag (use case #1) — SOLVED

The M10 writes the in-camera favorite as **`xmp:Rating` inside the
photo's embedded XMP packet** (camera-authored; CreatorTool = firmware
version). Verified from a real camera-authored DNG (unstarred = "0").
No standard EXIF Rating tag (0x4746) is present. Leica MakerNote
("LEICA\0" header, 4096B) exists but isn't needed.

App path: read xmp:Rating (or MTP object property if exposed — TBD)
-> filter starred -> PhotoKit import as favorite -> auto album.
TODO verify: a starred photo via SD card reader (never camera WiFi)
should show xmp:Rating > 0.

## 9. Open items (nice-to-have, verify on hardware when convenient)

- Clean close sequence (LE_CloseSession + CloseSession param conventions)
- GetObjectPropsSupported: find the rating property code (0x9035? MTP
  standard object props?) — needed for star-filter without EXIF parsing
- GetObject chunking for large DNGs (multi Data packets — the undecoded
  596KB tail of the capture has the answer when needed)
- 0x9037 GetObjectPropListPaginated argument format (bulk metadata;
  might be the fast path for ratings of 1500 photos)
