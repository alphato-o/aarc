#!/bin/bash
# Home Base answers the runner. Usage: reply.sh "<text>" [--silent] [--run <runId>]
# Default: speaks the line into the current live run in the Home Base voice and
# writes it to the app's Home Base terminal. --silent writes the terminal only.
set -u
API="${AARC_API:?set AARC_API to your Worker URL}"
ADM="${AARC_ADMIN_TOKEN:?set AARC_ADMIN_TOKEN (the LIVE_ADMIN_TOKEN secret)}"
TEXT="$1"; shift
SPEAK=true; RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --silent) SPEAK=false ;;
    --run) RUN="$2"; shift ;;
  esac
  shift
done
if [ -z "$RUN" ] && [ "$SPEAK" = true ]; then
  RUN=$(curl -s --max-time 6 "$API/live/status" -H "x-aarc-admin: $ADM" | python3 -c "
import sys, json
try: d = json.load(sys.stdin); print(d.get('runId') or '' if d.get('active') else '')
except Exception: print('')")
fi
python3 - "$TEXT" "$SPEAK" "$RUN" <<'PY' | curl -s --max-time 12 -X POST "$API/agent/reply" -H "x-aarc-admin: $ADM" -H 'content-type: application/json' -d @-
import sys, json
b = {"text": sys.argv[1], "speak": sys.argv[2] == "true"}
if sys.argv[3]: b["runId"] = sys.argv[3]
print(json.dumps(b))
PY
echo
