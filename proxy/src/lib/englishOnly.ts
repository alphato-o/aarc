/// Last pass over every spoken line before it leaves the proxy (founder,
/// 2026-10-22, run CF3B6CD8). The race is cut for an English YouTube audience,
/// so a voiced line carries no Chinese characters: "near 建国门", "五-forty-six"
/// and "while 东大桥路小区 watches on" all went out to ElevenLabs that day.
/// This reverses the 2026-10-17 choice to let the voices read zh names natively.
/// The prompts ask for English or pinyin; this guard makes it true when they don't.

import { REAL_NAME_RE } from "./personalities";

const SCRIPTS = "\\p{Script=Han}\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Hangul}";
const HAS_CJK = new RegExp(`[${SCRIPTS}]`, "u");
/// A "word" with CJK in it, Latin glued on either side included: "CBD历史文化公园", "光华路7号", "he懂三千种桑巴".
const CJK_WORD = `[A-Za-z0-9]*[${SCRIPTS}][${SCRIPTS}A-Za-z0-9·・]*`;
const CJK_WORDS = `${CJK_WORD}(?:\\s+${CJK_WORD})*`;

const FULLWIDTH: Record<string, string> = {
    "，": ", ", "。": ". ", "！": "! ", "？": "? ", "：": ": ", "；": "; ", "、": ", ",
    "（": " (", "）": ") ", "“": "\"", "”": "\"", "‘": "'", "’": "'", "《": "", "》": "", "「": "", "」": "",
};
const NUMERALS: Record<string, string> = {
    "〇": "zero", "零": "zero", "一": "one", "二": "two", "两": "two", "三": "three", "四": "four",
    "五": "five", "六": "six", "七": "seven", "八": "eight", "九": "nine", "十": "ten",
};
const PREPOSITIONS = "near|past|at|by|on|along|around|round|into|through|towards?|from|outside|behind|beside|in|under|over|off|onto|across";

export function hasCJK(text: string): boolean {
    return HAS_CJK.test(text);
}

/// Strip or rewrite every CJK fragment so the line reads as plain English.
/// Order matters: keep an English gloss when the model gave one, drop quoted
/// lyric fragments whole, drop "near <place>" phrases, and only then fall
/// back to "this stretch" so the sentence still parses.
export function englishOnly(text: string): string {
    let s = text.replace(/[，。！？：；、（）“”‘’《》「」]/g, (c) => FULLWIDTH[c] ?? "");
    if (!HAS_CJK.test(s)) return s === text ? text : tidy(s);

    // "五-forty-six": a lone numeral glued to an English number.
    s = s.replace(/[〇零一二两三四五六七八九十](?=-[a-z])/giu, (c) => NUMERALS[c] ?? c);
    s = s.replace(/(?<=[a-z]-)[〇零一二两三四五六七八九十]/giu, (c) => NUMERALS[c] ?? c);

    // A quoted fragment that contains CJK (a lyric): drop the whole quote.
    for (const [o, c] of [["'", "'"], ["\"", "\""]] as const) {
        const re = new RegExp(`(^|[\\s(\\[\\]])${o}[^${o}\\n]*?[${SCRIPTS}][^${o}\\n]*?${c}(?=$|[\\s,.;:!?)\\-])`, "gu");
        s = s.replace(re, "$1");
    }

    // "景华街, Jinghua Street" / "呼家楼, the district..." keep the English.
    s = s.replace(new RegExp(`${CJK_WORDS},\\s*(?=(?:the|a|an)\\s|[A-Z])(?!(?:Alpha|Ricky|Jessica|Home Base)\\b)`, "gu"), "");
    // "景华街 (Jinghua Street)" keeps the English; "Jinghua Street (景华街)" drops the Chinese.
    s = s.replace(new RegExp(`${CJK_WORDS}\\s*\\(([^)]*[A-Za-z][^)]*)\\)`, "gu"), "$1");
    s = s.replace(new RegExp(`\\s*\\(\\s*${CJK_WORDS}\\s*\\)`, "gu"), "");
    // "呼家楼 district" with the English already given elsewhere: the noun alone says nothing.
    s = s.replace(new RegExp(`${CJK_WORDS}\\s+(?:district|area|neighbourhood|road|street|park)\\b`, "giu"), "");
    // "near 建国门" says nothing an English listener can use: drop the phrase.
    s = s.replace(new RegExp(`\\b(?:${PREPOSITIONS})\\s+(?:the\\s+)?${CJK_WORDS}`, "giu"), "");
    // Anything left is a bare name in the middle of a sentence.
    s = s.replace(new RegExp(CJK_WORDS, "gu"), "this stretch");
    s = s.replace(new RegExp(`[${SCRIPTS}]`, "gu"), "");
    return tidy(s).replace(/(^|(?<!\.)[.!?]\s+)([a-z])/g, (_m, a: string, b: string) => a + b.toUpperCase());
}

/// Ricky is a British bloke (and Jessica is posh British). Lyrics with
/// "goddamn" in them taught him to say it in his own voice (run CF3B6CD8,
/// twice in one line); this keeps the register British when the model slips.
export function britishRegister(text: string): string {
    const swaps: [RegExp, string][] = [
        [/\bgod\s*-?\s*dam(?:n\s*-?\s*it|mit)\b/gi, "bloody hell"],
        [/\bgod\s*-?\s*damn(?:ed)?\b/gi, "bloody"],
        [/\bgoddam\b/gi, "bloody"],
        [/\bfreaking\b|\bfrickin'?|\bfriggin'?/gi, "bloody"],
        [/\bassholes\b/gi, "arseholes"],
        [/\basshole\b/gi, "arsehole"],
        [/\bjackass\b/gi, "pillock"],
        [/\bdumbass\b/gi, "pillock"],
        [/\bass\b/gi, "arse"],
        [/\b(?:dude|buddy|bro)\b/gi, "mate"],
        [/\bmom\b/gi, "mum"],
        [/\bgotten\b/gi, "got"],
    ];
    let s = text;
    for (const [re, to] of swaps) s = s.replace(re, (m) => matchCase(m, to));
    return s;
}

/// His name is Alpha (or "Alpha T"). His real given name entered from our own
/// persona prompt and lived on in liked lines and the recent-lines window; the
/// race video is public, so it is rewritten on the way in and on the way out.
/// The pattern lives in the gitignored personalities.ts: this repo is public.
export function runnerName(text: string): string {
    return text.replace(REAL_NAME_RE, "Alpha");
}

/// The single exit for coach and Home Base text.
export function finalizeSpoken(text: string, voice: "ricky" | "jessica" | "home"): string {
    // Alpha bans the em and en dash everywhere, the B-roll text included;
    // "--" keeps the short clip DELIVERY_CRAFT asks for.
    let s = runnerName(text).replace(/\s*[\u2014\u2013]\s*/g, " -- ");
    s = englishOnly(s);
    if (voice !== "home") s = britishRegister(s);
    return s;
}

function matchCase(src: string, to: string): string {
    return src[0] && src[0] === src[0].toUpperCase() && src[0] !== src[0].toLowerCase()
        ? to[0]!.toUpperCase() + to.slice(1)
        : to;
}

function tidy(s: string): string {
    let t = s
        .replace(/[ \t]{2,}/g, " ")
        .replace(/\s+([,.;:!?])/g, "$1")
        .replace(/([,;:])(?:\s*[,;:])+/g, "$1")
        .replace(/,\s*([.!?])/g, "$1")
        .replace(/\(\s*\)/g, "")
        .replace(/''|""/g, "")
        .replace(/[ \t]{2,}/g, " ");
    // A dropped lead-in quote leaves "[scoffs] -- three thousand..."; drop the orphan separator.
    t = t.replace(/^((?:\s*\[[^\]]*\])*\s*)(?:--|-|,|:|;)\s*/, "$1");
    return t.trim();
}
