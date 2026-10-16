/// Race course knowledge (founder, 2026-10-16): the Tianjin Marathon route was
/// traced with Amap (walking directions through every turn, kilometres
/// re-anchored to the organiser's map), then every kilometre was looked up
/// for its street, district and landmarks, with the aid-station table and
/// hand-written notes on top. In "actual" race mode every voice gets a block
/// that says where he is, what is coming and where the next water is, so the
/// lines are specific to the kilometre he is running, not generic.

import tianjin from "../data/courses/tianjin-2026.json";

export interface CourseKm {
    km: number;
    district?: string;
    street?: string;
    landmarks: string[];
    note?: string;
    stations?: string[];
}

export interface Course {
    id: string;
    name: string;
    date: string;
    totalM: number;
    km: CourseKm[];
    /// (lon, lat, official metres) samples along the route, GCJ-02.
    polyline: [number, number, number][];
}

const COURSES: Record<string, Course> = { tianjin2026: tianjin as unknown as Course };

export function courseById(id: string): Course | null {
    return COURSES[id] ?? null;
}

/// The course that applies to this run: actual race mode means the marathon.
export function courseFor(raceMode: string | undefined): Course | null {
    return raceMode === "actual" ? (COURSES.tianjin2026 ?? null) : null;
}

function fmtKm(m: number): string { return (m / 1000).toFixed(1); }

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
    out.push(`- remaining: ${fmtKm(course.totalM - d)} km to the finish at 天津奥林匹克中心 (the Water Drop stadium)`);
    out.push("Use these as the REAL surroundings when the live GPS block is thin or absent; name the places as given, in Chinese where they are Chinese. The course is flat; the only climbs are the bridges. Do not recite the list; pick the one thing that sharpens the line.");
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
    return out;
}
