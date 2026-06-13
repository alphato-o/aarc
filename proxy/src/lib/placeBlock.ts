/// Shared prompt block for the live place context (outdoor runs).
///
/// When the phone sends real surroundings, the block both supplies the
/// material AND forbids invented scenery — the entire point is replacing
/// fabricated cargo-shorts men with the actual hotel across the road.

import type { PlaceInfo } from "../schemas";

export function pushPlaceBlock(lines: string[], place: PlaceInfo | undefined): void {
    if (!place) return;
    const hasNames = !!(place.road || place.area || (place.pois && place.pois.length));
    if (!hasNames && !place.route) return;
    lines.push("");
    lines.push("REAL SURROUNDINGS (live GPS — REAL places, use them; while this block is present NEVER invent streets, people, buildings or scenery):");
    if (place.road || place.area) {
        lines.push(`- location: ${[place.road, place.area].filter(Boolean).join(", ")}`);
    }
    if (place.pois && place.pois.length > 0) {
        lines.push(`- notable places nearby (say the name naturally, as a local would — no address, no "hotel" tacked on): ${place.pois.join("; ")}`);
    }
    if (place.route) {
        lines.push(`- route so far: ${place.route}`);
    }
    lines.push("Ground the line in one of these specifics when it sharpens the joke — name the actual place. Don't force it into every line, and never recite the list.");
    lines.push("Names may be in the LOCAL language (e.g. Chinese) — say them AS GIVEN, in that language, mid-sentence. Do not translate or transliterate them; voicing the real local name is the point.");
}
