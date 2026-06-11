#!/usr/bin/env bash
# Deploy the AARC standalone Node proxy to a VPS (the "US3" box).
#
# - rsyncs the whole proxy/ tree (the bundle step needs ../src and zod)
# - installs deps + builds remotely, installs/restarts the systemd unit
# - assumes the SSH user is root or has passwordless sudo
#
# Usage: edit HOST below, then  ./deploy.sh
set -euo pipefail

HOST="US3_HOST_HERE"          # e.g. root@203.0.113.7 or alpha@us3.aarun.club
REMOTE_DIR="/opt/aarc-proxy"

if [ "$HOST" = "US3_HOST_HERE" ]; then
    echo "deploy.sh: edit HOST at the top of this script first." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> rsync $PROXY_DIR -> $HOST:$REMOTE_DIR"
rsync -az --delete \
    --exclude node_modules \
    --exclude .wrangler \
    --exclude server/dist \
    --exclude server/.env \
    --exclude .dev.vars \
    "$PROXY_DIR/" "$HOST:$REMOTE_DIR/"

echo "==> remote install + build + (re)start service"
# Quoted heredoc: everything below runs remotely; REMOTE_DIR is passed via env.
ssh "$HOST" "REMOTE_DIR='$REMOTE_DIR' bash -s" <<'REMOTE'
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

cd "$REMOTE_DIR"
npm install --omit=dev          # zod (Worker dep) without wrangler etc.

cd server
npm install                     # esbuild
npm run build                   # -> dist/worker.mjs

if [ ! -f .env ]; then
    cp .env.example .env
    echo "WARNING: created server/.env from .env.example — fill in real keys, then:"
    echo "         systemctl restart aarc-proxy"
fi

$SUDO install -m 644 aarc-proxy.service /etc/systemd/system/aarc-proxy.service
$SUDO systemctl daemon-reload
$SUDO systemctl enable aarc-proxy
$SUDO systemctl restart aarc-proxy
sleep 1
$SUDO systemctl --no-pager --full status aarc-proxy | head -n 12
REMOTE

echo "==> done. Smoke test:  curl -s http://<vps>:8787/ping   (or via Caddy: https://<subdomain>/ping)"
