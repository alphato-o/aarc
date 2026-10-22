/// What Home Base's desk (the agent at the office) said into his ears, and
/// what he said back over talk-back, read from agent_thread. Neither the
/// coaches nor the readout saw any of it on 22 Oct (run CF3B6CD8): Ricky
/// mocked "twelve-thirty-three a kay" 22 s after the desk told him to walk
/// for water, and the readout kept its format after he asked for a new one.
/// The phone sends no run id on these requests, so rows are picked by age;
/// there is one runner. Fails soft to empty.

export interface DeskEnv {
    DB?: D1Database;
}

export interface DeskLine {
    text: string;
    agoS: number;
}

/// Lines the desk spoke to him (role agent, spoken or watchdog auto) in the last `withinS` seconds.
export async function recentDeskLines(env: DeskEnv, withinS: number): Promise<DeskLine[]> {
    return rows(env, "role = 'agent' AND source IN ('spoken','auto')", withinS, 8);
}

/// What he said over talk-back during this run (voice rows only; the
/// terminal rows are the phone's diagnostics).
export async function runnerTalkback(env: DeskEnv, withinS: number): Promise<DeskLine[]> {
    return rows(env, "role = 'user' AND source = 'voice'", withinS, 6);
}

async function rows(env: DeskEnv, where: string, withinS: number, limit: number): Promise<DeskLine[]> {
    if (!env.DB) return [];
    try {
        const res = await env.DB.prepare(
            `SELECT text, CAST((julianday('now') - julianday(created_at)) * 86400 AS INTEGER) AS ago FROM agent_thread ` +
            `WHERE ${where} AND julianday(created_at) >= julianday('now', ?1) ORDER BY id DESC LIMIT ${limit}`,
        ).bind(`-${Math.max(1, Math.round(withinS))} seconds`).all<{ text: string; ago: number }>();
        return (res.results ?? []).reverse().map((r) => ({ text: String(r.text), agoS: Math.max(0, Number(r.ago) || 0) }));
    } catch {
        return [];
    }
}

/// A desk line that orders a walk, a drink or a slower pace.
const BREAK_ORDER = /\b(walk|walking|water|drink|drinking|sip|sips|swallows?|gulps?|capsules?|gel|fuel|hydrat\w*|ease (?:off|back|to|it)|back (?:it )?off|slow (?:it )?down)\b/i;

export function breakOrder(desk: DeskLine[], withinS = 120): DeskLine | null {
    for (let i = desk.length - 1; i >= 0; i--) {
        const d = desk[i]!;
        if (d.agoS <= withinS && BREAK_ORDER.test(d.text)) return d;
    }
    return null;
}

/// The coaches' block: the last desk lines, and, when one ordered a walk or
/// drink in the last two minutes, a hard rule against mocking the slow pace.
export async function pushDeskBlock(lines: string[], env: DeskEnv, trigger?: string): Promise<void> {
    const desk = await recentDeskLines(env, 240);
    if (!desk.length) return;
    lines.push("");
    lines.push("HOME BASE JUST SAID TO HIM (the desk's voice, already heard; never quote it, never contradict it):");
    for (const d of desk.slice(-3)) lines.push(`- ${d.agoS} s ago: "${d.text.slice(0, 300)}"`);
    const order = breakOrder(desk);
    if (order) {
        lines.push(`PLANNED BREAK IN FORCE: ${order.agoS} s ago Home Base told him to walk, drink or ease off. Any slow pace or stop right now is that ordered break, not weakness. Do NOT mock the pace, do NOT quote the pace number, do NOT call it walking, crawling or standing still. Talk about anything else (the drink itself, the city, the music, the marathon).`);
        if (trigger === "pace_drop" || trigger === "stationary") {
            lines.push("This EVENT fired because of that ordered break. Your line is NOT about his pace.");
        }
    }
}
