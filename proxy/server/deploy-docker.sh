#!/usr/bin/env bash
# Deploy the AARC US gateway to a Docker host. Platform-agnostic: the only
# host requirements are sshd + docker compose. Migrating to a new box is
# this same script with a new HOST.
#
# Usage: ./deploy-docker.sh   (run from anywhere; paths are derived)
set -euo pipefail

HOST="root@gateway.aarun.club"
REMOTE_DIR="/opt/aarc-proxy"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> rsync proxy/ -> $HOST:$REMOTE_DIR"
rsync -az --delete \
  --exclude node_modules --exclude .wrangler --exclude dist \
  --exclude .env --exclude .dev.vars \
  "$PROXY_DIR/" "$HOST:$REMOTE_DIR/"

echo "==> remote: seed .env on first deploy, then compose up"
ssh "$HOST" "set -e; cd $REMOTE_DIR/server; \
  if [ ! -f .env ]; then cp .env.example .env; echo '!! Seeded server/.env from example — FILL IN KEYS, then rerun'; exit 1; fi; \
  docker compose up -d --build; \
  docker compose ps"

echo "==> done. Smoke: curl -s https://gateway.aarun.club/ping"
