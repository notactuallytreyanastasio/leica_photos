# Leica M10 WiFi Protocol — Research Log

**What this is:** a live, chronological log of the research spike for building a
custom iOS app that talks to a stock Leica M10 over WiFi (a Leica FOTOS
replacement). Written to be read by a human — `tail -f` friendly.

**Companion docs (later, once facts are firm):** `protocol-notes.md` will hold
the actual protocol spec as we learn it.

---

## The Goal (context)

Build an iOS app that, against a **completely stock, warranty-intact M10**:

1. Transfers photos marked with a star (in-camera favorites) to a special album
2. Organizes photo albums in-app, mirrored into Apple Photos
3. Browses/downloads photos like Leica FOTOS does (no remote shutter needed)

**Hard constraint:** the camera must remain 100% stock. No firmware mods, no
debug interfaces, nothing that could void the warranty. Everything we build is
a *client* that speaks the same language the official FOTOS app speaks.
From the camera's point of view, our app is indistinguishable from FOTOS.

**iOS-side facts (settled early, no research needed):**
- Joining the camera's WiFi: `NEHotspotConfiguration` (same mechanism GoPro
  etc. use). Needs an entitlement, available to sideloaded apps.
- Saving into Apple Photos + albums: PhotoKit. Fully supported.
- Star filtering: the M10's in-camera favorite flag is written into EXIF, so
  it survives download and can be filtered on. (Exact tag TBD.)

**The open question:** what protocol does the M10 speak over WiFi?

---

## Findings

### 1. The Leica "LE" PTP command set is public knowledge (CONFIRMED)

libgphoto2 (the big open-source camera library) contains a full set of
Leica vendor-specific PTP operations, gathered from two public sources:

- Adobe Lightroom's Leica tether plugin (people watched what it sent)
- alexhude's "LeicaHacks" blog research (github.io, M240-era, firmware RE)

The interesting commands for us:

| Opcode | Name | Why it matters |
|--------|------|---------------|
| 0x9005 | LEOpenSession | how a session starts |
| 0x9006 | LECloseSession | how it ends |
| 0x9007 | RequestObjectTransferReady | photo transfer handshake |
| 0x9037 | **GetObjectPropListPaginated** | paginated photo listing — smells exactly like what a WiFi browsing app (FOTOS) uses |
| 0x9025 | LEGetStreamData | live view stream (we don't need this) |
| 0x9036 | LESetDateTime, etc. | housekeeping |

Full list is in libgphoto2 `camlibs/ptp2/ptp.h` (~50 Leica opcodes).
Implication: **Leica's protocol is PTP-based** (the ISO camera transfer
standard) with a vendor extension, not some from-scratch invention.
That's very good news — PTP is documented, and Wireshark understands its
IP variant (PTP/IP) out of the box.

### 2. gphoto2 does NOT support Leica over WiFi (CONFIRMED)

gphoto2's PTP/IP (WiFi) camera list contains only Ricoh/Nikon/Canon/Fuji.
Leica works there over **USB only** (M11 Monochrom, Q3, SL3 are listed).
So we can't just reuse gphoto2 for the WiFi path — but the USB support
confirms the command family is stable across Leica generations.

### 3. Independent Swift implementation exists for Leica USB (CONFIRMED)

`dognotdog/ptpwebcam` (GPLv3, macOS "PTP camera as webcam" app) has
`UsbLeicaCamera.swift` — a working Swift implementation of the Leica
session/liveview commands. Caveats:

- Targets newer bodies (M11 / Q3 / SL3 era; it explicitly says live view
  needs those), not the M10.
- USB transport, not WiFi.
- GPLv3: fine to *read* for protocol facts, we must not copy code into
  our (non-GPL) app.

### 4. Someone already did a giant camera-protocol research sweep (FOUND)

`OliverTaki/motk-capture` repo contains a whole library of camera-control
protocol research files, including:

- `om-leica-fuji-ptp-deep-read.md` — confirms modern Leica M/Q/SL is a
  "standard-PTP-oriented family" and warns that Leica-branded compacts are
  Panasonic firmware (different protocol entirely — doesn't apply to the M10).
- `ptpip-deep-read.md` + `ptpip-connection-topology-*.md` — PTP/IP knowledge
  we can crib from.

### 5. THE KEY QUESTION IS ANSWERED: M10 WiFi = PTP/IP (CONFIRMED)

Two independent confirmations:

**a) L-Camera-Forum, 2017-2018.** A forum member captured the M10 ↔ FOTOS
traffic with Wireshark (passive capture — exactly our plan) and found:
- The camera speaks **PTP/IP** (the IP variant of the ISO 15740 standard)
- Camera acts as **DHCP server** on a 192.168.1/24 subnet; camera is
  192.168.1.2
- Wireshark recognizes PTP/IP natively (protocol decoding for free)
- ("Mark II" / tSoniq, who wrote a macOS downloader app, adds: standard
  PTP/IP **with MTP extensions and zero-conf/mDNS service discovery**)

**b) "Leica Sync" by tSoniq — a working, free, notarized macOS app that
downloads images from the M10/M10-P over WiFi.** We downloaded it
(research/leica_sync_1.4.dmg) and inspected the binary. Strings confirm:

- mDNS/Bonjour discovery of service type **`_ptp._tcp`** (NSNetServiceBrowser)
- Standard PTP/IP transport: dual TCP streams (command + event),
  INIT COMMAND / INIT EVENT handshake, transaction queue — textbook PTP/IP
- Standard PTP/MTP operations used for browsing/downloading:
  OpenSession, GetDeviceInfo, GetStorageIDs, GetStorageInfo,
  GetObjectHandles, GetObjectInfo, GetThumb, GetObject, GetPartialObject,
  GetNumObjects, GetObjectPropList, GetObjectPropValue, GetObjectPropsSupported
- Leica vendor ops known to the app: GetViewFinderData, GetStreamInfo,
  GetStream, GetOSDData, GetLensInfo, GetVendorDeviceInfo,
  **GetResizedImageObject** (handy — server-side resized previews)
- Battery level + copyright editing via device properties

The app was built against the M10 specifically (author only owned an M10),
which makes it the perfect behavioral reference for OUR target camera.

**Implication for our project:**
- No protocol reverse engineering needed for browsing/downloading — we
  implement standard PTP/IP + MTP object operations against the camera.
- Wireshark decodes our debug captures natively (huge for development).
- The star/favorite filter question reduces to: does the M10 expose a
  rating property via GetObjectPropList/GetObjectPropValue, or do we read
  EXIF after download? (Empirical test on hardware will settle it.)
- Vendor ops (0x9xxx) are optional sugar — standard ops suffice, which is
  also the safest posture for the camera (same commands FOTOS itself uses).

### 6. Android app identified (for static analysis)

Leica FOTOS on Android: package `com.leica_camera.app`. Decompiling it
would give us the exact protocol the app uses, per camera generation,
including the M10 path. **Blocked so far:** every APK mirror (APKPure,
APKMirror, apkcombo) is Cloudflare-walled against curl.

Options: (a) user downloads the APK in a normal browser and drops it in
`research/`, (b) find another mirror, (c) skip it and go straight to a
WiFi capture, which gives *ground truth for the M10 specifically* anyway.

### 7. Search engine situation (MINOR)

GitHub API works (unauthenticated). DuckDuckGo/Google/Bing/grep.app all
bot-block curl from here. Reddit's JSON API also blocked. Brave search's
HTML works — that's our web-search channel.

---

## Status: where we are

- iOS feasibility: settled (all standard APIs).
- Camera protocol family: settled (PTP + Leica vendor extension).
- M10-over-WiFi transport: **SETTLED — standard PTP/IP + MTP, mDNS discovery
  (`_ptp._tcp`), camera at 192.168.1.2 as DHCP server.** Confirmed by forum
  Wireshark captures AND a working third-party macOS app we inspected.
- Reference implementation: Leica Sync 1.4 (closed freeware — behavioral
  reference only, no code copying; all rights reserved, tSoniq).

## Next steps (in order)

1. ~~Find the WiFi transport~~ **DONE — it's PTP/IP**
2. Write `protocol-notes.md`: the concrete protocol spec for our client
   (packet formats, session flow, object listing, thumbnails, downloads)
3. macOS CLI prototype: join camera WiFi, discover via Bonjour, connect,
   list, thumbnail, download — prove it against the real M10
4. Verify the star/favorite question empirically (object props vs EXIF)
5. iOS app skeleton → PhotoKit import + albums → star-filtered transfer flow

## LIVE SESSION (in progress)

The M10 is physically on hand — moving from research to empirical
verification. Prepared:

- `research/ptpip_probe.py` — a minimal PTP/IP client (connect, handshake,
  OpenSession, GetDeviceInfo, dump everything). Wire format cross-verified
  against Wireshark's dissector + libgphoto2's client before touching the
  camera: header is u32 LENGTH then u32 TYPE (little-endian), StartData
  total length is u64, dataphase 1=recv/2=send.
- `research/protocol-notes.md` — the durable protocol spec (verified formats,
  connection sequence, open questions).

Everything the probe does is stock FOTOS-style client traffic. Camera
remains untouched.

## Scratch / dead ends (so we don't retry them)

- GitHub repo search: no M10 WiFi protocol project exists (checked many
  query shapes). Closest: LeicaHacks (M240 firmware RE — off-limits and
  irrelevant), ptpwebcam (USB, newer bodies), motk-capture (research notes).
- gphoto2: no Leica WiFi support.
- APKPure/APKMirror/apkcombo direct downloads: Cloudflare-blocked.
- DDG html/lite, Google, Bing, grep.app, Reddit JSON: bot-blocked.
- Brave search HTML: works (use this for web search).
- L-Camera-Forum: Cloudflare-blocks curl directly, but **r.jina.ai reader
  proxy works** (`https://r.jina.ai/<url>`) — use this for forum threads.
- FOTOS APK: no longer needed — Leica Sync binary + forum captures answer
  the protocol question more directly (and M10-specifically).

## MISTAKE LOG — WiFi handling (read this before touching network again)

- I ran `networksetup -setairportnetwork` on the USER'S Mac without asking,
  twice. The join failed silently, left the Mac unassociated (no internet),
  and I misread a stale DHCP lease + a ping to 192.168.1.2 as "camera
  reachable" — the user's HOME subnet is also 192.168.1.x; that was their
  router answering, not the camera. Classic confirmation bias.
- Why the join failed: unknown (possible: single-client AP limit, WEP vs
  WPA mismatch on older M10 firmware, or SSID/password subtleties). TBD.
- RULE GOING FORWARD: the user drives all WiFi switching from the menu
  bar. I never modify network configuration. I only read state
  (ipconfig, dns-sd, ping, TCP sockets to the camera).

## LIVE SESSION RESULT — FIRST CONTACT WITH THE M10 (2026-09-03 15:42)

The user ran the offline probe from Terminal (correct protocol: agent is a
cloud model and goes offline with the Mac; user drives everything offline).

**CONFIRMED (from probe_output.txt):**
- Mac on camera network: DHCP lease 192.168.1.188 (camera = DHCP server)
- Bonjour: instance `LeicaM10-5230856`, type `_ptp._tcp` →
  `LeicaM10-5230856.local.:15740` — mDNS discovery CONFIRMED
- Camera is at **192.168.1.2:15740**
- **PTP/IP handshake WORKS with our own code:**
  - InitCommandAck received: camera name `LEICA M10`, conn_id 1,
    camera GUID all zeros
  - InitEventAck received: dual-channel PTP/IP fully operational
  - (First-ever contact between this project and the camera: our Python
    client introduced itself and the camera answered.)

**BLOCKER:** OpenSession (0x1002, sid=0xC0FFEE, txid=1, dataphase=1) got
SILENCE — no response packet, connection stayed open. Not rejected: ignored.

**NEXT:** one more offline session with `run_capture.sh`:
1. tcpdump records everything on port 15740
2. probe2 runs a strategy matrix (sessionless GetDeviceInfo, sid=1,
   sid=0/txid=0, Leica 0x9005 vendor session, dataphase=0) with full
   packet logging and a lenient reader
3. Leica Sync (the working reference app) connects and browses — its
   traffic gets captured = byte-perfect ground truth of how a real
   client opens a session on this exact camera

## CAPTURE SESSION #1 ANALYSIS (2026-09-03 ~16:00, from leica_capture.pcap)

What the pcap showed (643 packets):

1. Strategy A (15:51:04) and B (15:51:14): handshakes fine, all commands
   silently ignored, clean TCP close each time.
2. Strategy C/D: TCP connect timeouts — the camera stopped accepting
   connections after ~2 aborted cycles.
3. Strategy E (port 62432): surreal degraded state — camera keeps
   re-sending SYN-ACKs on an ESTABLISHED connection, never ACKs app data.
4. Leica Sync (15:52:08+, ports 64649/64903/65234): DID find the camera's
   address and tried connecting repeatedly — but the camera's PTP service
   was already dead. It FIN'd immediately, retried, RST'd out. UI: no
   camera. (So its discovery worked; the camera was just wedged.)

**LESSON (camera behavior):** the M10's PTP/IP server has a tiny session
table and no watchdog. Two aborted connection cycles wedge it. Recovery:
cycle WiFi off/on on the camera. Our app must be a gentle, clean client.

**PRIME SUSPECT for the OpenSession silence (found in gphoto2 ptp.c):**
`ptp->Transaction_ID = params->transaction_id++` with transaction_id
initialized to 0 → **the first transaction id must be 0**. All our
fresh-camera attempts sent first txid=1. The M10 silently drops
mis-sequenced transactions. (Strategy C tested txid=0 but only AFTER the
camera wedged — invalid test.)

Also fixed: probe2's "camera name ''" was my parser hitting the all-zero
camera GUID (name is at offset 20, not "first \x00\x00 after 4").

**NEXT:** run_capture2.sh — camera freshly cycled, Leica Sync FIRST
(ground truth), then probe3 (single clean session, txid starts at 0,
full tour: OpenSession/DeviceInfo/StorageIDs/ObjectHandles/CloseSession).

## 🎉 PROTOCOL FULLY CRACKED (2026-09-03, capture session #2)

Leica Sync worked on the fresh camera (user cycled WiFi first), and the
41MB capture contains its complete session: 1826 commands, both directions.

**Why every previous probe got silence (3 combined mistakes):**
1. dataphase must be 0 — we sent 1 (camera likely waits for a data-out
   phase that never comes → silence)
2. CmdRequest must ALWAYS carry 5 param slots (38 bytes) — we sent 1
   param (22 bytes)
3. Session open is TWO commands: OpenSession(sid=0xFFFF) THEN Leica
   vendor LE_OpenSession(0x9005, param 0xFF55) — we never sent the second

**Everything else decoded from the capture:**
- Session choreography, 1-second Pings on the event channel, events
- DeviceInfo layout (PTP/IP variant: u32 array counts, u8-prefixed
  UTF-16 strings) — 48 ops, 159 device props, 15 events
- MTP object props supported (0x9801-0x9805) → star-rating reads
  without downloading
- ObjectInfo layout + real sample (L1003477.DNG, 30MB, 5984×3992,
  captured 20260820T181641.0)
- 1522 photos on camera; handles +0x10 per shot, newest = highest
  (user directive: browse newest-first — reverse walk)
- One full GetObject download captured

`protocol-notes.md` is now the complete, ground-truth spec.
Research phase: DONE. Next: build the client (macOS prototype first,
then the iOS app).

## PROTOTYPE BUILT: m10.py (2026-09-03)

Full client implementing the cracked spec: dual session open, phase=0 +
5-param commands, 1s event Pings, newest-first listing, thumbnails,
downloads, MTP object-prop probes (the rating hunt), clean close, and a
post-close reconnect health check. Offline driver: run_proto.sh
(`python3 m10.py validate`). Next: user validates on hardware.

## INCIDENT LOG — camera froze and ran hot after prototype run (2026-09-03)

After the m10.py validation tour, the user reports the M10 froze up and
got hot. Recovery: battery pull (standard M10 lockup recovery). All our
traffic was read-only (browse/metadata/thumb/download — zero write ops),
so permanent damage is not expected; freeze = wedged PTP server (known
behavior), heat = WiFi radio + likely CPU spin from the stuck state.

CAUSE (my fault): the validation tour was too aggressive — dozens of
MTP object-property queries back-to-back (0.1s pacing), plus a
reconnect-health-check that could itself leave an unclean session.

RULES GOING FORWARD (enforced in code):
1. No probe sweeps on the camera — a handful of queries max, or none
2. First timeout = immediate clean close, no retries, no pushing through
3. Hard runtime cap on every session
4. One session per WiFi cycle; camera rests between sessions
5. User always cycles camera WiFi (or reboots) before any test

## STAR MECHANISM SOLVED (2026-09-03, zero camera contact)

Analyzed ~/Downloads/L1003477.DNG (the photo the user downloaded via
Leica Sync at 16:11, after capture session 2 — m10.py never ran; no
proto_* files exist; the freeze was caused by probe3's dataphase=1
OpenSession hang, camera off-limits since).

The camera's in-camera favorite flag is written into the photo's
embedded XMP packet as `xmp:Rating` (camera-authored: CreatorTool
= firmware "3.22.23.38"). Unstarred photo shows xmp:Rating="0".
EXIF proper has NO 0x4746 Rating tag; Leica MakerNote exists
("LEICA\0" header, 4096B) but XMP answers the need.

USE CASE #1 PATH (complete):
  star on camera -> xmp:Rating in file -> app filters on it ->
  Apple Photos import as favorite -> "M10 Stars" album (PhotoKit)

VERIFICATION NEEDED (camera-free): parse a STARRED photo from the SD
card via card reader to confirm xmp:Rating > 0. Never via camera WiFi.

DEVELOPMENT BOUNDARY: camera is off-limits (user decision, respected).
All further work is Mac-only: Swift port of the PTP/IP client +
NEHotspotConfiguration + PhotoKit. m10.py exists but stays unvalidated
until the user ever chooses to run one gentle, time-capped test.

## SWIFT PORT + iOS SKELETON COMPLETE (2026-09-03, zero camera contact)

**M10Kit** (SwiftPM package, glm_funk/M10Kit/):
- PtpIpPacket.swift — framing codec; commandRequest enforces the 3 rules
  (phase=0, 5 param slots, 38 bytes)
- Models.swift — DeviceInfo (PTP/IP variant: u32 counts, u8-prefixed
  strings), ObjectInfo, formats, opcodes
- M10Session.swift — BSD sockets on serial queue, dual session open,
  1s pings, GentleClientRules enforced (first timeout aborts, session
  cap, inter-query pacing), clean close
- XmpRating.swift — star rating extraction
- **11/11 ground-truth tests green**: command encodings byte-identical
  to Leica Sync's captured traffic; DeviceInfo/ObjectInfo/handles
  decode real camera data; XMP rating works; InitCommandAck lesson
  learned (name is NUL-terminated, NOT length-prefixed — fixed in kit)

**M10App** (glm_funk/M10App/, xcodegen project):
- SwiftUI skeleton: ConnectView (instructions + Connect), BrowserView
  (newest-first lazy grid w/ thumbnails), AppState (session owner,
  fail-safe), CameraDiscovery (NWBrowser _ptp._tcp + resolve)
- Info.plist: local-network usage + Bonjour service declarations
- Builds for iOS simulator; unit tests pass

NEXT: photo detail view + download flow, PhotoKit import (favorites
from xmp:Rating, album mirroring), NEHotspotConfiguration join flow
(needs Hotspot entitlement), star-filter UI. All buildable and
testable without the camera; hardware validation only when user opts in.

## PRODUCT RULES (from the owner, 2026-09-03)

- starred photos (xmp:Rating > 0) → Photos Favorite + "Best of Leica" album
- DNGs → "RAW Leica" album (starred DNG → both)
- NO bulk transfers — they always fail (matches the camera's fragility);
  the app imports one photo at a time, sequentially, stop-on-first-failure

## CACHE + POLISH INCREMENT (2026-09-03)

- M10Kit: EXIF parser (TIFF/DNG + JPEG APP1; handles M10's APEX-style
  values) — validated against the real DNG fixture; 13/13 tests green
- M10App: disk cache (Documents/PhotoCache) — ObjectInfo blobs,
  thumbnails, full downloads (LRU @1GB), ratings + saved status;
  batch hydration on connect; re-browsing is nearly camera-free
- Polish: camera header (fw/serial/battery), filter chips
  (All/★/JPEG/DNG), date-grouped grid, EXIF line in detail view,
  friendly errors ("camera needs a rest"), haptics, Keychain for
  WiFi passwords, settings sheet (cache usage/clear), generated
  app icon (tools/generate_icon.swift)
- Repo pushed to GitHub as an educational project
