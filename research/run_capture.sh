#!/bin/bash
# run_capture.sh — capture a REAL client (Leica Sync) talking to the M10,
# plus run our probe2 strategy matrix. Everything happens offline, on the
# camera's network. Results land in research/ for the agent to analyze.
#
# You will be asked for your Mac password ONCE (for tcpdump) at the start.
#
# Usage:  bash /Users/bg/code/glm_funk/research/run_capture.sh

cd "$(dirname "$0")"
OUT=capture_session.txt
: > "$OUT"
log() { echo "$@" | tee -a "$OUT"; }

log "=== Leica M10 capture session: $(date) ==="

IP=$(ipconfig getifaddr en0 2>/dev/null)
log "[0] Mac IP: ${IP:-NONE}"
if [ -z "$IP" ]; then
  log "    Not on any network. Join 'LeicaM10-5230856' first, then re-run."
  exit 1
fi

# --- 1. start tcpdump (needs sudo; password prompt NOW) ---
log "[1] Starting packet capture (sudo password prompt)..."
sudo tcpdump -i en0 -w leica_capture.pcap host 192.168.1.2 2>> "$OUT" &
TD_PID=$!
sleep 2
if ! sudo kill -0 $TD_PID 2>/dev/null; then
  log "    tcpdump failed to start — see above. Aborting."
  exit 1
fi
log "    capture running (pid $TD_PID) -> leica_capture.pcap"

# --- 2. run probe2 strategy matrix (also captured) ---
log ""
log "[2] Running probe2 (strategy matrix, ~1 minute)..."
python3 ptpip_probe2.py 192.168.1.2 15740 2>&1 | tee -a "$OUT"
log "    probe2 done."

# --- 3. launch Leica Sync for the real-client capture ---
log ""
log "[3] Launching Leica Sync (the working reference app)..."

# make sure the DMG is mounted
if [ ! -d "/Volumes/Leica Sync 1.4/Leica Sync.app" ]; then
  hdiutil attach -nobrowse -readonly leica_sync_1.4.dmg >/dev/null 2>&1
fi
open "/Volumes/Leica Sync 1.4/Leica Sync.app"
log "    Leica Sync is opening."
log ""
log "    >>> IN THE LEICA SYNC WINDOW: select your camera, let it connect,"
log "    >>> wait until you see thumbnails of your photos."
log "    >>> THEN come back here and press ENTER."
log ""
read -p "   Press ENTER after Leica Sync shows thumbnails... "

# --- 4. stop capture ---
log "[4] Stopping capture..."
sudo kill -INT $TD_PID 2>/dev/null
sleep 2
log "    capture stopped."

# --- 5. close Leica Sync politely ---
osascript -e 'tell application "Leica Sync" to quit' 2>/dev/null
log "[5] Leica Sync closed."

log ""
log "=== CAPTURE SESSION DONE ==="
ls -la leica_capture.pcap 2>/dev/null | tee -a "$OUT"
log ""
echo "===================================================================="
echo " DONE — switch back to your home WiFi now, then tell the agent 'done'"
echo " (files: research/capture_session.txt + research/leica_capture.pcap)"
echo "===================================================================="
