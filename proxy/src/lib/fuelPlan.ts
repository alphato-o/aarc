/// His marathon fuel plan (founder, 2026-10-24): 8 GU gels, 2 packs of salt
/// tablets (~10), first gel around 10 km; not all of it has to go. Each stop
/// sits on an aid station from the course file. `km` is the kilometre whose
/// readout (or pack line) carries the cue: the one just before the station.
export interface FuelStop {
    km: number;
    stationKm: number;
    item: "gel" | "salt";
    n: number;
    cue: string;
}

export const MARATHON_FUEL: FuelStop[] = [
    { km: 10, stationKm: 10, item: "gel", n: 1, cue: "Gel one at this station, with water." },
    { km: 12, stationKm: 12.5, item: "salt", n: 1, cue: "Salt tablet one at the twelve point five water." },
    { km: 17, stationKm: 17.5, item: "gel", n: 2, cue: "Gel two at the seventeen point five water." },
    { km: 22, stationKm: 22.5, item: "salt", n: 2, cue: "Salt tablet two at the twenty two point five water." },
    { km: 25, stationKm: 25, item: "gel", n: 3, cue: "Gel three at this station, with water." },
    { km: 30, stationKm: 30, item: "gel", n: 4, cue: "Gel four at this station, with water." },
    { km: 32, stationKm: 32.5, item: "salt", n: 3, cue: "Salt tablet three at the thirty two point five water." },
    { km: 35, stationKm: 35, item: "gel", n: 5, cue: "Gel five at this station, with water." },
    { km: 37, stationKm: 37.5, item: "salt", n: 4, cue: "Salt tablet four at the thirty seven point five water." },
];

const CUE_WORDS = /\b(gel|salt)\b/i;

export function fuelStopAt(km: number): FuelStop | undefined {
    return MARATHON_FUEL.find((s) => s.km === km);
}

/// The mechanical half: whatever the model wrote, the kilometre's cue is said.
export function withFuelCue(text: string, km: number): string {
    const stop = fuelStopAt(km);
    if (!stop || CUE_WORDS.test(text)) return text;
    return `${text.trim()} ${stop.cue}`;
}

export function fuelPlanBlock(): string[] {
    return [
        "FUEL PLAN (his own kit: 8 GU gels, about 10 salt tablets; every stop is at an aid station, always with water):",
        ...MARATHON_FUEL.map((s) => `- ${s.item === "gel" ? `gel ${s.n}` : `salt tablet ${s.n}`} at the ${s.stationKm} km station (cued in the km ${s.km} line)`),
        "- spares: 3 gels and about 6 tablets. A calf or hamstring twinge means one extra salt tablet now, with water; at most one every 20 minutes.",
        "- no gel in the last 5 km: it lands after the finish.",
    ];
}
