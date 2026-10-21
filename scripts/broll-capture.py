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
  console   kind, text                            the agent's terminal during the run
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
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")

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
