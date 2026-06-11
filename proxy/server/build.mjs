/**
 * Bundle the Cloudflare Worker entry (proxy/src/index.ts) into a single
 * Node-importable ESM file at dist/worker.mjs.
 *
 * The Worker handlers are plain (Request, env) -> Promise<Response>
 * functions using only fetch/Request/Response — all native in Node 20+.
 * Workers-specific TYPES (ExecutionContext, ExportedHandler) are erased
 * by esbuild; no Cloudflare runtime modules are imported. If a sibling
 * change ever adds `import ... from "cloudflare:..."` this build will
 * fail loudly — that's intentional (such a module cannot run on Node).
 */
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));

await build({
    entryPoints: [path.join(here, "..", "src", "index.ts")],
    outfile: path.join(here, "dist", "worker.mjs"),
    bundle: true,
    format: "esm",
    platform: "node",
    target: "node20",
    sourcemap: false,
    logLevel: "info",
});
