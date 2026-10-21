#!/usr/bin/env python3
"""Freeze everything a race run's Control Room B-roll is rebuilt from.

    scripts/broll-capture.py <runId> [--out ~/aarc-broll] [--no-audio]

Writes <out>/<runId>/:
  manifest.json    format, run window (start, gate, end), counts, sources
  timeline.jsonl   one record per moment, sorted by wall clock (UTC ms)
  audio/           every voice line's MP3 and his talk-back clips, as heard

Timeline lanes (format aarc-broll/1):
  pos       lat, lon, hr, kmh                     the dot on the map
  metrics   distanceM, paceS, hr, speed           the numbers on screen
  voice     speaker, text, audio, durationS       a line as it started playing
  talkback  text, audio, durationS                his voice to Control Room
  screen    role, source, text                    a message on the Control Room thread
  console   kind, text                            the agent's terminal during the run (short form)
  terminal  kind, text, + per kind fields          the agent's Claude Code session, block by block:
            user (typed prompt), assistant (text), tool (name, description, input),
            result (text, lines, isError), harness (label, text), thinking (durationS)
  event     type, detail                          camera, gate, km, network, the rest

Every record has `ms` (epoch milliseconds, UTC) and `t` (seconds since the
run started; null where only a wall clock exists). A video renderer replays
the lanes against `ms`; the A-roll is aligned on the voice lines, which are
audible on both.
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROXY = ROOT / "proxy"
SESSIONS = Path.home() / ".claude/projects/-Users-fydeos-Dev-ccplayground-aarc"
SPEAKERS = {
    "lKMAeQD7Brvj7QCWByqK": "ricky",
    "qXT8GHnNNyIOcyf6WrH9": "jessica",
    "Awx8TeMHHpDzbm42nIB6": "home",
    "local": "phone",
}


def d1(sql):
    out = subprocess.run(
        ["npx", "wrangler", "d1", "execute", "aarc-runs", "--remote", "--json", "--command", sql],
        cwd=PROXY, capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]["results"]


def d1_all(sql, page=2000):
    rows, offset = [], 0
    while True:
        batch = d1(f"{sql} LIMIT {page} OFFSET {offset}")
        rows += batch
        if len(batch) < page:
            return rows
        offset += page


def r2_get(key, dest):
    if dest.exists() and dest.stat().st_size > 0:
        return True
    r = subprocess.run(
        ["npx", "wrangler", "r2", "object", "get", f"aarc-voices/{key}", "--remote", "--file", str(dest)],
        cwd=PROXY, capture_output=True, text=True)
    return r.returncode == 0 and dest.exists() and dest.stat().st_size > 0


def duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                       capture_output=True, text=True)
    try:
        return round(float(r.stdout.strip()), 3)
    except ValueError:
        return None


def ms_of(iso):
    iso = iso.replace(" ", "T")
    if not iso.endswith("Z") and "+" not in iso[10:]:
        iso += "Z"
    return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)


def iso_of(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def console_lines(start_ms, end_ms):
    """The agent's visible output while the run was live: text and tool calls."""
    out = []
    for f in SESSIONS.glob("*.jsonl"):
        if f.stat().st_mtime * 1000 < start_ms:
            continue
        with f.open() as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = d.get("timestamp")
                if d.get("type") != "assistant" or not ts or d.get("isSidechain"):
                    continue
                ms = ms_of(ts)
                if not (start_ms <= ms <= end_ms):
                    continue
                for block in (d.get("message") or {}).get("content") or []:
                    if block.get("type") == "text" and block.get("text", "").strip():
                        out.append({"ms": ms, "lane": "console", "kind": "text", "text": block["text"].strip()})
                    elif block.get("type") == "tool_use":
                        inp = block.get("input") or {}
                        label = inp.get("description") or inp.get("command") or inp.get("file_path") or ""
                        out.append({"ms": ms, "lane": "console", "kind": "tool",
                                    "text": f"{block.get('name')}: {str(label)[:200]}"})
    return out


REDACTED = "\u2039redacted\u203a"
_HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_SECRETS = [
    re.compile(r"\bsk-or-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"\bsk-[A-Za-z0-9_\-]{12,}"),
    re.compile(r"\bsk_[A-Za-z0-9_\-]{12,}"),
    re.compile(r"\bcnc-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"\bxi-[A-Za-z0-9_\-]{12,}"),
    re.compile(r"\b(?:ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{12,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_\-]{30,}"),
    re.compile(r"\beyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}"),
]
_BEARER = re.compile(r"(?i)\b(Bearer|Basic|Token)(\s+)([A-Za-z0-9._~+/=\-]{8,})")
_ASSIGN = re.compile(
    r"(?i)([A-Za-z0-9_\-]*(?:token|key|secret|passw(?:or)?d|credential|auth)[A-Za-z0-9_\-]*)"
    r"(\"?'?\s*[=:]\s*[\"']?)([^\s\"',;}{)(\]\[]{6,})")
_LONG = re.compile(r"[A-Za-z0-9+_\-]{32,}={0,2}")


def _long_secret(m):
    v = m.group(0)
    if _HEX64.match(v) or re.fullmatch(r"[0-9a-fA-F\-]+", v):
        return v
    if not (re.search(r"[a-z]", v) and re.search(r"[A-Z]", v) and re.search(r"[0-9]", v)):
        return v
    if "_" in v and re.fullmatch(r"[A-Za-z0-9]+(_[A-Za-z0-9]+)+", v) and not re.search(r"[A-Za-z0-9]{24,}", v):
        return v                 # snake_case identifiers
    return REDACTED


def _assign(m):
    value = m.group(3)
    if _HEX64.match(value) or _UUID.match(value) or value.startswith(("$", "/", "~", "./", "<", "\u2039")):
        return m.group(0)
    if value.isdigit() or value.lower() in ("true", "false", "null", "none", "undefined", "string", "number"):
        return m.group(0)
    return m.group(1) + m.group(2) + REDACTED


def redact(text):
    """Strip anything credential-shaped; the video goes public, so this errs wide."""
    if not text:
        return text
    for pat in _SECRETS:
        text = pat.sub(REDACTED, text)
    text = _BEARER.sub(lambda m: m.group(1) + m.group(2) + REDACTED, text)
    text = _ASSIGN.sub(_assign, text)
    return _LONG.sub(_long_secret, text)


def redact_record(rec):
    for k, v in list(rec.items()):
        if isinstance(v, str) and k not in ("ts", "audio", "lane", "kind"):
            rec[k] = redact(v)
    return rec


REMINDER = re.compile(r"<system-reminder>(.*?)</system-reminder>", re.S)
SKIP_ATTACH = {"deferred_tools_record", "deferred_tools_delta", "credential_org", "prompt_snapshot",
               "hook_success", "batching_reminder_sent", "agent_listing_delta", "mcp_instructions_delta",
               "skill_listing", "session_context", "compact_file_reference", "plan_file_reference"}
ATTACH_LABEL = {
    "total_tokens_reminder": "token budget",
    "environment": "environment changed",
    "date_change": "date changed",
    "date": "date",
    "instructions": "instruction files re-read",
    "edited_text_file": "file changed on disk",
    "file": "file attached",
    "task_reminder": "task list reminder",
    "task_status": "task status",
    "diagnostics": "diagnostics",
    "bash_output_audience_note": "output audience note",
    "invoked_skills": "skills invoked",
    "model": "model",
    "auto_mode": "auto mode",
    "elapsed_time_reminder": "elapsed time",
}


def reminder_label(body):
    """One collapsed line for a system-reminder: what it is, never its body."""
    b = body.strip()
    if "SYSTEM NOTIFICATION" in b:
        return "[SYSTEM NOTIFICATION \u00b7 NOT USER INPUT] background-task event"
    if "hasn't heard from you" in b:
        return "The user hasn't heard from you in a while: say what you're doing, then continue."
    if "Contents of" in b and ("CLAUDE.md" in b or "AGENTS.md" in b or "MEMORY.md" in b):
        return "system-reminder \u00b7 instruction files re-read"
    m = re.search(r"<total_tokens>([^<]*)</total_tokens>", b)
    if m:
        return "system-reminder \u00b7 " + m.group(1).strip()
    if "changed on disk" in b or "was modified" in b:
        return "system-reminder \u00b7 file changed on disk"
    if b.startswith("# Environment") or "invoked in the following environment" in b:
        return "system-reminder \u00b7 environment"
    if "memory is" in b and "days old" in b:
        return "system-reminder \u00b7 memory age note"
    first = b.splitlines()[0][:80] if b else ""
    return "system-reminder \u00b7 " + (first or "note")


def _text_of(content):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text", ""))
        elif isinstance(b, dict) and b.get("type") == "image":
            out.append("[image]")
    return "\n".join(out)


def _tool_input(name, inp):
    if not isinstance(inp, dict):
        return str(inp)
    if name == "Bash":
        return inp.get("command", "")
    if name in ("Read", "NotebookRead"):
        extra = "".join(f" {k}={inp[k]}" for k in ("offset", "limit", "pages") if inp.get(k))
        return inp.get("file_path", "") + extra
    if name == "Edit":
        return f"{inp.get('file_path', '')}\n- {inp.get('old_string', '')}\n+ {inp.get('new_string', '')}"
    if name == "Write":
        return f"{inp.get('file_path', '')}\n{inp.get('content', '')}"
    if name == "SendMessage":
        return f"to {inp.get('to') or inp.get('recipient') or ''}: {inp.get('message') or inp.get('content') or ''}"
    keep = {k: v for k, v in inp.items() if k != "description"}
    return json.dumps(keep, ensure_ascii=False)


def _tool_desc(name, inp):
    if not isinstance(inp, dict):
        return ""
    for k in ("description", "file_path", "pattern", "url", "query", "skill", "action", "to"):
        if inp.get(k):
            return str(inp[k])
    return ""


def _clip(text, max_lines=40, max_chars=4000):
    lines = text.splitlines()
    total = len(lines)
    text = "\n".join(lines[:max_lines])
    if len(text) > max_chars:
        text = text[:max_chars]
    return text, total


def terminal_lines(start_ms, end_ms):
    """The agent's Claude Code session during the run, as the terminal showed it."""
    out = []
    files = [f for f in SESSIONS.glob("*.jsonl") if f.stat().st_mtime * 1000 >= start_ms]
    for f in files:
        recs = []
        with f.open() as fh:
            for line in fh:
                if '"timestamp"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = d.get("timestamp")
                if not ts or d.get("isSidechain"):
                    continue
                ms = ms_of(ts)
                if start_ms <= ms <= end_ms and d.get("type") in ("user", "assistant", "attachment"):
                    recs.append((ms, d))
        recs.sort(key=lambda r: r[0])
        prev_ms = None
        pending_think = None
        for ms, d in recs:
            typ = d["type"]
            if typ == "attachment":
                a = d.get("attachment") or {}
                kind = a.get("type")
                rendered = "".join(r.get("content", "") for r in d.get("rendered") or [] if isinstance(r, dict))
                if kind in SKIP_ATTACH or "<system-reminder>" not in rendered:
                    continue
                if kind == "queued_command":
                    if "SYSTEM NOTIFICATION" in rendered:
                        out.append({"ms": ms, "lane": "terminal", "kind": "harness", "label": "system",
                                    "text": "[SYSTEM NOTIFICATION \u00b7 NOT USER INPUT] background-task event"})
                    continue
                if kind == "silent_turn_reminder":
                    label = reminder_label(a.get("text", "hasn't heard from you"))
                else:
                    label = (("system-reminder \u00b7 " + ATTACH_LABEL[kind]) if kind in ATTACH_LABEL
                             and kind != "total_tokens_reminder" else reminder_label(REMINDER.sub(lambda m: m.group(1), rendered)))
                out.append({"ms": ms, "lane": "terminal", "kind": "harness", "label": kind, "text": label})
                continue
            content = (d.get("message") or {}).get("content")
            if typ == "user":
                if isinstance(content, str) or (isinstance(content, list) and all(
                        isinstance(b, dict) and b.get("type") == "text" for b in content)):
                    text = _text_of(content)
                    if "<task-notification>" in text:
                        g = lambda tag: (re.search(f"<{tag}>(.*?)</{tag}>", text, re.S) or [None, ""])[1].strip()
                        out.append({"ms": ms, "lane": "terminal", "kind": "harness", "label": "task-notification",
                                    "text": f"[task-notification \u00b7 {g('task-id')} \u00b7 {g('status')}] {g('summary')}"})
                    else:
                        for body in REMINDER.findall(text):
                            out.append({"ms": ms, "lane": "terminal", "kind": "harness", "label": "system-reminder",
                                        "text": reminder_label(body)})
                        typed = REMINDER.sub("", text).strip()
                        if typed and not d.get("isMeta") and not typed.startswith("<"):
                            out.append({"ms": ms, "lane": "terminal", "kind": "user", "text": typed})
                    prev_ms = ms
                    continue
                for b in content or []:
                    if not isinstance(b, dict) or b.get("type") != "tool_result":
                        continue
                    raw = _text_of(b.get("content"))
                    for body in REMINDER.findall(raw):
                        out.append({"ms": ms, "lane": "terminal", "kind": "harness", "label": "system-reminder",
                                    "text": reminder_label(body)})
                    raw = REMINDER.sub("", raw).strip()
                    if raw.startswith("Command running in background with ID"):
                        tid = (re.search(r"ID: (\w+)", raw) or [None, "?"])[1]
                        out.append({"ms": ms, "lane": "terminal", "kind": "harness", "label": "background",
                                    "text": f"[background task {tid} started \u00b7 you will be notified when it completes]"})
                        continue
                    text, total = _clip(raw)
                    out.append({"ms": ms, "lane": "terminal", "kind": "result", "text": text, "lines": total,
                                "isError": bool(b.get("is_error"))})
                prev_ms = ms
                continue
            # assistant
            for b in content or []:
                bt = b.get("type") if isinstance(b, dict) else None
                if bt == "thinking":
                    pending_think = prev_ms if prev_ms is not None else ms
                    continue
                if pending_think is not None and bt in ("text", "tool_use"):
                    out.append({"ms": pending_think, "lane": "terminal", "kind": "thinking",
                                "durationS": round(max(0.5, (ms - pending_think) / 1000), 1)})
                    pending_think = None
                if bt == "text" and b.get("text", "").strip():
                    out.append({"ms": ms, "lane": "terminal", "kind": "assistant", "text": b["text"].strip()})
                elif bt == "tool_use":
                    name = b.get("name") or "Tool"
                    inp = b.get("input") or {}
                    text, _ = _clip(_tool_input(name, inp), 40, 4000)
                    out.append({"ms": ms, "lane": "terminal", "kind": "tool", "name": name,
                                "description": _tool_desc(name, inp)[:300], "text": text})
            prev_ms = ms
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id")
    ap.add_argument("--out", default=str(Path.home() / "aarc-broll"))
    ap.add_argument("--no-audio", action="store_true")
    args = ap.parse_args()
    run = args.run_id.upper()
    out = Path(args.out).expanduser() / run
    audio_dir = out / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    events = d1_all(f"SELECT t, wall, type, detail, data FROM run_events WHERE run_id='{run}' ORDER BY t")
    if not events:
        sys.exit(f"no run_events for {run}: has the run log uploaded?")
    live = d1(f"SELECT started_at, ended_at, course FROM live_run WHERE run_id='{run}'")
    thread = d1(f"SELECT id, role, source, text, created_at, meta FROM agent_thread WHERE run_id='{run}' ORDER BY id")
    notes = d1(f"SELECT note_id, created_at, audio_key, duration_s, clean_text, raw_text FROM voice_note WHERE run_id='{run}'")

    start_ms = ms_of(events[0]["wall"]) - int(float(events[0]["t"] or 0) * 1000)
    end_ms = max(ms_of(e["wall"]) for e in events if e["wall"])
    timeline, fetch = [], []
    gate_ms = None
    seen = set()

    for e in events:
        if not e["wall"]:
            continue
        key = (e["t"], e["type"], e["detail"])
        if key in seen:          # the log can carry a line twice after a relaunch
            continue
        seen.add(key)
        ms, t = ms_of(e["wall"]), num(e["t"])
        data = json.loads(e["data"]) if e["data"] else {}
        typ = e["type"]
        if typ == "gps":
            timeline.append({"ms": ms, "t": t, "lane": "pos", "lat": num(data.get("lat")), "lon": num(data.get("lon")),
                             "hr": num(data.get("hr")), "kmh": num(data.get("kmh"))})
        elif typ == "metrics":
            timeline.append({"ms": ms, "t": t, "lane": "metrics", "distanceM": num(data.get("d")),
                             "paceS": num(data.get("p")), "hr": num(data.get("hr")), "speed": num(data.get("v"))})
        elif typ == "speech":
            voice = data.get("voiceId") or "local"
            ck = data.get("cacheKey") or ""
            rec = {"ms": ms, "t": t, "lane": "voice", "speaker": SPEAKERS.get(voice, voice), "voiceId": voice,
                   "text": e["detail"], "source": data.get("source"), "audio": None, "durationS": None}
            if ck:
                rec["audio"] = f"audio/{ck}.mp3"
                fetch.append((f"{run}/{ck}.mp3", audio_dir / f"{ck}.mp3"))
            timeline.append(rec)
        elif typ in ("voice.play", "tts.play", "net.req"):
            continue             # superseded by `speech`, or network noise
        else:
            if typ == "race.gate" and gate_ms is None:   # the first press is the real one
                gate_ms = ms
            timeline.append({"ms": ms, "t": t, "lane": "event", "type": typ, "detail": e["detail"]})

    for m in thread:
        meta = json.loads(m["meta"]) if m["meta"] else {}
        ms = ms_of(meta["startedAt"]) if m["role"] == "user" and meta.get("startedAt") else ms_of(m["created_at"])
        if m["role"] == "user" and m["source"] == "voice":
            rec = {"ms": ms, "t": None, "lane": "talkback", "text": m["text"], "audio": None,
                   "durationS": meta.get("duration")}
            if meta.get("clientId"):
                rec["audio"] = f"audio/talkback-{meta['clientId']}.m4a"
                fetch.append((f"talkback/{meta['clientId']}.m4a", audio_dir / f"talkback-{meta['clientId']}.m4a"))
            timeline.append(rec)
        timeline.append({"ms": ms_of(m["created_at"]), "t": None, "lane": "screen", "role": m["role"],
                         "source": m["source"], "text": m["text"]})

    timeline += console_lines(start_ms, end_ms)
    timeline += terminal_lines(start_ms, end_ms)

    fetched = 0
    if not args.no_audio and fetch:
        with cf.ThreadPoolExecutor(6) as pool:
            ok = dict(zip([f[1] for f in fetch], pool.map(lambda f: r2_get(*f), fetch)))
        fetched = sum(ok.values())
    for rec in timeline:
        if rec.get("audio"):
            p = out / rec["audio"]
            if p.exists():
                rec["durationS"] = rec.get("durationS") or duration(p)
            else:
                rec["audio"] = None
        if rec.get("t") is None:
            rec["t"] = round((rec["ms"] - start_ms) / 1000, 3)
        rec["ts"] = iso_of(rec["ms"])

    timeline.sort(key=lambda r: (r["ms"], r["lane"]))
    with (out / "timeline.jsonl").open("w") as fh:
        for rec in timeline:
            fh.write(json.dumps(redact_record(rec), ensure_ascii=False) + "\n")

    counts = {}
    for rec in timeline:
        counts[rec["lane"]] = counts.get(rec["lane"], 0) + 1
    manifest = {
        "format": "aarc-broll/1",
        "runId": run,
        "course": (live[0]["course"] if live else None),
        "startedAt": iso_of(start_ms),
        "gateAt": iso_of(gate_ms) if gate_ms else None,
        "endedAt": iso_of(end_ms),
        "durationS": round((end_ms - start_ms) / 1000, 1),
        "counts": counts,
        "audioFiles": {"wanted": len(fetch), "fetched": fetched},
        "voiceNotesAfter": [{"noteId": n["note_id"], "at": n["created_at"], "audioKey": n["audio_key"],
                             "durationS": n["duration_s"], "text": n["clean_text"] or n["raw_text"]} for n in notes],
        "sources": ["D1 run_events", "D1 agent_thread", "D1 voice_note", "R2 aarc-voices", "agent session transcript"],
        "capturedAt": iso_of(int(datetime.now(timezone.utc).timestamp() * 1000)),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
    print(f"{out}: {len(timeline)} records {counts}, audio {fetched}/{len(fetch)}")


if __name__ == "__main__":
    main()
