#!/bin/bash
# run_capture2.sh — attempt #2 at ground truth, with lessons applied:
#   1. Camera must be FRESH (user cycles WiFi off/on first) — our 5 probe
#      attempts last time wedged its PTP server within 40 seconds.
#   2. Leica Sync (known-good client) runs FIRST on the fresh camera.
#   3. Our probe3 (fixed: transaction ids start at 0) runs AFTER, once.
#   4. Everything captured to one pcap.
#
# You will be asked for your Mac password ONCE (tcpdump) at the start.
#
# BEFORE RUNNING: on the camera, turn WiFi OFF then ON (fresh state),
# and make sure your iPhone is not connected to the camera.
#
# Usage:  bash /Users/bg/code/glm_funk/research/run_capture2.sh

cd "$(dirname "$0")"
OUT=capture_session2.txt
: > "$OUT"
log() { echo "$@" | tee -a "$OUT"; }

log "=== Leica M10 capture session #2: $(date) ==="

IP=$(ipconfig getifaddr en0 2>/dev/null)
log "[0] Mac IP: ${IP:-NONE}"
if [ -z "$IP" ]; then
  log "    Not on the camera network. Join 'LeicaM10-5230856' first, then re-run."
  exit 1
fi

# --- 1. capture (include mDNS) ---
log "[1] Starting packet capture (sudo password prompt)..."
sudo tcpdump -i en0 -w leica_capture2.pcap 'host 192.168.1.2 or port 5353' 2>> "$OUT" &
TD_PID=$!
sleep 2
sudo kill -0 $TD_PID 2>/dev/null || { log "tcpdump failed. Aborting."; exit 1; }
log "    capture running -> leica_capture2.pcap"

# --- 2. Leica Sync FIRST on the fresh camera ---
log ""
log "[2] Launching Leica Sync (known-good client, fresh camera)..."
[ -d "/Volumes/Leica Sync 1.4/Leica Sync.app" ] || hdiutil attach -nobrowse -readonly leica_sync_1.4.dmg >/dev/null 2>&1
open "/Volumes/Leica Sync 1.4/Leica Sync.app"
log "    Leica Sync is opening."
log ""
log "    >>> IN LEICA SYNC: select your camera, wait for thumbnails."
log "    >>> If it shows photos: also DOWNLOAD ONE image (we want that traffic)."
log "    >>> THEN come back here and press ENTER."
log ""
read -p "   Press ENTER after Leica Sync shows thumbnails (or says no camera)... "

log "[3] Quitting Leica Sync (cleanly)..."
osascript -e 'tell application "Leica Sync" to quit' 2>/dev/null
sleep 3

# --- 4. probe3: one clean session with the txid=0 fix ---
log ""
log "[4] Running probe3 (single clean session, txid starts at 0)..."
python3 ptpip_probe3.py 192.168.1.2 15740 2>&1 | tee -a "$OUT"

# --- 5. stop capture ---
log ""
log "[5] Stopping capture..."
sudo kill -INT $TD_PID 2>/dev/null
sleep 2
log "    capture stopped."
ls -la leica_capture2.pcap 2>/dev/null | tee -a "$OUT"

log ""
log "=== CAPTURE SESSION #2 DONE ==="
echo ""
echo "===================================================================="
echo " DONE — switch back to your home WiFi, then tell the agent 'done'"
echo " (files: research/capture_session2.txt + research/leica_capture2.pcap)"
echo "===================================================================="
