/// Public marketing site for AARC at the apex aarun.club (host routing in
/// src/index.ts). The page and its device mockups are static files in
/// public/site/; "/" serves /site/ through the ASSETS binding.
///
/// This page is PUBLIC: Ricky and Home Base only, never any other voice or
/// adult content, and the founder is "Alpha".

interface Env {
    ASSETS?: Fetcher;
}

export async function landingHandler(request: Request, env: Env): Promise<Response> {
    if (!env.ASSETS) return new Response("Not found", { status: 404 });
    const res = await env.ASSETS.fetch(new Request(new URL("/site/", request.url), request));
    const out = new Response(res.body, res);
    out.headers.set("cache-control", "public, max-age=300");
    return out;
}
