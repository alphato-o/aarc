# AARC proxy — standalone Node host (US VPS / "US3")

Runs the **same handlers** as the Cloudflare Worker (`proxy/src/index.ts`)
on a plain Node 20+ box, as a second, China-friendlier endpoint. The Worker
handlers are plain `(Request, env) -> Promise<Response>` functions using only
`fetch`/`Request`/`Response` — all native in Node, so no code fork: `build.mjs`
bundles the Worker entry with esbuild into `dist/worker.mjs` and `server.mjs`
adapts `node:http` to/from WHATWG and calls `worker.fetch(request, env, ctx)`.

- **env** = `process.env` + a tiny built-in `.env` loader (`server/.env`).
- **Cloudflare bindings** (`env.DB` D1, `env.VOICES` R2 — used by
  run-diagnostics routes) are **stubbed**: those routes return a clear `503
  binding_unavailable`; all LLM/TTS routes work fully.
- Zero runtime deps; esbuild is the only devDep.

## Bring-up (on the VPS)

Prereq: Node 20+ (`node --version`), rsync, and (recommended) Caddy.

Option A — one shot from your laptop:

```sh
# 1. edit HOST at the top of deploy.sh (replace US3_HOST_HERE)
cd proxy/server
./deploy.sh
# 2. first run only: fill in real keys on the box
ssh $HOST 'vi /opt/aarc-proxy/server/.env && systemctl restart aarc-proxy'
# 3. smoke test
curl -s http://<vps-ip>:8787/ping
```

Option B — manual, on the box:

```sh
# code lives at /opt/aarc-proxy (rsync or git clone the proxy/ dir there)
cd /opt/aarc-proxy && npm install --omit=dev      # zod for the bundle
cd server && npm install && npm run build          # esbuild -> dist/worker.mjs
cp .env.example .env && $EDITOR .env               # real keys
node server.mjs                                    # listens on :8787 (PORT env)
# as a service:
install -m 644 aarc-proxy.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now aarc-proxy
journalctl -u aarc-proxy -f
```

Endpoints (same as the Worker): `GET /ping`, `POST /generate-script`,
`POST /dynamic-line`, `POST /react-line`, `POST /music-comment`, `POST /tts`.

## TLS via Caddy (reverse proxy)

`/etc/caddy/Caddyfile` — Caddy handles the cert automatically:

```caddyfile
us3.aarun.club {
    reverse_proxy 127.0.0.1:8787
}
```

Then `systemctl reload caddy`. The Node server itself stays plain HTTP on
localhost; only Caddy is exposed on :443.

## DNS — IMPORTANT for the China path

> **NOTE:** the subdomain (e.g. `us3.aarun.club`) must be a **DIRECT A
> record to the VPS IP — grey-cloud in Cloudflare DNS, NOT proxied
> (orange-cloud)**. The entire point of this endpoint is that China traffic
> avoids the Cloudflare edge; if the record is CF-proxied you've just
> re-routed everything back through Cloudflare and gained nothing. Also
> required for Caddy's ACME HTTP-01 cert issuance to see the real host.

## Updating

Re-run `./deploy.sh` — it rsyncs, rebuilds, and restarts the unit.
`server/.env` on the box is never overwritten (excluded from rsync).

## Gotchas

- `dist/worker.mjs` is a build artifact — never edit it; edit `proxy/src/`
  and rebuild.
- If a future Worker change imports a `cloudflare:` runtime module (not just
  D1/R2 bindings on `env`), the esbuild step will fail loudly. That code
  can't run on Node; gate it behind the bindings instead.
- The iOS app picks its base URL via `ios/AARC/Services/Config.swift`
  (`Config.apiBaseURL`) — point it at `https://us3.aarun.club` to use this
  endpoint.
