/// Race course knowledge (founder, 2026-10-16): the Tianjin Marathon route was
/// traced with Amap (walking directions through every turn, kilometres
/// re-anchored to the organiser's map), then every kilometre was looked up
/// for its street, district and landmarks, with the aid-station table and
/// hand-written notes on top. In "actual" race mode every voice gets a block
/// that says where he is, what is coming and where the next water is, so the
/// lines are specific to the kilometre he is running, not generic.

import tianjin from "../data/courses/tianjin-2026.json";
import tianjinStories from "../data/courses/tianjin-2026-stories.json";

export interface CourseKm {
    km: number;
    district?: string;
    street?: string;
    landmarks: string[];
    note?: string;
    stations?: string[];
}

/// A story tied to a point on the course: told once, around `atM`, in the
/// voice of whoever is speaking. The facts are true; the jokes are theirs.
export interface CourseStory {
    atM: number;
    span: number;
    title: string;
    text: string;
}

export interface Course {
    id: string;
    name: string;
    date: string;
    totalM: number;
    km: CourseKm[];
    /// (lon, lat, official metres) samples along the route, GCJ-02.
    polyline: [number, number, number][];
    /// The story pack (founder, 2026-10-17): the city, its history and the
    /// places on the route, so every voice can be a tour guide with a twist.
    stories?: CourseStory[];
    city?: string[];
}

const COURSES: Record<string, Course> = {
    tianjin2026: { ...(tianjin as unknown as Course), stories: tianjinStories.stories as CourseStory[], city: tianjinStories.city as string[] },
};

export function courseById(id: string): Course | null {
    return COURSES[id] ?? null;
}

/// The course that applies to this run: actual race mode means the marathon.
export function courseFor(raceMode: string | undefined): Course | null {
    return raceMode === "actual" ? (COURSES.tianjin2026 ?? null) : null;
}

function fmtKm(m: number): string { return (m / 1000).toFixed(1); }

/// The race is recorded for an English-speaking YouTube audience. On 17 Oct
/// the voices were told to read Chinese names aloud in Mandarin with the
/// English after; reversed 22 Oct (run CF3B6CD8): Chinese characters went into
/// English lines and the TTS read them out mid-sentence. Lines are English only;
/// lib/englishOnly.ts strips whatever slips through.
export const NAMES_RULE = "NAMES, a hard rule: every line is ENGLISH ONLY and never contains a Chinese character. Say a Chinese place by its English name (\"Racecourse Road\", \"the Drum Tower\", \"the Tianjin Eye, the Ferris wheel on the bridge\", \"the Haihe river\"), else in pinyin (\"Jinghua Street\", \"Hujialou\"), else describe it (\"the river road\", \"the station square\"). If you cannot render a name in English or pinyin, leave it out. Numbers are English words or digits, never Chinese numerals.";

/// The story for this point (covering it, or the next one within `aheadM`).
export function storyAt(course: Course, distanceMeters: number, aheadM = 700): { here: CourseStory | null; next: CourseStory | null } {
    const list = course.stories ?? [];
    let here: CourseStory | null = null;
    for (const st of list) if (distanceMeters >= st.atM - 150 && distanceMeters <= st.atM + st.span) { here = st; break; }
    if (!here) for (const st of list) if (st.atM > distanceMeters && st.atM - distanceMeters <= aheadM) { here = st; break; }
    const next = list.find((st) => st.atM > (here ? here.atM : distanceMeters) + 100) ?? null;
    return { here, next };
}

/// Where he is on the course and what is ahead, as prompt lines.
export function courseBlock(course: Course, distanceMeters: number): string[] {
    const d = Math.max(0, Math.min(course.totalM, distanceMeters));
    const kmIdx = Math.min(course.km.length - 1, Math.floor(d / 1000));
    const here = course.km[kmIdx];
    const next = course.km[kmIdx + 1];
    const after = course.km[kmIdx + 2];
    const out: string[] = [];
    if (!here) return out;
    out.push("");
    out.push(`RACE COURSE (${course.name}, ${course.date}; organiser's map, true; he is at km ${fmtKm(d)} of 42.2):`);
    const where = [here.street, here.district].filter(Boolean).join(", ");
    out.push(`- now: km ${here.km}${where ? `, on ${where}` : ""}${here.landmarks.length ? `; around him: ${here.landmarks.slice(0, 4).join(", ")}` : ""}`);
    if (here.note) out.push(`- here: ${here.note}`);
    if (next) {
        const inM = Math.max(0, next.km * 1000 - d);
        out.push(`- next, in ${Math.round(inM / 100) * 100} m: km ${next.km}${next.street ? ` on ${next.street}` : ""}${next.landmarks.length ? `, ${next.landmarks.slice(0, 3).join(", ")}` : ""}${next.note ? `. ${next.note}` : ""}`);
    }
    if (after && after.note) out.push(`- then: ${after.note}`);
    const station = course.km.find((k) => k.km * 1000 > d && k.stations && k.stations.length);
    if (station) out.push(`- next aid station: km ${station.km}, ${Math.round((station.km * 1000 - d) / 100) * 100} m ahead (${station.stations!.join(", ")})`);
    // The watch reads long on a race, so near the end the book, not the
    // number, says where the finish is (founder, 2026-10-18).
    out.push(course.totalM - d > 400
        ? `- remaining: about ${fmtKm(course.totalM - d)} km to the finish at 天津奥林匹克中心 (the Water Drop stadium); his watch may read a little long`
        : `- remaining: the finish arch at 天津奥林匹克中心 (the Water Drop stadium) is close. Never say the race is over or give a remaining number: his watch reads long, the arch is the finish`);
    out.push("Use these as the REAL surroundings when the live GPS block is thin or absent; name the places in English or pinyin, never in Chinese characters. The course is flat; the only climbs are the bridges. Do not recite the list; pick the one thing that sharpens the line.");
    out.push(NAMES_RULE);
    const st = storyAt(course, d);
    if (st.here) {
        out.push("");
        out.push(`STORY HERE (${st.here.title}; true, from the course file): ${st.here.text}`);
        out.push("Tell it the way a tour guide would if the tour guide were you: one or two sentences of the fact, in your own register, hung on what he is doing right now. Never read it out; pick the detail with the most bite. Do not tell the same story twice in a run.");
    }
    if (st.next) out.push(`- coming up at km ${fmtKm(st.next.atM)}: ${st.next.title}`);
    if (course.city?.length) {
        const pick = course.city[Math.floor(d / 7000) % course.city.length];
        if (pick) out.push(`- the city, for colour: ${pick}`);
    }
    return out;
}

export function pushCourseBlock(lines: string[], raceMode: string | undefined, distanceMeters: number): void {
    const course = courseFor(raceMode);
    if (!course) return;
    for (const l of courseBlock(course, distanceMeters)) lines.push(l);
}

/// The whole course for the script generator: one line per kilometre, so
/// the pre-baked race pack can hang its one-shot lines on real places.
export function courseScriptBlock(course: Course): string[] {
    const out: string[] = [];
    out.push("");
    out.push(`COURSE, kilometre by kilometre (${course.name}, ${course.date}; organiser's map, true):`);
    for (const k of course.km) {
        const where = [k.street, k.district].filter(Boolean).join(", ");
        const bits: string[] = [];
        if (where) bits.push(where);
        if (k.landmarks.length) bits.push(k.landmarks.slice(0, 3).join(", "));
        if (k.stations?.length) bits.push(`station: ${k.stations.join(", ")}`);
        out.push(`- km ${k.km}: ${bits.join("; ")}${k.note ? `. ${k.note}` : ""}`);
    }
    if (course.city?.length) {
        out.push("");
        out.push("THE CITY (true; material for the whole script):");
        for (const c of course.city) out.push(`- ${c}`);
    }
    out.push("");
    out.push(NAMES_RULE);
    if (course.stories?.length) {
        out.push("");
        out.push("STORIES ALONG THE COURSE (true; each gets ONE line, at the metres given, told your way):");
        for (const st of course.stories) out.push(`- at ${st.atM} m, "${st.title}": ${st.text}`);
    }
    return out;
}

/// True when a story covers this point: the line that fires here is the
/// tour-guide line and must not be withheld or swapped for a flash.
export function storyHere(raceMode: string | undefined, distanceMeters: number): CourseStory | null {
    const course = courseFor(raceMode);
    if (!course) return null;
    return storyAt(course, distanceMeters, 0).here;
}

/// A closing directive for a voice's prompt: this line carries the story.
export function pushStoryDirective(lines: string[], raceMode: string | undefined, distanceMeters: number, who: "ricky" | "jessica"): void {
    const st = storyHere(raceMode, distanceMeters);
    if (!st) return;
    lines.push("");
    lines.push(who === "ricky"
        ? `THIS LINE IS THE TOUR-GUIDE LINE. It must carry the STORY HERE ("${st.title}"): one true, specific detail from it, named as the file names it, then your angle on him. The live shop list and the weather do not matter for this line; the story does.`
        : `THIS LINE RIDES THE STORY HERE ("${st.title}"). If his line told it, add the detail he left out or turn it on him; if his line ignored it, you tell it, one true detail, your register. Never repeat his wording.`);
}
