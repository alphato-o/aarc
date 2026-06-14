/// Map-tile relay for the share-card route map.
///
/// The iOS app + web dashboard can't fetch AutoNavi (高德) tiles directly:
/// `MKMapSnapshotter` is blank in China and an on-device fetch of AutoNavi's
/// `wprd` tile servers returns blank/placeholder tiles (no referer/SDK
/// context). The SAME request made server-side returns real tiles. So we relay
/// them: client → this endpoint → AutoNavi, server-side, then cache at the
/// edge. Tiles are public map imagery, so no auth.
///
/// GET /maptile?x=&y=&z=  →  image/png (style-7 base map)

const COORD_RE = /^\d{1,9}$/;

export async function mapTileHandler(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const x = url.searchParams.get("x") ?? "";
    const y = url.searchParams.get("y") ?? "";
    const z = url.searchParams.get("z") ?? "";
    if (![x, y, z].every((v) => COORD_RE.test(v))) {
        return new Response("bad tile coords", { status: 400 });
    }

    const s = (Math.abs(Number(x) + Number(y)) % 4) + 1;
    const upstream =
        `https://wprd0${s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scl=1&style=7&x=${x}&y=${y}&z=${z}`;

    let resp: Response;
    try {
        resp = await fetch(upstream, {
            headers: {
                // Mimic a browser request so AutoNavi serves real tiles.
                "Referer": "https://www.amap.com/",
                "User-Agent":
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            },
            // Cache at the Cloudflare edge for a week — tiles are immutable.
            cf: { cacheTtl: 604800, cacheEverything: true },
        });
    } catch {
        return new Response("upstream fetch failed", { status: 502 });
    }
    if (!resp.ok) return new Response("upstream error", { status: 502 });

    const body = await resp.arrayBuffer();
    return new Response(body, {
        status: 200,
        headers: {
            "content-type": resp.headers.get("content-type") ?? "image/png",
            "cache-control": "public, max-age=604800, immutable",
            "access-control-allow-origin": "*",
        },
    });
}
