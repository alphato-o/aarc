#!/bin/bash
# Home Base ear: blocks until something needs the agent, prints it, exits.
# Wakes on: a message from the runner (Siri talk-back or the app's Home Base
# terminal), a live run starting, or a live run ending. Run it in the
# background, answer what it prints with reply.sh, then start it again.
#
#   AARC_API=https://api.example.com AARC_ADMIN_TOKEN=... scripts/home-base/watch.sh
#
# AARC_ADMIN_TOKEN is the Worker's LIVE_ADMIN_TOKEN secret. Never commit it.
set -u
API="${AARC_API:?set AARC_API to your Worker URL}"
ADM="${AARC_ADMIN_TOKEN:?set AARC_ADMIN_TOKEN (the LIVE_ADMIN_TOKEN secret)}"
POLL="${AARC_POLL_SECONDS:-15}"
IDLE_TIMEOUT="${AARC_IDLE_TIMEOUT:-3600}"

status() {
  curl -s --max-time 8 "$API/live/status" -H "x-aarc-admin: $ADM" | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: print('?'); sys.exit()
print(d.get('runId') if d.get('active') else '-')"
}

was=$(status)
elapsed=0
while :; do
  now=$(status)
  if [ "$now" != "?" ] && [ "$was" != "?" ] && [ "$now" != "$was" ]; then
    if [ "$now" = "-" ]; then echo "RUN ENDED $was: do the post-run readout"; else echo "LIVE RUN $now: watch it (GET $API/live/status), check in every few minutes"; fi
    exit 0
  fi
  [ "$now" != "?" ] && was=$now

  msgs=$(curl -s --max-time 8 "$API/agent/inbox" -H "x-aarc-admin: $ADM" | python3 -c "
import sys, json
try: rows = json.load(sys.stdin).get('messages', [])
except Exception: rows = []
for m in rows:
    meta = json.loads(m.get('meta') or '{}')
    where = ' [run %s at %.2f km]' % (m['run_id'][:8], meta.get('km', 0)) if m.get('run_id') else ' [no run]'
    tag = 'VOICE' if m.get('source') == 'voice' else 'TERMINAL'
    print('%s #%s %sZ%s: %s' % (tag, m['id'], m['created_at'], where, m['text'].replace(chr(10), ' ')))")
  if [ -n "$msgs" ]; then
    printf '%s\n' "$msgs"
    echo "MESSAGE FROM THE RUNNER: answer with scripts/home-base/reply.sh \"<text>\""
    exit 0
  fi

  sleep "$POLL"
  elapsed=$((elapsed + POLL))
  if [ "$elapsed" -ge "$IDLE_TIMEOUT" ]; then echo "IDLE: nothing for ${IDLE_TIMEOUT}s, start me again"; exit 0; fi
done
