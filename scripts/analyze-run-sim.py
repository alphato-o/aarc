#!/usr/bin/env python3
"""
Harness A — P3 analyzer. Reads a whole-run feedback-sim transcript
(run-sim-<plan>.json from SimRunDriver) and renders a self-contained HTML
verdict: structural-repetition score, voice-balance curve, milestone coverage,
length distribution, and the full two-column transcript so repetition is
impossible to miss.

Usage: python3 scripts/analyze-run-sim.py <transcript.json> [out.html]
"""
import sys, json, re, html, math
from collections import Counter, defaultdict

# ---------- load ----------
src = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".html"
doc = json.load(open(src))
lines = doc["lines"]
plan = doc.get("plan", "?")
pace = doc.get("paceSecPerKm", 0)

TAG = re.compile(r"\[[^\]]*\]")
def strip_tags(t): return TAG.sub("", t).strip()
def words(t, n): return strip_tags(t).lower().split()[:n]

# opener "chunk": text up to the first dash/ellipsis, else first ~7 words.
SPLIT = re.compile(r"\s+[—–-]{1,2}\s+|\.\.\.|…")
def opener(t):
    s = strip_tags(t)
    m = SPLIT.search(s)
    head = s[:m.start()] if m else " ".join(s.split()[:7])
    return head.strip().lower()

def trigrams(t):
    w = strip_tags(t).lower().split()
    return set(tuple(w[i:i+3]) for i in range(max(0, len(w)-2)))

def jaccard(a, b):
    if not a or not b: return 0.0
    return len(a & b) / len(a | b)

# ---------- per-voice repetition ----------
def analyze_voice(vlines):
    n = len(vlines)
    if n == 0: return None
    texts = [l["text"] for l in vlines]
    # "<hook> — …" opener template: a dash/ellipsis break early in the line.
    def is_template(t):
        m = SPLIT.search(strip_tags(t))
        return bool(m) and m.start() <= 60
    dash_open = sum(1 for t in texts if is_template(t))
    # the worst-offender combo the founder flagged: hook-dash opener + "darling"
    template_darling = sum(1 for t in texts if is_template(t) and re.search(r"\bdarling\b", t, re.I))
    # repeated opening 2-grams
    first2 = [tuple(words(t, 2)) for t in texts]
    f2c = Counter(first2)
    repeated_first2 = sum(c for k, c in f2c.items() if c > 1 and k)
    # opener-chunk duplicates (same hook used twice)
    openers = [opener(t) for t in texts]
    oc = Counter(openers)
    dup_openers = {k: c for k, c in oc.items() if c > 1 and k}
    # lexical tics
    def rate(pat): return sum(1 for t in texts if re.search(pat, t, re.I))
    darling = rate(r"\bdarling\b")
    giggle = rate(r"\[(giggles|laughs)")
    god_open = sum(1 for t in texts if re.match(r"\s*(god|christ)\b", strip_tags(t), re.I))
    # near-duplicate pairs by trigram jaccard
    tg = [trigrams(t) for t in texts]
    sim_pairs = []
    for i in range(n):
        for j in range(i+1, n):
            s = jaccard(tg[i], tg[j])
            if s >= 0.5: sim_pairs.append((s, i, j))
    sim_pairs.sort(reverse=True)
    # repeated CONTENT phrases (same image reused across lines) — e.g.
    # "mouth pulling at my nipples". 4-grams appearing in >=2 distinct lines,
    # excluding all-stopword runs.
    STOP = set("the a an and to of in on at it my your you i me he his her she "
               "that this with for is are was be so but as your you're i'm".split())
    def ngrams(t, k):
        w = [re.sub(r"[^a-z0-9]", "", x) for x in strip_tags(t).lower().split()]
        w = [x for x in w if x]
        return set(" ".join(w[i:i+k]) for i in range(max(0, len(w)-k+1)))
    phrase_lines = defaultdict(set)
    for idx, t in enumerate(texts):
        for g in ngrams(t, 4):
            toks = g.split()
            if len(toks) == 4 and not all(x in STOP for x in toks):
                phrase_lines[g].add(idx)
    repeated_phrases = {g: len(s) for g, s in phrase_lines.items() if len(s) >= 2}
    # --- v3 audio-tag usage (are we getting our money's worth?) ---
    tagcounts = [len(TAG.findall(t)) for t in texts]
    tagged = sum(1 for c in tagcounts if c > 0)
    total_tags = sum(tagcounts)
    combo_lines = sum(1 for c in tagcounts if c >= 2)
    tagkinds = Counter()
    for t in texts:
        for m in TAG.findall(t):
            tagkinds[m.lower()] += 1
    # broken closing tags ([/...]) should NEVER appear (v3 has no closing tags)
    closing = sum(1 for t in texts for m in TAG.findall(t) if m.startswith("[/"))
    # score 0..100 (lower = better): weighted blend of the tells the founder
    # flagged. "darling" and the hook-dash opener template carry the most.
    score = min(100, round(
        35 * (dash_open / n) +
        25 * (darling / n) +
        15 * (repeated_first2 / n) +
        12 * (giggle / n) +
        18 * (len(sim_pairs) / max(1, n)) +
        30 * (len(repeated_phrases) / max(1, n))))   # repeated content/images
    return dict(n=n, dash_open=dash_open, template_darling=template_darling,
                repeated_first2=repeated_first2,
                dup_openers=dup_openers, darling=darling, giggle=giggle,
                god_open=god_open, sim_pairs=sim_pairs[:6], score=score,
                openers=openers, repeated_phrases=repeated_phrases,
                tagged=tagged, total_tags=total_tags, combo_lines=combo_lines,
                tagkinds=tagkinds, closing=closing)

ricky = [l for l in lines if l["voice"] == "ricky"]
jess  = [l for l in lines if l["voice"] == "jessica"]
RA = analyze_voice(ricky)
JA = analyze_voice(jess)

# ---------- balance curve (deciles by time) ----------
T = max((l["t"] for l in lines), default=1) or 1
BUCKETS = 10
bal = [[0, 0] for _ in range(BUCKETS)]
for l in lines:
    b = min(BUCKETS-1, int(l["t"] / T * BUCKETS))
    bal[b][0 if l["voice"] == "ricky" else 1] += 1

# ---------- milestone coverage ----------
plan_km = int(re.sub(r"\D", "", plan) or 0)
ms = [l for l in lines if l["milestone"]]
km_owner = {}
# Jessica milestones name their km in the source (jessica:milestone:N) — that's
# authoritative for who the director assigned. Scripted km lines fill the rest.
for l in ms:
    if "jessica:milestone:" in l["source"]:
        try: km_owner[int(l["source"].split(":")[-1])] = "jessica"
        except ValueError: pass
for l in ms:
    if "jessica:milestone:" not in l["source"]:
        km_owner.setdefault(max(1, l["km"]), "ricky")
covered = sorted(km_owner)

# ---------- length dist ----------
def length_dist(vlines):
    c = Counter(l["lengthMode"] for vlines_ in [vlines] for l in vlines_)
    return c
JL = Counter(l["lengthMode"] for l in jess)

# ---------- verdict ----------
def verdict(score):
    return ("PASS", "g") if score < 30 else ("WATCH", "a") if score < 55 else ("FAIL", "r")

# ---------- render ----------
def esc(t): return html.escape(t)
def hl_tags(t):
    return TAG.sub(lambda m: f'<span class="tag">{esc(m.group())}</span>', esc(t))

def balance_svg():
    w, h, pad = 760, 150, 24
    bw = (w - 2*pad) / BUCKETS
    bars = []
    for i,(r,j) in enumerate(bal):
        tot = r + j or 1
        x = pad + i*bw
        rh = (h-40) * (r/ max(1,max(rr+jj for rr,jj in bal)))
        jh = (h-40) * (j/ max(1,max(rr+jj for rr,jj in bal)))
        bars.append(f'<rect x="{x+4:.1f}" y="{h-20-rh:.1f}" width="{bw/2-4:.1f}" height="{rh:.1f}" fill="#7d97a8"/>')
        bars.append(f'<rect x="{x+bw/2:.1f}" y="{h-20-jh:.1f}" width="{bw/2-4:.1f}" height="{jh:.1f}" fill="#c98aa8"/>')
        bars.append(f'<text x="{x+bw/2:.1f}" y="{h-6}" font-size="9" fill="#8a978d" text-anchor="middle">{int(i*10)}%</text>')
    return f'<svg viewBox="0 0 {w} {h}" width="100%">{"".join(bars)}</svg>'

def km_strip():
    cells = []
    for km in range(1, max(plan_km, max(covered, default=0)) + 1):
        o = km_owner.get(km)
        col = "#7d97a8" if o == "ricky" else "#c98aa8" if o == "jessica" else "#3a3f3a"
        lab = "R" if o == "ricky" else "J" if o == "jessica" else "·"
        cells.append(f'<div class="kmcell" style="background:{col}" title="km {km}">{lab}<small>{km}</small></div>')
    return "".join(cells)

def voice_card(name, A, color):
    if not A: return ""
    v, vc = verdict(A["score"])
    dup = "".join(f'<li>“{esc(k)}” ×{c}</li>' for k,c in sorted(A["dup_openers"].items(), key=lambda x:-x[1]))
    sims = "".join(
        f'<li>{s:.0%} — “{esc(strip_tags(([l for l in lines if l["voice"]==name][i]["text"]))[:60])}…” ≈ “{esc(strip_tags(([l for l in lines if l["voice"]==name][j]["text"]))[:60])}…”</li>'
        for s,i,j in A["sim_pairs"])
    return f"""
    <div class="vcard">
      <h3>{name.title()} <span class="badge {vc}">{v} · repetition {A['score']}/100</span></h3>
      <table>
        <tr><td>lines</td><td>{A['n']}</td></tr>
        <tr><td>“&lt;hook&gt; —” opener template</td><td>{A['dash_open']}/{A['n']} ({A['dash_open']/A['n']:.0%})</td></tr>
        <tr><td>↳ template + “darling” (the worst combo)</td><td>{A['template_darling']}/{A['n']}</td></tr>
        <tr><td>repeated opening 2-words</td><td>{A['repeated_first2']}</td></tr>
        <tr><td>“darling”</td><td>{A['darling']}/{A['n']} ({A['darling']/A['n']:.0%})</td></tr>
        <tr><td>[giggles]/[laughs]</td><td>{A['giggle']}/{A['n']}</td></tr>
        <tr><td>“God/Christ…” opener</td><td>{A['god_open']}</td></tr>
        <tr><td>near-duplicate pairs (≥50% trigram)</td><td>{len(A['sim_pairs'])}</td></tr>
        <tr><td>repeated content phrases / images</td><td>{len(A['repeated_phrases'])}</td></tr>
        <tr><td><b>v3 tags — lines with a tag</b></td><td><b>{A['tagged']}/{A['n']} ({(A['tagged']/A['n']) if A['n'] else 0:.0%})</b></td></tr>
        <tr><td>total tags · combos (2+/line) · distinct</td><td>{A['total_tags']} · {A['combo_lines']} · {len(A['tagkinds'])}</td></tr>
        {('<tr><td style="color:#f0a097">⚠ BROKEN closing tags [/..]</td><td style="color:#f0a097">' + str(A['closing']) + ' (must be 0)</td></tr>') if A['closing'] else ''}
      </table>
      {('<p class="sub">Tags used:</p><ul class="rep">' + ''.join(f'<li>{esc(k)} ×{c}</li>' for k,c in A['tagkinds'].most_common(10)) + '</ul>') if A['tagkinds'] else '<p class="sub" style="color:#f0a097">No audio tags at all — flat v3 read, wasting the premium model.</p>'}
      {('<p class="sub">Reused images/phrases:</p><ul class="rep">' + ''.join(f'<li>“{esc(g)}” ×{c}</li>' for g,c in sorted(A['repeated_phrases'].items(), key=lambda x:-x[1])[:8]) + '</ul>') if A['repeated_phrases'] else ''}
      {f'<p class="sub">Reused openers:</p><ul class="rep">{dup}</ul>' if dup else ''}
      {f'<p class="sub">Most-similar pairs:</p><ul class="rep">{sims}</ul>' if sims else ''}
    </div>"""

def transcript():
    rows = []
    for l in sorted(lines, key=lambda x: x["t"]):
        mm, ss = int(l["t"]//60), int(l["t"]%60)
        side = "left" if l["voice"] == "ricky" else "right"
        col = "#7d97a8" if l["voice"]=="ricky" else "#c98aa8"
        chip = f'<span class="chip">{esc(l["lengthMode"])}</span>' if l["voice"]=="jessica" else ""
        mst = '<span class="chip ms">★ km'+str(l["km"])+'</span>' if l["milestone"] else ""
        rows.append(f"""
        <div class="trow {side}">
          <div class="bubble" style="border-color:{col}">
            <div class="meta">{mm}:{ss:02d} · <b style="color:{col}">{l['voice']}</b> · {esc(l['source'])} {chip}{mst}</div>
            <div class="txt">{hl_tags(l['text'])}</div>
          </div>
        </div>""")
    return "".join(rows)

jv, jvc = verdict(JA["score"]) if JA else ("—","g")
rv, rvc = verdict(RA["score"]) if RA else ("—","g")
ms_pct = len(covered)/plan_km if plan_km else 0
ms_v = "g" if ms_pct >= 0.9 else "a" if ms_pct >= 0.5 else "r"

HTML = f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<title>Run-sim verdict — {esc(plan)}</title><style>
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d100e;color:#e7efe9;margin:0;font-size:15px;line-height:1.5}}
.wrap{{max-width:980px;margin:0 auto;padding:32px 22px 80px}}
h1{{font-size:24px;margin:0 0 2px}} .muted{{color:#8a978d;font-size:13px}}
h2{{font-size:17px;margin:34px 0 10px;border-top:1px solid #232825;padding-top:14px}}
h3{{font-size:15px;margin:0 0 8px}}
.banner{{display:flex;gap:12px;flex-wrap:wrap;margin:18px 0}}
.tile{{flex:1;min-width:150px;background:#161a17;border:1px solid #242a26;border-radius:10px;padding:12px 14px}}
.tile .big{{font-size:22px;font-weight:800}}
.badge{{font-size:11px;font-weight:700;padding:2px 9px;border-radius:20px;vertical-align:middle}}
.g{{background:#173a26;color:#7fe0a6}} .a{{background:#3a3318;color:#e6c878}} .r{{background:#3a1d1a;color:#f0a097}}
table{{border-collapse:collapse;width:100%;font-size:13.5px;margin:6px 0}}
td{{border-bottom:1px solid #20251f;padding:4px 6px}} td:last-child{{text-align:right;color:#cfe0d4;font-variant-numeric:tabular-nums}}
.two{{display:grid;grid-template-columns:1fr 1fr;gap:16px}}
.vcard{{background:#13171400;border:1px solid #242a26;border-radius:10px;padding:14px 16px}}
.sub{{color:#8a978d;font-size:12px;margin:10px 0 2px}}
ul.rep{{margin:2px 0;padding-left:18px;font-size:12.5px;color:#d6c0a0}} ul.rep li{{margin:2px 0}}
.kmstrip{{display:flex;gap:4px;flex-wrap:wrap}}
.kmcell{{width:30px;height:34px;border-radius:6px;display:flex;flex-direction:column;align-items:center;justify-content:center;font-weight:800;color:#0d100e;font-size:13px}}
.kmcell small{{font-size:8px;opacity:.7}}
.legend{{font-size:12px;color:#8a978d;margin-top:6px}}
.trow{{display:flex;margin:6px 0}} .trow.right{{justify-content:flex-end}}
.bubble{{max-width:74%;background:#14181500;border:1px solid;border-left-width:3px;border-radius:8px;padding:8px 11px}}
.meta{{font-size:11px;color:#8a978d;margin-bottom:3px}}
.txt{{font-size:13.5px}}
.chip{{font-size:10px;background:#232825;color:#9fb0a3;padding:1px 6px;border-radius:10px;margin-left:4px}}
.chip.ms{{background:#2a2118;color:#e6c878}}
.tag{{color:#6f8a78;font-style:italic}}
@media(max-width:680px){{.two{{grid-template-columns:1fr}}.bubble{{max-width:88%}}}}
</style></head><body><div class="wrap">
<h1>Run-sim verdict — {esc(plan)}</h1>
<div class="muted">{len(lines)} lines · {len(ricky)} Ricky / {len(jess)} Jessica · pace {int(pace//60)}:{int(pace%60):02d}/km · content-mode preview (no TTS)</div>

<div class="banner">
  <div class="tile"><div class="muted">Jessica repetition</div><div class="big">{JA['score'] if JA else '—'}<span class="badge {jvc}">{jv}</span></div></div>
  <div class="tile"><div class="muted">Ricky repetition</div><div class="big">{RA['score'] if RA else '—'}<span class="badge {rvc}">{rv}</span></div></div>
  <div class="tile"><div class="muted">Milestone coverage</div><div class="big">{len(covered)}/{plan_km}<span class="badge {ms_v}">{'OK' if ms_v=='g' else 'GAPS' if ms_v=='a' else 'MISSING'}</span></div></div>
  <div class="tile"><div class="muted">Jessica lengths</div><div class="big" style="font-size:15px">{JL['quip']}q · {JL['medium']}m · {JL['indulgent']}i</div></div>
  <div class="tile"><div class="muted">v3 tags — Ricky / Jessica lines tagged</div><div class="big" style="font-size:17px">{(RA['tagged']/RA['n']) if RA and RA['n'] else 0:.0%} · {(JA['tagged']/JA['n']) if JA and JA['n'] else 0:.0%}<span class="badge {('r' if (RA and RA['closing'])or(JA and JA['closing']) else 'g' if (RA and RA['tagged']/max(1,RA['n'])>=0.35) else 'a')}">{'BROKEN' if (RA and RA['closing'])or(JA and JA['closing']) else 'OK' if (RA and RA['tagged']/max(1,RA['n'])>=0.35) else 'LOW'}</span></div></div>
</div>

<h2>Voice balance over the run <span class="muted">(grey = Ricky, pink = Jessica · should tilt to Jessica late)</span></h2>
{balance_svg()}

<h2>Milestone coverage <span class="muted">(R = Ricky owns the km, J = Jessica, · = none)</span></h2>
<div class="kmstrip">{km_strip()}</div>
<div class="legend">Jessica share of delivered milestones: {sum(1 for v in km_owner.values() if v=='jessica')}/{len(km_owner)}</div>

<h2>Structural repetition</h2>
<div class="two">{voice_card('jessica', JA, '#c98aa8')}{voice_card('ricky', RA, '#7d97a8')}</div>

<h2>Full transcript</h2>
{transcript()}
</div></body></html>"""

open(out, "w").write(HTML)
# console summary
print(f"plan={plan}  lines={len(lines)} (R {len(ricky)} / J {len(jess)})")
if JA: print(f"Jessica repetition {JA['score']}/100  dash-opener {JA['dash_open']}/{JA['n']}  darling {JA['darling']}  repeated-phrases {len(JA['repeated_phrases'])}  sim-pairs {len(JA['sim_pairs'])}")
if JA and JA['repeated_phrases']:
    print("  repeated images:", "; ".join(f"\"{g}\"×{c}" for g,c in sorted(JA['repeated_phrases'].items(), key=lambda x:-x[1])[:6]))
if RA: print(f"Ricky   repetition {RA['score']}/100  dash-opener {RA['dash_open']}/{RA['n']}  dup-openers {len(RA['dup_openers'])}  sim-pairs {len(RA['sim_pairs'])}")
print(f"milestones {len(covered)}/{plan_km} covered; Jessica owns {sum(1 for v in km_owner.values() if v=='jessica')}/{len(km_owner)}")
if RA: print(f"Ricky   tags: {RA['tagged']}/{RA['n']} lines tagged · {RA['total_tags']} tags · {RA['combo_lines']} combos · closing(bad)={RA['closing']}")
if JA: print(f"Jessica tags: {JA['tagged']}/{JA['n']} lines tagged · {JA['total_tags']} tags · {JA['combo_lines']} combos · closing(bad)={JA['closing']}")
print(f"→ {out}")
