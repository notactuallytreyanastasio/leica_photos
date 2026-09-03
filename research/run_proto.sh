#!/bin/bash
# run_proto.sh — offline validation of m10.py (the prototype client)
# against the real camera. Results saved for the agent to analyze.
#
# BEFORE: camera WiFi freshly on (cycle if unsure), iPhone not connected.
#
# Usage: bash /Users/bg/code/glm_funk/research/run_proto.sh

cd "$(dirname "$0")"
OUT=proto_output.txt
: > "$OUT"

{
  echo "=== m10.py prototype validation: $(date) ==="
  IP=$(ipconfig getifaddr en0 2>/dev/null)
  echo "Mac IP: ${IP:-NONE}"
  if [ -z "$IP" ]; then
    echo "Not on the camera network. Join LeicaM10-5230856 first."
    exit 1
  fi
  python3 m10.py validate
} 2>&1 | tee "$OUT"

echo ""
echo "===================================================================="
echo " DONE — switch back to home WiFi, then tell the agent 'done'"
echo " (files: proto_output.txt, proto_deviceinfo.txt, proto_newest_photos.txt,"
echo "  proto_thumb.jpg, proto_download.jpg, proto_objprops.txt, proto_propvalues.txt)"
echo "===================================================================="
