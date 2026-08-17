/// Real knowledge about a CONFIRMED venue, so the coaches describe the room
/// the runner is actually standing in.
///
/// The failure this fixes (founder, 2026-08-17): Ricky kept telling him he was
/// facing a wall with a TV on it, in a gym on the 59th floor of the Park Hyatt
/// with floor-to-ceiling windows over the Beijing CBD. That wasn't Ricky
/// improvising badly — OUTDOOR_VS_TREADMILL instructed exactly that furniture.
/// Invented detail is fine when we know nothing; it is corrosive once we know
/// better, because the whole promise is a companion who is actually there.
///
/// Profiles are written by the AGENT (who can research a venue) and keyed on
/// the confirmed venue name, so the work happens once per venue rather than
/// once per run.

export interface VenueProfileEnv {
    DB?: D1Database;
}

const MEMO_TTL_MS = 300_000;
const memo = new Map<string, { at: number; profile: string | null }>();

/// Normalise for lookup: the runner's confirmed string and the researched one
/// won't match byte-for-byte across runs (branch suffixes, casing, spacing).
export function venueKey(name: string): string {
    return name
        .toLowerCase()
        .replace(/[（(].*?[)）]/g, " ")   // drop "(Guomao Branch)" style suffixes
        .replace(/[^a-z0-9一-鿿]+/g, " ")
        .trim()
        .replace(/\s+/g, " ");
}

export async function fetchVenueProfile(
    env: VenueProfileEnv,
    venue: string | undefined,
): Promise<string | null> {
    if (!env.DB || !venue) return null;
    const key = venueKey(venue);
    if (!key) return null;
    const hit = memo.get(key);
    if (hit && Date.now() - hit.at < MEMO_TTL_MS) return hit.profile;
    try {
        // Exact key first; then a contains-match so "Park Hyatt Beijing" still
        // resolves when the phone hands back a longer branch string.
        let row = await env.DB
            .prepare("SELECT profile FROM venue_profile WHERE venue_key = ?")
            .bind(key).first<{ profile: string }>();
        if (!row) {
            row = await env.DB
                .prepare("SELECT profile FROM venue_profile WHERE ? LIKE '%' || venue_key || '%' ORDER BY length(venue_key) DESC LIMIT 1")
                .bind(key).first<{ profile: string }>();
        }
        const profile = row?.profile ?? null;
        memo.set(key, { at: Date.now(), profile });
        return profile;
    } catch {
        return null;   // table missing or D1 hiccup — never cost a spoken line
    }
}

/// The prompt block. Deliberately forceful about SUPERSEDING the generic gym
/// furniture, because that furniture is written into the persona prompt and
/// will otherwise win by sheer repetition.
export function formatVenueProfile(venue: string, profile: string): string {
    return [
        `WHAT ${venue.toUpperCase()} IS ACTUALLY LIKE (researched, TRUE, and it OVERRIDES every generic gym detail you have been given):`,
        profile,
        "USE THIS INSTEAD OF THE STOCK GYM FURNITURE. You have standing instructions elsewhere about mirrors, a wall-mounted TV and a bloke deadlifting behind him — those are DEFAULTS for when we don't know the room, and they are now WRONG here. Do not describe a wall, a mirror or a telly he cannot see. Describe what is actually in front of him.",
        "Use it the way someone standing next to him would: one concrete detail when it sharpens a line, not a tour of the amenities. Never recite this block.",
    ].join("\n");
}
