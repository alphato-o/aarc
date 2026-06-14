/// Server-side static route map for the share card (iOS + web dashboard).
///
/// The device/browser can't reliably stitch Apple/AutoNavi tiles itself in
/// China (MKMapSnapshotter is blank; on-device tile fetches are slow/blank).
/// So the server does it: fetch the covering AutoNavi (高德) tiles, composite
/// them, draw the performance-colored route on top, return ONE PNG. One small
/// request from the client instead of a dozen flaky tile fetches.
///
/// POST /staticmap   body JSON:
///   { w, h, mode: "pace"|"hr", datum: "gcj"|"wgs",
///     points: [[lon, lat, value], ...] }   value = km/h (pace) or bpm (hr)
/// → image/png  (w×h)

import UPNG from "upng-js";

interface Body {
    w?: number;
    h?: number;
    mode?: "pace" | "hr";
    datum?: "gcj" | "wgs";
    points?: [number, number, number | null][];
    drawRoute?: boolean;   // bake the route server-side (default: client draws it)
    padBottom?: number;    // reserve this many px at the bottom (route fits above it)
}

const TILE = 256;
const MAX_DIM = 1200;

// --- WGS-84 → GCJ-02 (AutoNavi tiles are GCJ) ------------------------------
const GCJ_A = 6378245.0;
const GCJ_EE = 0.00669342162296594323;
function tLat(x: number, y: number): number {
    let r = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
    r += ((20 * Math.sin(6 * x * Math.PI) + 20 * Math.sin(2 * x * Math.PI)) * 2) / 3;
    r += ((20 * Math.sin(y * Math.PI) + 40 * Math.sin((y / 3) * Math.PI)) * 2) / 3;
    r += ((160 * Math.sin((y / 12) * Math.PI) + 320 * Math.sin((y * Math.PI) / 30)) * 2) / 3;
    return r;
}
function tLon(x: number, y: number): number {
    let r = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
    r += ((20 * Math.sin(6 * x * Math.PI) + 20 * Math.sin(2 * x * Math.PI)) * 2) / 3;
    r += ((20 * Math.sin(x * Math.PI) + 40 * Math.sin((x / 3) * Math.PI)) * 2) / 3;
    r += ((150 * Math.sin((x / 12) * Math.PI) + 300 * Math.sin((x / 30) * Math.PI)) * 2) / 3;
    return r;
}
/// GCJ-02 → WGS-84 (one-pass reverse; ~1m error, fine for a share map). Only
/// used if a caller sends GCJ; iOS converts its display trail to WGS itself
/// and the dashboard's GPS log is already WGS, so the default path is WGS.
function gcjToWgs(lon: number, lat: number): [number, number] {
    let dLat = tLat(lon - 105, lat - 35);
    let dLon = tLon(lon - 105, lat - 35);
    const rad = (lat / 180) * Math.PI;
    let m = Math.sin(rad);
    m = 1 - GCJ_EE * m * m;
    const sm = Math.sqrt(m);
    dLat = (dLat * 180) / (((GCJ_A * (1 - GCJ_EE)) / (m * sm)) * Math.PI);
    dLon = (dLon * 180) / ((GCJ_A / sm) * Math.cos(rad) * Math.PI);
    return [lon - dLon, lat - dLat];
}

// --- Web-Mercator world pixels (tile=256) ----------------------------------
function world(lon: number, lat: number, z: number): [number, number] {
    const n = TILE * Math.pow(2, z);
    const x = ((lon + 180) / 360) * n;
    const r = (lat * Math.PI) / 180;
    const y = ((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * n;
    return [x, y];
}

// --- performance hue (matches the iOS RunMapView / ShareMap palette) -------
function hsvToRgb(h: number, s: number, v: number): [number, number, number] {
    const i = Math.floor(h * 6);
    const f = h * 6 - i;
    const p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
    let r = 0, g = 0, b = 0;
    switch (i % 6) {
        case 0: r = v; g = t; b = p; break;
        case 1: r = q; g = v; b = p; break;
        case 2: r = p; g = v; b = t; break;
        case 3: r = p; g = q; b = v; break;
        case 4: r = t; g = p; b = v; break;
        case 5: r = v; g = p; b = q; break;
    }
    return [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)];
}
function rampColor(v: number | null, lo: number, hi: number, mode: string): [number, number, number] {
    if (v == null || v <= 0 || hi <= lo) return [168, 199, 176];
    const t = (v - lo) / (hi - lo);
    return mode === "hr" ? hsvToRgb(0.62 * (1 - t), 0.85, 0.92) : hsvToRgb(0.33 * t, 0.85, 0.92);
}

// Label-free dark basemap (CARTO, OSM/WGS-84). No Chinese labels / POI noise,
// already dark; we add the brand-green tint on composite. Fetched server-side
// so China reachability is a non-issue. One retry so a dropped tile doesn't
// leave a seam.
async function fetchTile(x: number, y: number, z: number): Promise<Uint8Array | null> {
    const sub = ["a", "b", "c"][Math.abs(x + y) % 3];
    const url = `https://${sub}.basemaps.cartocdn.com/dark_nolabels/${z}/${x}/${y}.png`;
    for (let attempt = 0; attempt < 2; attempt++) {
        try {
            const resp = await fetch(url, {
                headers: { "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15" },
                cf: { cacheTtl: 604800, cacheEverything: true },
            } as RequestInit);
            if (!resp.ok) continue;
            const buf = await resp.arrayBuffer();
            const img = UPNG.decode(buf);
            return new Uint8Array(UPNG.toRGBA8(img)[0]); // 256*256*4 RGBA
        } catch {
            // retry once
        }
    }
    return null;
}

export async function staticMapHandler(request: Request): Promise<Response> {
    let body: Body;
    try {
        body = (await request.json()) as Body;
    } catch {
        return new Response("bad json", { status: 400 });
    }
    const W = Math.min(MAX_DIM, Math.max(64, Math.round(body.w ?? 928)));
    const H = Math.min(MAX_DIM, Math.max(64, Math.round(body.h ?? 432)));
    const mode = body.mode === "hr" ? "hr" : "pace";
    const raw = Array.isArray(body.points) ? body.points : [];
    if (raw.length < 2) return new Response("need >=2 points", { status: 400 });

    // CARTO tiles are WGS-84 — keep points in WGS (convert only if a caller
    // explicitly sends GCJ).
    const pts = raw.map((p) => {
        const lon = p[0]!, lat = p[1]!;
        const [wlon, wlat] = body.datum === "gcj" ? gcjToWgs(lon, lat) : [lon, lat];
        return { lon: wlon, lat: wlat, v: p[2] ?? null };
    });

    let minLon = pts[0]!.lon, maxLon = pts[0]!.lon, minLat = pts[0]!.lat, maxLat = pts[0]!.lat;
    for (const p of pts) {
        minLon = Math.min(minLon, p.lon); maxLon = Math.max(maxLon, p.lon);
        minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat);
    }

    // Reserve a bottom band (for a KPI overlay): fit + center the route into
    // the region ABOVE it, while the tiles still fill the whole image.
    const padBottom = Math.max(0, Math.min(H - 40, Math.round(body.padBottom ?? 0)));
    const fitH = H - padBottom;
    let zoom = 3;
    for (let z = 19; z >= 3; z--) {
        const [tlx, tly] = world(minLon, maxLat, z);
        const [brx, bry] = world(maxLon, minLat, z);
        if (brx - tlx <= W * 0.84 && bry - tly <= fitH * 0.84) { zoom = z; break; }
    }
    const [cx, cy] = world((minLon + maxLon) / 2, (minLat + maxLat) / 2, zoom);
    const originX = cx - W / 2, originY = cy - fitH / 2;
    const proj = (lon: number, lat: number): [number, number] => {
        const [wx, wy] = world(lon, lat, zoom);
        return [wx - originX, wy - originY];
    };

    // Canvas RGBA buffer.
    const out = new Uint8Array(W * H * 4);
    // Base fill (#08110b) for any tile gap.
    for (let i = 0; i < W * H; i++) { out[i * 4] = 8; out[i * 4 + 1] = 17; out[i * 4 + 2] = 11; out[i * 4 + 3] = 255; }

    // Fetch + composite the covering tiles.
    const minTX = Math.floor(originX / TILE), maxTX = Math.floor((originX + W) / TILE);
    const minTY = Math.floor(originY / TILE), maxTY = Math.floor((originY + H) / TILE);
    const maxIdx = Math.pow(2, zoom) - 1;
    const jobs: Promise<void>[] = [];
    for (let tx = minTX; tx <= maxTX; tx++) {
        for (let ty = minTY; ty <= maxTY; ty++) {
            if (tx < 0 || ty < 0 || tx > maxIdx || ty > maxIdx) continue;
            const dx = Math.round(tx * TILE - originX), dy = Math.round(ty * TILE - originY);
            jobs.push(fetchTile(tx, ty, zoom).then((rgba) => {
                if (!rgba) return;
                for (let py = 0; py < TILE; py++) {
                    const oy = dy + py;
                    if (oy < 0 || oy >= H) continue;
                    for (let px = 0; px < TILE; px++) {
                        const ox = dx + px;
                        if (ox < 0 || ox >= W) continue;
                        const si = (py * TILE + px) * 4, di = (oy * W + ox) * 4;
                        // Brand-green tint: a gentle green lean (G lifted a
                        // touch over R/B) but lighter than before, so the road
                        // network stays clearly visible on the dark card.
                        out[di] = Math.min(255, Math.round(rgba[si]! * 0.74 + 12));
                        out[di + 1] = Math.min(255, Math.round(rgba[si + 1]! * 0.92 + 20));
                        out[di + 2] = Math.min(255, Math.round(rgba[si + 2]! * 0.78 + 14));
                        out[di + 3] = 255;
                    }
                }
            }));
        }
    }
    await Promise.all(jobs);

    // The route is normally drawn CLIENT-side over this base — so the still
    // image and the video share one map, and the video can animate the route
    // as the audio plays (the client redraws the route up to progress(t) each
    // frame). `drawRoute:true` bakes it server-side for callers that just want
    // a complete still in one request.
    if (body.drawRoute) {
        const vals = pts.map((p) => p.v).filter((v): v is number => v != null && v > 0);
        const lo = vals.length ? Math.min(...vals) : 0, hi = vals.length ? Math.max(...vals) : 1;
        const R = 4;
        const disc = (cxp: number, cyp: number, rgb: [number, number, number]) => {
            for (let yy = -R; yy <= R; yy++) {
                for (let xx = -R; xx <= R; xx++) {
                    if (xx * xx + yy * yy > R * R) continue;
                    const ox = Math.round(cxp) + xx, oy = Math.round(cyp) + yy;
                    if (ox < 0 || ox >= W || oy < 0 || oy >= H) continue;
                    const di = (oy * W + ox) * 4;
                    out[di] = rgb[0]; out[di + 1] = rgb[1]; out[di + 2] = rgb[2]; out[di + 3] = 255;
                }
            }
        };
        for (let i = 1; i < pts.length; i++) {
            const a = pts[i - 1]!, b = pts[i]!;
            const [ax, ay] = proj(a.lon, a.lat);
            const [bx, by] = proj(b.lon, b.lat);
            const rgb = rampColor(b.v, lo, hi, mode);
            const steps = Math.max(1, Math.ceil(Math.hypot(bx - ax, by - ay) / 2));
            for (let s = 0; s <= steps; s++) {
                disc(ax + ((bx - ax) * s) / steps, ay + ((by - ay) * s) / steps, rgb);
            }
        }
        const [sx, sy] = proj(pts[0]!.lon, pts[0]!.lat);
        for (let yy = -7; yy <= 7; yy++) for (let xx = -7; xx <= 7; xx++) {
            if (xx * xx + yy * yy > 49) continue;
            const ox = Math.round(sx) + xx, oy = Math.round(sy) + yy;
            if (ox < 0 || ox >= W || oy < 0 || oy >= H) continue;
            const di = (oy * W + ox) * 4;
            out[di] = 207; out[di + 1] = 232; out[di + 2] = 214; out[di + 3] = 255;
        }
    }

    const png = UPNG.encode([out.buffer], W, H, 0);
    return new Response(png, {
        status: 200,
        headers: {
            "content-type": "image/png",
            "cache-control": "no-store",
            "access-control-allow-origin": "*",
            // Projection params so the client can place the route on the base
            // exactly (no formula drift): pixel = world(lon,lat,zoom) - origin.
            "access-control-expose-headers": "X-Map-Zoom, X-Map-Ox, X-Map-Oy",
            "X-Map-Zoom": String(zoom),
            "X-Map-Ox": String(originX),
            "X-Map-Oy": String(originY),
        },
    });
}
