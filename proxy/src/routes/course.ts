/// GET /course/:id            — the course (markers + polyline) for the app and the desk.
/// GET /course/:id/at?km=12.3 — the prompt block Home Base, Ricky and Jessica see at that point (admin preview).
import { courseById, courseBlock } from "../lib/course";

const json = (data: unknown, status = 200): Response =>
    new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

export function courseHandler(request: Request, url: URL): Response {
    const m = url.pathname.match(/^\/course\/([a-z0-9]+)(\/at)?$/);
    if (!m) return json({ ok: false, error: "not found" }, 404);
    const course = courseById(m[1] ?? "");
    if (!course) return json({ ok: false, error: "unknown course" }, 404);
    if (m[2]) {
        const km = Number(url.searchParams.get("km") ?? "0");
        return json({ ok: true, km, block: courseBlock(course, km * 1000) });
    }
    const { polyline, ...rest } = course;
    return json({ ok: true, course: { ...rest, polyline: url.searchParams.get("polyline") === "1" ? polyline : undefined } });
}
