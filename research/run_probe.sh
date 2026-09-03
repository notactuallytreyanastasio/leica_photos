#!/bin/bash
# run_probe.sh — ONE command to probe the Leica M10 while the Mac is on the
# camera's WiFi network. Run it, wait for ALL DONE, then switch back to your
# home WiFi. The agent will read research/probe_output.txt afterwards.
#
# Usage:  bash research/run_probe.sh

cd "$(dirname "$0")"   # work in research/
OUT=probe_output.txt
: > "$OUT"

log() { echo "$@" | tee -a "$OUT"; }

log "=== Leica M10 probe run: $(date) ==="
log ""

# --- 1. Network state ---
IP=$(ipconfig getifaddr en0 2>/dev/null)
log "[1] Mac IP on this network: ${IP:-NONE (no DHCP lease — not on camera network?)}"
if [ -z "$IP" ]; then
  log "    No IP! You are probably not on the camera network. Aborting."
  log "ALL DONE (nothing to analyze)"
  exit 1
fi
log ""

# --- 2. Bonjour discovery: camera advertises _ptp._tcp ---
log "[2] Browsing for _ptp._tcp services (8 seconds)..."
dns-sd -B _ptp._tcp > dnssd_browse.txt 2>&1 &
B_PID=$!
sleep 8
kill $B_PID 2>/dev/null
cat dnssd_browse.txt | tee -a "$OUT"

# instance name = everything after the 6th column on an "Add" line
# (columns: timestamp, Add/Rmv, flags, ifindex, domain, service type, INSTANCE...)
INSTANCE=$(awk '/Add/ { for(i=1;i<=6;i++) $i=""; sub(/^ +/,""); print; exit }' dnssd_browse.txt)
PORT=""
HOSTIP=""

if [ -n "$INSTANCE" ]; then
  log "    Found service instance: '$INSTANCE'"
  log ""
  log "[3] Resolving '$INSTANCE' (8 seconds)..."
  dns-sd -L "$INSTANCE" _ptp._tcp local > dnssd_resolve.txt 2>&1 &
  L_PID=$!
  sleep 8
  kill $L_PID 2>/dev/null
  cat dnssd_resolve.txt | tee -a "$OUT"
  # be liberal about dns-sd output formats across macOS versions
  PORT=$(grep -oE 'Port [0-9]+' dnssd_resolve.txt | grep -oE '[0-9]+' | head -1)
  # prefer a literal IPv4 address in the resolve output; fall back to hostname
  LITERAL_IP=$(grep -oE '192\.168\.[0-9]+\.[0-9]+' dnssd_resolve.txt | head -1)
  HOSTIP=${LITERAL_IP:-$(grep -oE '[A-Za-z0-9-]+\.local\.?' dnssd_resolve.txt | head -1)}
else
  log "    No _ptp._tcp instance found. (Maybe still on home network, or camera WiFi off)"
  log ""
fi

# --- 4. Probe the camera over PTP/IP ---
log ""
log "[4] PTP/IP probe..."

try_target() {  # $1=host $2=port
  log "---- attempting $1:$2 ----"
  python3 ptpip_probe.py "$1" "$2" 2>&1 | tee -a "$OUT"
}

if [ -n "$HOSTIP" ] && [ -n "$PORT" ]; then
  try_target "$HOSTIP" "$PORT"
else
  # fallbacks from forum/intel: camera at .2 (old firmware) or .1, port 15740
  try_target 192.168.1.2 15740
  try_target 192.168.1.1 15740
fi

log ""
log "=== ALL DONE ==="
log "Now: click your HOME network in the WiFi menu, then tell the agent 'done'."
echo ""
echo "=========================================================="
echo " ALL DONE — switch back to your home WiFi now"
echo " (results saved to research/$OUT)"
echo "=========================================================="
