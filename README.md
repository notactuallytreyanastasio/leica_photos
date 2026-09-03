# glm_funk — an educational reverse-engineering project

A from-scratch iOS client for the Leica M10, built by reverse-engineering
the camera's WiFi protocol **without touching the camera**: no firmware
mods, no debug interfaces, warranty fully intact. The camera only ever saw
the same read-only traffic the official app sends it.

This README tells the whole story — including the mistakes — so the method
is reusable for other cameras.

## What this is

- **`research/`** — the investigation: logs, protocol spec, probe scripts,
  and a 41MB packet capture (`leica_capture2.pcap`) of a *known-working
  third-party client* (Leica Sync by tSoniq) talking to the camera. That
  capture is the source of every protocol fact in this repo.
- **`M10Kit/`** — a Swift package implementing the protocol, with tests
  that decode fixtures extracted from the capture. If the tests pass, the
  client speaks the camera's language — no camera needed to develop.
- **`M10App/`** — a SwiftUI iOS app on M10Kit: discover the camera over
  Bonjour, browse photos newest-first, download, and file into Apple
  Photos (starred → "Best of Leica", DNGs → "RAW Leica").

## The short version of how the protocol was cracked

1. **Read what's already known.** libgphoto2's source contains a Leica
   PTP vendor-extension command set (0x9005 LE session ops, etc.),
   originally documented from Adobe's Lightroom tether plugin. So the
   protocol family was known: PTP, the ISO camera-transfer standard.
2. **Find the transport.** A 2018 L-Camera-Forum thread confirmed the M10
   speaks PTP/IP — PTP over TCP — and someone had already Wiresharked it.
   The camera is a DHCP server at 192.168.1.2, port 15740, advertising
   `_ptp._tcp` over Bonjour.
3. **First contact.** A ~200-line Python client completed the PTP/IP
   handshake (the camera answered `LEICA M10`!) — but every command was
   met with silence.
4. **Ground truth.** Rather than guess, we captured a working client: ran
   Leica Sync against the camera with tcpdump recording everything
   (41MB, 1826 commands), then wrote a pcap parser
   (`research/parse_pcap.py`) and read the conversation like a transcript.
5. **The answer was three small details** that no documentation mentions:
   - commands always carry all 5 PTP parameter slots (38 bytes, zero-padded)
   - the "data phase" field must be 0 (with 1, the camera blocks forever —
     which is what froze and heated the camera during testing; see the
     incident log)
   - session open is *two* commands: standard `OpenSession(0xFFFF)` plus
     Leica vendor `LE_OpenSession(0x9005, 0xFF55)`
6. **Star ratings.** The camera's in-camera favorite flag is written into
   each photo's embedded XMP as `xmp:Rating` — so the app can filter and
   file starred shots without any proprietary property reads.

Full spec: `research/protocol-notes.md`. Day-by-day narrative including
failures: `research/RESEARCH_LOG.md`.

## Things that will bite you on this camera (documented the hard way)

- The PTP/IP server is fragile. Two aborted connection cycles wedge it.
  Recovery: cycle the camera's WiFi. Never hammer it; be a gentle client.
- A malformed session-open makes it block forever (see above).
- One client at a time. iPhones with the Leica FOTOS app connected will
  lock you out.
- It has no watchdog: a wedged server can sit spinning with the WiFi radio
  on until the camera heats up and freezes. Battery pull recovers it.
- Bulk transfers don't work in practice — the app transfers one photo at a
  time and stops at the first failure.

## Repo layout

```
research/            the investigation (start with RESEARCH_LOG.md)
  protocol-notes.md  the byte-level protocol spec
  RESEARCH_LOG.md    chronological story, honest about mistakes
  leica_capture2.pcap  ground-truth capture (41MB, real session)
  parse_pcap.py      pcap → readable PTP/IP transcript
  extract_data.py    pull data payloads (DeviceInfo, ObjectInfo, …) out
  m10.py             standalone Python client (protocol reference)
  ptpip_probe*.py    the early probes (kept for the history)
M10Kit/              Swift package: framing, models, session, XMP rating
  Tests/             fixtures extracted from the capture — the proof
M10App/              SwiftUI app (xcodegen project; `xcodegen generate`)
```

## Running the app

```bash
cd M10App && xcodegen generate   # if M10App.xcodeproj is absent
open M10App.xcodeproj            # build & run on a device or simulator
cd ../M10Kit && swift test       # protocol tests against capture fixtures
```

The simulator can't join WiFi, so discovery will report "no camera found"
there — everything else (UI, import logic) is developable and testable
without a camera.

## Credits & prior art

- **Leica Sync** (tSoniq, 2019) — the working macOS client whose traffic
  we captured. Its behavior (not its code) is the reference for this
  project's client.
- **libgphoto2** — the Leica vendor command set in `camlibs/ptp2/ptp.h`.
- **L-Camera-Forum** members who Wiresharked the M10 back in 2017-2018
  and built the first macOS downloader.
- The agent-setup notes for the coding tooling that did the grunt work:
  `docs/pi-agent-setup.md`.
