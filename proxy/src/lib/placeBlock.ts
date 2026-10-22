/// Shared prompt block for the live place context (outdoor runs).
///
/// When the phone sends real surroundings, the block both supplies the
/// material AND forbids invented scenery — the entire point is replacing
/// fabricated cargo-shorts men with the actual hotel across the road.

import type { PlaceInfo } from "../schemas";
import type { LocalIntel } from "./amap";

/// `intel` is Amap's view of the same fix (GCJ-corrected server side). In
/// China it outranks the phone's POI list, which was ~600 m off on 22 Oct.
export function pushPlaceBlock(lines: string[], place: PlaceInfo | undefined, intel?: LocalIntel | null): void {
    if (!place && !intel?.inside && !intel?.nearby.length) return;
    place = place ?? {};
    const amapNearby = intel?.nearby.length ? intel.nearby.map((n) => `${n.name} (${n.meters} m)`) : null;
    // With an Amap fix in hand the phone list (off by the datum) is dropped, even if Amap found nothing.
    const pois = intel ? (amapNearby ?? []) : place.pois;
    const hasNames = !!(place.road || place.area || intel?.inside || (pois && pois.length));
    if (!hasNames && !place.route) return;
    lines.push("");
    lines.push("REAL SURROUNDINGS (live GPS — REAL places, use them; while this block is present NEVER invent streets, people, buildings or scenery):");
    if (place.road || place.area) {
        lines.push(`- location: ${[place.road, place.area].filter(Boolean).join(", ")}`);
    }
    if (intel?.inside) {
        lines.push(`- he is running INSIDE ${intel.inside} right now (in it, not near it, not a few hundred metres away)`);
    }
    if (pois && pois.length > 0) {
        lines.push(`- notable places nearby (say the name naturally, no address, no "hotel" tacked on): ${pois.join("; ")}`);
    }
    if (place.route) {
        lines.push(`- route so far: ${place.route}`);
    }
    lines.push("Ground the line in one of these specifics when it sharpens the joke — name the actual place. Don't force it into every line, and never recite the list.");
    lines.push("Names may be given in Chinese. Your line must be English only: say the English name if there is one (CBD历史文化公园 is the CBD History and Culture Park), else pinyin, never Chinese characters.");
}
