/// Dashboard app shell for GET /dash with a valid session cookie.
/// Self-contained: inline CSS, inline vanilla JS + SVG, zero CDN deps.
///
/// CHARTS-FIRST rewrite. Primary purpose = review PERFORMANCE; reliving
/// audio is secondary but must actually work (the old build's speech click
/// was dead). Layout:
///   - left rail: runs list (date, duration, distance, event count)
///   - main HERO: dual-series performance chart from "metrics" events
///       (wide translucent SPEED area + narrow solid HR line, HR pinned to
///        a 200bpm right axis, speed auto-scaled left axis, outlier-resistant)
///   - event markers on the SAME zoomable/pannable time (or distance) axis
///   - audio player (single reusable HTMLAudioElement, same-origin src)
///   - telemetry log: filterable scrollable table of ALL events
///   - right detail panel: selected event raw JSON + play
///
/// Data contract (sibling data-API agent, ingestRun.ts):
///   GET /api/runs                 -> [{run_id, started_at, event_count, meta}]
///   GET /api/runs/:id/events      -> [{t, wall, type, detail, data}]
///   GET /api/runs/:id/audio/:key  -> mp3 | 404 (not archived) | 503 (R2 off)
///
/// "metrics" event (shared contract): t = seconds since run start.
///   data = {d:distM, p:paceSecPerKm(""?), hr:bpm(""?), v:speedMps(""?)}
///   all values are STRINGS, any may be empty. Backfilled for old runs, so a
///   run may carry only HR or only pace — render sparse data gracefully.
///
/// speech event (verified against iOS RunEventLog/RemoteTTS):
///   data = {voiceId, source:"cache"|"fetch", cacheKey}; voiceId picks the
///   colour (jessica vs ricky). cacheKey is the audio URL segment.
///
/// NOTE for editors: the embedded JS deliberately avoids backticks and the
/// dollar-brace sequence so it can live inside this TS template literal
/// unescaped. Keep it that way (use string concatenation in the JS).
export const APP_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>AARC dash</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0b0e13; --panel: #11151c; --panel2: #0e1116; --line: #21262d;
    --line2: #1b212a; --text: #c9d1d9; --textHi: #e6edf3; --textDim: #8b949e;
    --textFaint: #545d68;
    --speed: #58a6ff; --hr: #f85149; --ricky: #e8a13a; --jessica: #ef6da8;
    --green: #3fb950; --amber: #d29922; --select: #58a6ff;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body {
    font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); overflow: hidden;
  }
  header {
    height: 44px; display: flex; align-items: center; gap: 12px;
    padding: 0 14px; background: var(--panel); border-bottom: 1px solid var(--line);
  }
  header h1 { font-size: 14px; font-weight: 700; color: var(--textHi); letter-spacing: .02em; }
  header .runlabel { color: var(--textDim); font-size: 12px; }
  header .spacer { flex: 1; }
  header .hint { color: var(--textFaint); font-size: 11px; }
  .xtoggle {
    display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden;
  }
  .xtoggle button {
    background: var(--panel2); color: var(--textDim); border: 0; padding: 5px 10px;
    font: 600 11px/1 inherit; cursor: pointer;
  }
  .xtoggle button.on { background: #1c2632; color: var(--textHi); }
  .xtoggle button + button { border-left: 1px solid var(--line); }

  #layout { display: flex; height: calc(100% - 44px); }

  /* left rail: runs */
  #runs {
    width: 236px; min-width: 236px; overflow-y: auto;
    background: var(--panel); border-right: 1px solid var(--line);
  }
  .run-row { padding: 9px 12px; border-bottom: 1px solid var(--line2); cursor: pointer; }
  .run-row:hover { background: #161d27; }
  .run-row.active { background: #1c2632; box-shadow: inset 3px 0 0 var(--select); }
  .run-row .date { color: var(--textHi); font-weight: 600; font-size: 12px; }
  .run-row .sub { color: var(--textDim); font-size: 11px; margin-top: 3px;
    display: flex; gap: 8px; flex-wrap: wrap; }
  .run-row .sub b { color: #adbac7; font-weight: 600; }
  #runs .empty { padding: 16px 12px; color: var(--textDim); font-size: 12px; }

  /* center column */
  #center { flex: 1; display: flex; flex-direction: column; min-width: 0; }

  /* hero chart + markers */
  #chartwrap { position: relative; border-bottom: 1px solid var(--line); background: var(--panel2); }
  #chart { display: block; width: 100%; cursor: grab; touch-action: none; }
  #chart.panning { cursor: grabbing; }
  #chartempty {
    position: absolute; inset: 0; display: flex; align-items: center;
    justify-content: center; color: var(--textFaint); font-size: 13px; pointer-events: none;
  }
  .legend {
    position: absolute; top: 8px; right: 12px; display: flex; gap: 14px;
    font-size: 11px; color: var(--textDim); pointer-events: none;
  }
  .legend span { display: inline-flex; align-items: center; gap: 5px; }
  .legend i { width: 11px; height: 11px; border-radius: 2px; display: inline-block; }

  /* audio player bar */
  #player {
    display: flex; align-items: center; gap: 10px; padding: 8px 12px;
    background: var(--panel); border-bottom: 1px solid var(--line); min-height: 46px;
  }
  #pbtn {
    width: 30px; height: 30px; flex: 0 0 30px; border-radius: 50%; border: 0;
    background: var(--green); color: #08130b; font-size: 13px; cursor: pointer;
    display: inline-flex; align-items: center; justify-content: center;
  }
  #pbtn:hover { filter: brightness(1.1); }
  #pbtn:disabled { background: #30363d; color: #6e7681; cursor: default; }
  #pmeta { min-width: 0; flex: 1; }
  #ptext { color: var(--textHi); font-size: 12px; white-space: nowrap; overflow: hidden;
    text-overflow: ellipsis; }
  #psub { color: var(--textDim); font-size: 11px; margin-top: 1px; }
  #psub .voicechip { display: inline-block; padding: 0 6px; border-radius: 8px;
    font-size: 10px; font-weight: 700; color: #0b0e13; margin-right: 6px; }
  #pstatus { color: var(--amber); font-size: 11px; white-space: nowrap; }

  /* telemetry log */
  #logwrap { flex: 1; min-height: 0; display: flex; flex-direction: column; background: var(--panel2); }
  #logbar { display: flex; align-items: center; gap: 6px; padding: 6px 12px;
    border-bottom: 1px solid var(--line); flex-wrap: wrap; }
  #logbar .lbl { color: var(--textFaint); font-size: 11px; text-transform: uppercase;
    letter-spacing: .06em; margin-right: 4px; }
  .chip {
    border: 1px solid var(--line); background: var(--panel2); color: var(--textDim);
    border-radius: 12px; padding: 3px 9px; font: 600 11px/1 inherit; cursor: pointer;
  }
  .chip.on { background: #1c2632; color: var(--textHi); border-color: #2f3b49; }
  .chip.err { color: #ffb4ae; }
  #logscroll { flex: 1; overflow-y: auto; }
  /* table-layout: fixed so the DETAIL column (the spoken transcript — the
     thing the founder actually wants to read) gets the width, instead of
     the auto algorithm handing it to the JSON data column and crushing the
     words to one-per-line. Widths come from the colgroup below. */
  table.log { width: 100%; border-collapse: collapse; font-size: 12px; table-layout: fixed; }
  table.log col.col-t { width: 52px; }
  table.log col.col-type { width: 116px; }
  table.log col.col-data { width: 188px; }
  /* col-detail takes the remaining width (the majority). */
  table.log th {
    position: sticky; top: 0; background: var(--panel); color: var(--textFaint);
    font-weight: 600; text-align: left; padding: 5px 10px; border-bottom: 1px solid var(--line);
    font-size: 10px; text-transform: uppercase; letter-spacing: .05em; z-index: 1;
  }
  table.log td { padding: 5px 10px; border-bottom: 1px solid var(--line2); vertical-align: top; }
  table.log tr { cursor: pointer; }
  table.log tr:hover { background: #161d27; }
  table.log tr.sel { background: #1c2632; }
  table.log tr.err td { color: #ffb4ae; }
  table.log tr.err td.c-type { color: #ff7b72; font-weight: 600; }
  td.c-t { color: var(--textDim); font-variant-numeric: tabular-nums; white-space: nowrap; }
  td.c-type { color: #adbac7; white-space: nowrap; font-weight: 500; overflow: hidden; text-overflow: ellipsis; }
  /* Wrap the transcript at spaces (normal word wrap), only breaking inside a
     word as a last resort — never the per-syllable shredding from before. */
  td.c-detail { color: var(--text); white-space: normal; overflow-wrap: anywhere; word-break: normal; line-height: 1.5; }
  /* Inline data is a one-line peek; the full JSON is one click away in the
     expand row + the right panel, so truncate rather than steal width. */
  td.c-data { color: var(--textDim); }
  td.c-data code { font: 11px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    color: #a5d6ff; display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .jsonrow td { background: var(--panel2); }
  .jsonrow pre { font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    color: #a5d6ff; white-space: pre-wrap; word-break: break-word; padding: 6px 10px;
    border-left: 2px solid #2f3b49; }

  /* right: detail */
  #detail {
    width: 320px; min-width: 320px; overflow-y: auto;
    background: var(--panel); border-left: 1px solid var(--line); padding: 12px;
  }
  #detail h2 { font-size: 11px; color: var(--textFaint); text-transform: uppercase;
    letter-spacing: .06em; margin-bottom: 8px; }
  #dhead { font-size: 13px; color: var(--textHi); font-weight: 600; margin-bottom: 2px;
    word-break: break-word; }
  #dtime { font-size: 11px; color: var(--textDim); margin-bottom: 8px; }
  #dplay {
    display: none; background: var(--green); color: #08130b; border: 0; border-radius: 6px;
    font: 700 12px/1 inherit; padding: 8px 14px; margin-bottom: 8px; cursor: pointer;
  }
  #dplay:hover { filter: brightness(1.1); }
  #djson {
    font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    background: var(--panel2); border: 1px solid var(--line); border-radius: 6px;
    padding: 10px; white-space: pre-wrap; word-break: break-word; color: #a5d6ff;
  }
  #dstats { margin-bottom: 12px; }
  #dstats .row { display: flex; justify-content: space-between; padding: 3px 0;
    border-bottom: 1px solid var(--line2); }
  #dstats .row span:first-child { color: var(--textDim); }
  #dstats .row span:last-child { color: var(--textHi); font-variant-numeric: tabular-nums; }
  text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
</style>
</head>
<body>
<header>
  <h1>AARC dash</h1>
  <span class="runlabel" id="runlabel">no run selected</span>
  <span class="spacer"></span>
  <span class="xtoggle" id="xtoggle">
    <button data-x="time" class="on">Time</button>
    <button data-x="dist">Distance</button>
  </span>
  <span class="hint">wheel = zoom &middot; drag = pan</span>
</header>
<div id="layout">
  <nav id="runs"><div class="empty">Loading runs&hellip;</div></nav>
  <main id="center">
    <div id="chartwrap">
      <svg id="chart" xmlns="http://www.w3.org/2000/svg"></svg>
      <div class="legend">
        <span><i style="background:var(--speed)"></i>speed (km/h)</span>
        <span><i style="background:var(--hr)"></i>HR (bpm)</span>
        <span><i style="background:var(--ricky)"></i>ricky</span>
        <span><i style="background:var(--jessica)"></i>jessica</span>
        <span><i style="background:#d29922"></i>net 11Labs</span>
        <span><i style="background:#39c5cf"></i>net LLM</span>
      </div>
      <div id="chartempty">Select a run</div>
    </div>
    <div id="player">
      <button id="pbtn" disabled>&#9654;</button>
      <div id="pmeta">
        <div id="ptext">No audio selected</div>
        <div id="psub">Click a speech pill on the chart, or a speech row in the log.</div>
      </div>
      <span id="pstatus"></span>
    </div>
    <div id="logwrap">
      <div id="logbar"><span class="lbl">Events</span></div>
      <div id="logscroll">
        <table class="log">
          <colgroup><col class="col-t"><col class="col-type"><col class="col-detail"><col class="col-data"></colgroup>
          <thead><tr><th>t</th><th>type</th><th>detail</th><th>data</th></tr></thead>
          <tbody id="logbody"></tbody>
        </table>
      </div>
    </div>
  </main>
  <aside id="detail">
    <h2>Selected event</h2>
    <div id="dhead">&mdash;</div>
    <div id="dtime"></div>
    <button id="dplay">&#9654; Play audio</button>
    <h2 style="margin-top:14px">Run summary</h2>
    <div id="dstats"><div class="row"><span>&mdash;</span><span></span></div></div>
    <h2>Raw JSON</h2>
    <pre id="djson">Click an event.</pre>
  </aside>
</div>
<script>
"use strict";
var SVG_NS = "http://www.w3.org/2000/svg";

// Voice ids (from iOS RemoteTTS) -> pill colour.
var VOICE_RICKY = "lKMAeQD7Brvj7QCWByqK";
var VOICE_JESSICA = "jP5jSWhfXz3nfQENMtf4";

// outlier gates (shared contract): drop implausible sensor noise.
var SPEED_MIN_KMH = 0, SPEED_MAX_KMH = 28;
var HR_MIN = 30, HR_MAX = 220;
var HR_AXIS_MAX = 200;   // right axis pinned to top 200 bpm (mirrors iOS)

var C = {
  speed: "#58a6ff", hr: "#f85149", ricky: "#e8a13a", jessica: "#ef6da8",
  voiceOther: "#8b949e",
  protect: "rgba(248,81,73,0.16)", protectEdge: "#f85149",
  prewarm: "#a371f7", coach: "#388bfd", drop: "#f85149", preempt: "#d29922",
  fallback: "#d29922", gen: "#1f6feb", endpoint: "#2ea043",
  bound: "#8b949e", error: "#f85149",
  // network lane (net.req): 11Labs amber, LLM cyan, failed red, cached dim blue
  net11Labs: "#d29922", netLLM: "#39c5cf", netFail: "#f85149", netCached: "#4a6b8a",
  axis: "#21262d", grid: "#1b212a", axisText: "#8b949e", select: "#58a6ff"
};

// chart geometry
var PAD_L = 46, PAD_R = 46, PAD_T = 14;
var PLOT_H = 170;          // performance plot
var MARK_ROWS = 5;         // speech, gen, network, director, control
var MARK_H = 70;           // event-marker strip directly under the plot
var AXIS_H = 22;           // x-axis labels
var CHART_H = PAD_T + PLOT_H + MARK_H + AXIS_H;

// marker rows inside the strip (each a thin lane)
var ROW = { speech: 0, gen: 1, network: 2, director: 3, control: 4 };
var ROW_H = MARK_H / MARK_ROWS;

var state = {
  runs: [], runId: null, events: [], metrics: [],
  xmode: "time",            // "time" | "dist"
  dur: 60, maxDist: 0,
  v0: 0, v1: 60,            // visible window in current x-units
  domain0: 0, domain1: 60,  // full data domain in current x-units
  selected: -1,
  directorIntervals: [],
  summary: null,
  pan: null
};

var chart = document.getElementById("chart");
var chartWrap = document.getElementById("chartwrap");
var audio = new Audio();
var curAudio = null;       // {url, text, voiceId, cacheKey}

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function num(v) { var n = Number(v); return isFinite(n) ? n : NaN; }
function has(s) { return s !== undefined && s !== null && String(s).trim() !== ""; }

function fmtClock(sec) {
  var neg = sec < 0 ? "-" : "";
  sec = Math.abs(sec);
  var m = Math.floor(sec / 60), s = sec - m * 60;
  var span = state.v1 - state.v0;
  var ss = (state.xmode === "time" && span < 20) ? s.toFixed(1) : String(Math.round(s));
  if (Number(ss) < 10) ss = "0" + ss;
  return neg + m + ":" + ss;
}
function fmtDur(sec) {
  if (sec == null || isNaN(sec)) return null;
  var m = Math.floor(sec / 60), s = Math.round(sec - m * 60);
  return m + "m" + (s < 10 ? "0" : "") + s + "s";
}
function fmtDist(m) {
  if (m == null || isNaN(m) || m <= 0) return null;
  return m >= 1000 ? (m / 1000).toFixed(2) + " km" : Math.round(m) + " m";
}
function fmtPace(secPerKm) {
  if (!isFinite(secPerKm) || secPerKm <= 0) return null;
  var m = Math.floor(secPerKm / 60), s = Math.round(secPerKm - m * 60);
  return m + ":" + (s < 10 ? "0" : "") + s + "/km";
}
function fmtXAxis(v) {
  if (state.xmode === "dist") {
    return v >= 1000 ? (v / 1000).toFixed(v < 10000 ? 2 : 1) + "k" : Math.round(v) + "m";
  }
  return fmtClock(v);
}
function metaObj(meta) {
  if (meta == null) return {};
  if (typeof meta === "object") return meta;
  if (typeof meta === "string") { try { return JSON.parse(meta); } catch (e) { return {}; } }
  return {};
}

// --- runs list --------------------------------------------------------
function loadRuns() {
  fetch("/api/runs").then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }).then(function (runs) {
    state.runs = Array.isArray(runs) ? runs : [];
    renderRuns();
    if (state.runs.length > 0) selectRun(state.runs[0].run_id);
  }).catch(function (e) {
    document.getElementById("runs").innerHTML =
      '<div class="empty">Failed to load runs: ' + esc(e.message) + "</div>";
  });
}
function renderRuns() {
  var nav = document.getElementById("runs");
  nav.innerHTML = "";
  if (state.runs.length === 0) { nav.innerHTML = '<div class="empty">No runs yet.</div>'; return; }
  state.runs.forEach(function (run) {
    var row = document.createElement("div");
    row.className = "run-row" + (run.run_id === state.runId ? " active" : "");
    var d = new Date(run.started_at);
    var dateStr = isNaN(d.getTime()) ? String(run.started_at)
      : d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " " +
        d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    var meta = metaObj(run.meta);
    var durS = has(meta.duration_s) ? num(meta.duration_s)
      : (has(meta.duration) ? num(meta.duration) : NaN);
    var distM = has(meta.distance_m) ? num(meta.distance_m)
      : (has(meta.distance) ? num(meta.distance) : NaN);
    var sub = document.createElement("div");
    sub.className = "sub";
    var bits = [];
    var fd = fmtDur(durS); if (fd) bits.push("<b>" + esc(fd) + "</b>");
    var fdist = fmtDist(distM); if (fdist) bits.push("<b>" + esc(fdist) + "</b>");
    bits.push(esc(run.event_count + " ev"));
    sub.innerHTML = bits.join(" ");
    var dateEl = document.createElement("div");
    dateEl.className = "date"; dateEl.textContent = dateStr;
    row.appendChild(dateEl); row.appendChild(sub);
    row.addEventListener("click", function () { selectRun(run.run_id); });
    nav.appendChild(row);
  });
}

// --- run selection + normalization ------------------------------------
function selectRun(id) {
  state.runId = id;
  state.selected = -1;
  resetAudio();
  renderRuns();
  document.getElementById("runlabel").textContent = "run " + id + " (loading\\u2026)";
  fetch("/api/runs/" + encodeURIComponent(id) + "/events").then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }).then(function (events) {
    if (state.runId !== id) return; // user moved on
    events = Array.isArray(events) ? events : [];
    events.forEach(function (ev) { ev.t = num(ev.t); if (isNaN(ev.t)) ev.t = 0; ev.data = ev.data || {}; });
    events.sort(function (a, b) { return a.t - b.t; });
    // heuristic: t accidentally in ms -> back to seconds
    var maxT = events.length ? events[events.length - 1].t : 0;
    if (maxT > 21600) {
      events.forEach(function (ev) { ev.t = ev.t / 1000; });
      maxT = maxT / 1000;
    }
    state.events = events;
    extractMetrics();
    var run = null;
    state.runs.forEach(function (r2) { if (r2.run_id === id) run = r2; });
    var meta = run ? metaObj(run.meta) : {};
    var metaDur = has(meta.duration_s) ? num(meta.duration_s)
      : (has(meta.duration) ? num(meta.duration) : NaN);
    state.dur = Math.max(maxT, isNaN(metaDur) ? 0 : metaDur, 10);
    state.maxDist = state.metrics.length ? state.metrics[state.metrics.length - 1].d : 0;
    if (!(state.maxDist > 0)) {
      var md = has(meta.distance_m) ? num(meta.distance_m) : (has(meta.distance) ? num(meta.distance) : NaN);
      if (md > 0) state.maxDist = md;
    }
    buildDirectorIntervals();
    computeSummary(meta);
    setXMode(state.xmode, true);    // sets domain + full-zoom window
    document.getElementById("runlabel").textContent =
      "run " + id + " \\u00b7 " + events.length + " events \\u00b7 " + (fmtDur(state.dur) || "");
    var hasData = events.length > 0;
    document.getElementById("chartempty").style.display = hasData ? "none" : "flex";
    document.getElementById("chartempty").textContent = hasData ? "" : "No events in this run";
    renderLog();
    scheduleRender();
  }).catch(function (e) {
    document.getElementById("runlabel").textContent = "run " + id + " \\u2014 failed: " + e.message;
  });
}

// Pull the "metrics" time-series, gate outliers, derive distance mapping.
function extractMetrics() {
  var out = [];
  state.events.forEach(function (ev) {
    if (ev.type !== "metrics") return;
    var d = ev.data || {};
    var dist = num(d.d);
    var speedMps = num(d.v);
    var paceSpk = num(d.p);
    var hr = num(d.hr);
    // derive km/h from v (m/s) if present, else from pace.
    var kmh = NaN;
    if (isFinite(speedMps) && speedMps >= 0) kmh = speedMps * 3.6;
    else if (isFinite(paceSpk) && paceSpk > 0) kmh = 3600 / paceSpk;
    var rec = {
      t: num(ev.t),
      d: isFinite(dist) && dist >= 0 ? dist : NaN,
      kmh: (isFinite(kmh) && kmh >= SPEED_MIN_KMH && kmh <= SPEED_MAX_KMH) ? kmh : NaN,
      pace: (isFinite(paceSpk) && paceSpk > 0) ? paceSpk
            : (isFinite(kmh) && kmh > 0 ? 3600 / kmh : NaN),
      hr: (isFinite(hr) && hr >= HR_MIN && hr <= HR_MAX) ? hr : NaN
    };
    if (isNaN(rec.t)) return;
    out.push(rec);
  });
  out.sort(function (a, b) { return a.t - b.t; });
  // forward-fill distance so distance-x works even with sparse d.
  var lastD = 0;
  out.forEach(function (r) {
    if (isFinite(r.d)) lastD = r.d; else r.d = lastD;
  });
  state.metrics = out;
}

function computeSummary(meta) {
  var m = state.metrics;
  var hrs = [], kmhs = [];
  m.forEach(function (r) { if (isFinite(r.hr)) hrs.push(r.hr); if (isFinite(r.kmh)) kmhs.push(r.kmh); });
  function avg(a) { if (!a.length) return NaN; var s = 0; a.forEach(function (x) { s += x; }); return s / a.length; }
  function max(a) { return a.length ? Math.max.apply(null, a) : NaN; }
  var speechCt = 0, errCt = 0;
  // network rollup: count, failures, and 11Labs latency percentiles.
  var netCt = 0, netFailCt = 0, elevenMs = [];
  state.events.forEach(function (ev) {
    if (ev.type === "speech") speechCt++;
    if (ev.type === "error" || ev.type === "tts.fallback" || ev.type === "gen.error") errCt++;
    if (ev.type === "net.req") {
      netCt++;
      var nd = ev.data || {};
      if (String(nd.phase) === "failed") netFailCt++;
      if (String(nd.svc) === "11Labs" && String(nd.phase) !== "cached") {
        var nms = num(nd.ms);
        if (isFinite(nms) && nms >= 0) elevenMs.push(nms);
      }
    }
  });
  function pct(a, p) {
    if (!a.length) return NaN;
    var s = a.slice().sort(function (x, y) { return x - y; });
    var i = Math.min(s.length - 1, Math.max(0, Math.round((p / 100) * (s.length - 1))));
    return s[i];
  }
  var dist = state.maxDist > 0 ? state.maxDist
    : (has(meta.distance_m) ? num(meta.distance_m) : NaN);
  var avgPace = (isFinite(dist) && dist > 0 && state.dur > 0) ? state.dur / (dist / 1000) : NaN;
  state.summary = {
    duration: state.dur, distance: dist, avgPace: avgPace,
    avgHr: avg(hrs), maxHr: max(hrs), avgKmh: avg(kmhs), maxKmh: max(kmhs),
    metricsCt: m.length, speechCt: speechCt, errCt: errCt,
    netCt: netCt, netFailCt: netFailCt,
    elevenP50: pct(elevenMs, 50), elevenP95: pct(elevenMs, 95)
  };
  renderSummary();
}
function renderSummary() {
  var s = state.summary, box = document.getElementById("dstats");
  if (!s) { box.innerHTML = ""; return; }
  function row(k, v) {
    if (v == null) return "";
    return '<div class="row"><span>' + esc(k) + '</span><span>' + esc(v) + "</span></div>";
  }
  var html = "";
  html += row("Duration", fmtDur(s.duration));
  html += row("Distance", fmtDist(s.distance));
  html += row("Avg pace", fmtPace(s.avgPace));
  if (isFinite(s.avgKmh)) html += row("Avg speed", s.avgKmh.toFixed(1) + " km/h");
  if (isFinite(s.avgHr)) html += row("Avg HR", Math.round(s.avgHr) + " bpm");
  if (isFinite(s.maxHr)) html += row("Max HR", Math.round(s.maxHr) + " bpm");
  html += row("Metrics pts", String(s.metricsCt));
  html += row("Speech lines", String(s.speechCt));
  if (s.errCt) html += row("Errors", String(s.errCt));
  if (s.netCt) {
    html += row("Net requests", String(s.netCt) + (s.netFailCt ? " (" + s.netFailCt + " failed)" : ""));
    if (isFinite(s.elevenP50)) html += row("11Labs p50", Math.round(s.elevenP50) + " ms");
    if (isFinite(s.elevenP95)) html += row("11Labs p95", Math.round(s.elevenP95) + " ms");
  }
  box.innerHTML = html || '<div class="row"><span>No data</span><span></span></div>';
}

// director.protect = state toggle: opens an interval the next director.*
// (or run end) closes; explicit data.ms wins as a duration.
function buildDirectorIntervals() {
  var out = [], open = null;
  state.events.forEach(function (ev) {
    if (ev.type !== "director.protect" && ev.type !== "director.room") return;
    var detail = String(ev.detail || "");
    // contract: director.protect detail may be "enter"/"exit".
    if (detail === "exit" && open) { open.end = ev.t; out.push(open); open = null; return; }
    var t = ev.t;
    if (open) { open.end = t; out.push(open); open = null; }
    var kind = ev.type === "director.protect" ? "protect" : "room";
    var ms = has(ev.data && ev.data.ms) ? num(ev.data.ms) : NaN;
    if (isFinite(ms) && ms > 0) out.push({ kind: kind, start: t, end: t + ms / 1000, ev: ev });
    else open = { kind: kind, start: t, end: state.dur, ev: ev };
  });
  if (open) out.push(open);
  state.directorIntervals = out;
}

// --- x mapping: time<->distance ---------------------------------------
// In distance mode we still locate events by their t via the metrics curve.
function tToX(t) {
  if (state.xmode === "time") return t;
  // map elapsed seconds to distance by interpolating the metrics d(t) curve.
  var m = state.metrics;
  if (!m.length) return 0;
  if (t <= m[0].t) return m[0].d;
  if (t >= m[m.length - 1].t) return m[m.length - 1].d;
  // binary search
  var lo = 0, hi = m.length - 1;
  while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (m[mid].t <= t) lo = mid; else hi = mid; }
  var a = m[lo], b = m[hi];
  var span = b.t - a.t;
  if (span <= 0) return a.d;
  return a.d + (b.d - a.d) * (t - a.t) / span;
}
function setXMode(mode, keepFullZoom) {
  state.xmode = mode;
  document.querySelectorAll("#xtoggle button").forEach(function (b) {
    b.classList.toggle("on", b.getAttribute("data-x") === mode);
  });
  state.domain0 = 0;
  state.domain1 = mode === "dist"
    ? Math.max(state.maxDist, 1)
    : Math.max(state.dur, 1);
  if (keepFullZoom || state.v1 <= state.v0) {
    state.v0 = state.domain0; state.v1 = state.domain1;
  } else {
    clampView();
  }
}

// --- svg helpers -------------------------------------------------------
function el(name, attrs) {
  var node = document.createElementNS(SVG_NS, name);
  for (var k in attrs) node.setAttribute(k, attrs[k]);
  return node;
}
function withTitle(node, text) {
  var t = document.createElementNS(SVG_NS, "title");
  t.textContent = text; node.appendChild(t); return node;
}
function clickable(node, idx) {
  node.style.cursor = "pointer";
  node.addEventListener("click", function (e) { e.stopPropagation(); select(idx); });
  return node;
}

// --- chart rendering ---------------------------------------------------
var renderQueued = false;
function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(function () { renderQueued = false; render(); });
}

function render() {
  var W = chartWrap.clientWidth || 800;
  chart.setAttribute("viewBox", "0 0 " + W + " " + CHART_H);
  chart.setAttribute("height", CHART_H);
  while (chart.firstChild) chart.removeChild(chart.firstChild);

  var plotW = W - PAD_L - PAD_R;
  if (plotW < 10) plotW = 10;
  var v0 = state.v0, v1 = state.v1, span = v1 - v0;
  if (span <= 0) span = 1;
  function X(v) { return PAD_L + (v - v0) / span * plotW; }
  var plotTop = PAD_T, plotBot = PAD_T + PLOT_H;
  var markTop = plotBot, markBot = markTop + MARK_H;
  var axisY = markBot;

  // ---- speed (left) axis auto-scale with headroom -------------------
  var maxKmh = 0;
  state.metrics.forEach(function (r) { if (isFinite(r.kmh) && r.kmh > maxKmh) maxKmh = r.kmh; });
  var speedTop = Math.max(Math.ceil((maxKmh * 1.18) / 2) * 2, 6);
  if (speedTop > SPEED_MAX_KMH) speedTop = SPEED_MAX_KMH;
  function Yspeed(kmh) { return plotBot - (kmh / speedTop) * PLOT_H; }
  function Yhr(hr) { return plotBot - (hr / HR_AXIS_MAX) * PLOT_H; }

  // ---- grid + plot frame --------------------------------------------
  chart.appendChild(el("rect", { x: PAD_L, y: plotTop, width: plotW, height: PLOT_H,
    fill: "none", stroke: C.axis }));
  // horizontal gridlines on the speed scale
  var sStep = speedTop <= 8 ? 2 : speedTop <= 16 ? 4 : 5;
  for (var sv = 0; sv <= speedTop + 0.01; sv += sStep) {
    var gy = Yspeed(sv);
    chart.appendChild(el("line", { x1: PAD_L, y1: gy, x2: PAD_L + plotW, y2: gy,
      stroke: C.grid, "stroke-opacity": sv === 0 ? 0 : 0.7 }));
    var sl = el("text", { x: PAD_L - 6, y: gy + 3, fill: C.speed, "font-size": 10,
      "text-anchor": "end", "pointer-events": "none" });
    sl.textContent = String(sv);
    chart.appendChild(sl);
  }
  // right HR axis ticks (pinned 0..200)
  [0, 50, 100, 150, 200].forEach(function (hv) {
    var hy = Yhr(hv);
    var hl = el("text", { x: PAD_L + plotW + 6, y: hy + 3, fill: C.hr, "font-size": 10,
      "text-anchor": "start", "pointer-events": "none" });
    hl.textContent = String(hv);
    chart.appendChild(hl);
  });
  // axis titles
  var stitle = el("text", { x: PAD_L - 6, y: plotTop - 3, fill: C.speed, "font-size": 9,
    "text-anchor": "start", "pointer-events": "none" });
  stitle.textContent = "km/h";
  chart.appendChild(stitle);
  var htitle = el("text", { x: PAD_L + plotW + 6, y: plotTop - 3, fill: C.hr, "font-size": 9,
    "text-anchor": "end", "pointer-events": "none" });
  htitle.textContent = "bpm";
  chart.appendChild(htitle);

  // ---- x axis ticks --------------------------------------------------
  var ticks = niceTicks(v0, v1, 10);
  ticks.forEach(function (tv) {
    var tx = X(tv);
    if (tx < PAD_L - 1 || tx > PAD_L + plotW + 1) return;
    chart.appendChild(el("line", { x1: tx, y1: plotTop, x2: tx, y2: axisY,
      stroke: C.grid, "stroke-opacity": 0.5 }));
    var lbl = el("text", { x: tx, y: axisY + 14, fill: C.axisText, "font-size": 10,
      "text-anchor": "middle", "pointer-events": "none" });
    lbl.textContent = fmtXAxis(tv);
    chart.appendChild(lbl);
  });

  // ---- SPEED area (wide translucent) --------------------------------
  drawSeries(chart, X, function (r) { return r.kmh; }, Yspeed, {
    area: true, color: C.speed, areaOpacity: 0.16, lineOpacity: 0.55, width: 1.5,
    clipTop: plotTop, clipBot: plotBot
  });
  // ---- HR line (narrow solid) ---------------------------------------
  drawSeries(chart, X, function (r) { return r.hr; }, Yhr, {
    area: false, color: C.hr, lineOpacity: 0.95, width: 1.75,
    clipTop: plotTop, clipBot: plotBot
  });

  // ---- director protect bands (behind markers) ----------------------
  state.directorIntervals.forEach(function (iv) {
    var sx = tToX(iv.start), ex = tToX(iv.end);
    var x0 = Math.max(X(sx), PAD_L), x1 = Math.min(X(ex), PAD_L + plotW);
    if (x1 <= PAD_L || x0 >= PAD_L + plotW) return;
    var idx = state.events.indexOf(iv.ev);
    var band = el("rect", { x: x0, y: plotTop, width: Math.max(x1 - x0, 2), height: PLOT_H + MARK_H,
      fill: C.protect, stroke: state.selected === idx ? C.select : C.protectEdge,
      "stroke-width": state.selected === idx ? 1.5 : 0.5,
      "stroke-opacity": state.selected === idx ? 1 : 0.5 });
    withTitle(band, "director.protect " + fmtClock(iv.start) + " \\u2192 " + fmtClock(iv.end));
    clickable(band, idx);
    chart.appendChild(band);
  });

  // ---- marker strip backgrounds -------------------------------------
  for (var ri = 0; ri < MARK_ROWS; ri++) {
    var ry = markTop + ri * ROW_H;
    if (ri > 0) chart.appendChild(el("line", { x1: PAD_L, y1: ry, x2: PAD_L + plotW, y2: ry,
      stroke: C.grid, "stroke-opacity": 0.4 }));
  }

  // ---- event markers -------------------------------------------------
  state.events.forEach(function (ev, idx) {
    var type = String(ev.type || "");
    if (type === "metrics") return;
    if (type === "director.protect" || type === "director.room") return; // bands
    var vx = tToX(ev.t);
    if (vx < v0 - span * 0.02 || vx > v1 + span * 0.02) {
      // still allow speech (pills have width) to clip in
      if (type !== "speech") return;
    }
    var px = X(vx);
    var sel = state.selected === idx;
    var data = ev.data || {};

    if (type === "run.start" || type === "run.end" ||
        (type === "run" && (ev.detail === "started" || ev.detail === "ended"))) {
      var isStart = type === "run.start" || ev.detail === "started";
      var line = el("line", { x1: px, y1: plotTop, x2: px, y2: axisY,
        stroke: sel ? C.select : C.bound, "stroke-dasharray": "4 3", "stroke-width": sel ? 2 : 1 });
      withTitle(line, (isStart ? "run start" : "run end") + " @ " + fmtClock(ev.t));
      clickable(line, idx);
      chart.appendChild(line);
      var bl = el("text", { x: px + 3, y: plotTop + 10, fill: C.bound, "font-size": 9,
        "pointer-events": "none" });
      bl.textContent = isStart ? "start" : "end";
      chart.appendChild(bl);
      return;
    }

    if (type === "speech") {
      var ry0 = markTop + ROW.speech * ROW_H;
      var text = String(ev.detail || "");
      var vid = String(data.voiceId || "");
      var isJess = vid === VOICE_JESSICA || String(data.source || "").indexOf("jessica") === 0;
      var isRicky = vid === VOICE_RICKY || (!isJess);
      var fill = isJess ? C.jessica : isRicky ? C.ricky : C.voiceOther;
      // estimate pill width by speech duration (~15 chars/sec) projected to x.
      var estDur = Math.max(text.length / 15, 1.2);
      var endX = X(tToX(ev.t + estDur));
      var pw = Math.max(endX - px, 10);
      if (px + pw < PAD_L || px > PAD_L + plotW) return;
      var pill = el("rect", { x: px, y: ry0 + 1, width: pw, height: ROW_H - 3, rx: 4,
        fill: fill, "fill-opacity": data.cacheKey ? 0.9 : 0.55,
        stroke: sel ? C.select : "none", "stroke-width": 2 });
      withTitle(pill, (isJess ? "jessica" : "ricky") + " @ " + fmtClock(ev.t) + ": " + text);
      clickable(pill, idx);
      chart.appendChild(pill);
      if (pw > 36) {
        var maxChars = Math.floor((pw - 6) / 5.4);
        var snip = text.length > maxChars ? text.slice(0, Math.max(maxChars - 1, 1)) + "\\u2026" : text;
        var tn = el("text", { x: px + 3, y: ry0 + ROW_H - 4, fill: "#0b0e13", "font-size": 9,
          "pointer-events": "none" });
        tn.textContent = snip;
        chart.appendChild(tn);
      }
      return;
    }

    if (type === "jessica.react" || type === "jessica.skip") {
      var jy = markTop + ROW.speech * ROW_H + ROW_H / 2;
      var jc = el("circle", { cx: px, cy: jy, r: 3.2,
        fill: type === "jessica.skip" ? "none" : C.jessica, stroke: C.jessica,
        "stroke-width": sel ? 2 : 1 });
      withTitle(jc, type + " @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : ""));
      clickable(jc, idx);
      chart.appendChild(jc);
      return;
    }

    // NETWORK lane (net.req): one request per marker.
    //   color  = svc (11Labs amber / LLM cyan)
    //   red    = phase "failed"
    //   dim    = phase "cached"
    //   height = latency (data.ms) -> taller bar = slower request
    if (type === "net.req") {
      var ny = markTop + ROW.network * ROW_H;
      var svc = String(data.svc || "");
      var phase = String(data.phase || "");
      var nms = has(data.ms) ? num(data.ms) : NaN;
      var failed = phase === "failed";
      var cached = phase === "cached";
      var ncolor = failed ? C.netFail
        : cached ? C.netCached
        : svc === "LLM" ? C.netLLM
        : svc === "11Labs" ? C.net11Labs
        : C.bound;
      // bar height ~ ms (1px per 40ms), clamped to the lane; cached/no-ms = stub.
      var nh = (isFinite(nms) && nms > 0) ? Math.min(Math.max(nms / 40, 4), ROW_H - 4) : 5;
      var nbar = el("rect", { x: px - 1.5, y: ny + ROW_H - 1 - nh, width: 3, height: nh,
        rx: 1, fill: ncolor, "fill-opacity": cached ? 0.7 : 1,
        stroke: sel ? C.select : "none", "stroke-width": 1.5 });
      var nbits = [(svc || "net") + " net.req", "@ " + fmtClock(ev.t)];
      if (ev.detail) nbits.push(String(ev.detail));
      if (isFinite(nms)) nbits.push(nms + "ms");
      if (phase) nbits.push(phase);
      if (has(data.bytes)) nbits.push(data.bytes + "B");
      if (has(data.info)) nbits.push(String(data.info));
      withTitle(nbar, nbits.join(" \\u00b7 "));
      clickable(nbar, idx);
      chart.appendChild(nbar);
      // failed requests also get an X tick above the bar so they pop.
      if (failed) {
        var fx = px, fy = ny + 3;
        var xm = el("path", { d: "M" + (fx - 3) + " " + fy + "L" + (fx + 3) + " " + (fy + 6) +
          "M" + (fx + 3) + " " + fy + "L" + (fx - 3) + " " + (fy + 6),
          stroke: C.netFail, "stroke-width": 1.5, "pointer-events": "none" });
        chart.appendChild(xm);
      }
      return;
    }

    // GEN/TTS latency row
    if (type === "tts.play" || type === "tts.fallback" || type.indexOf("gen.") === 0 ||
        type === "script.dispatch" || type === "endpoint.switch") {
      var gy = markTop + ROW.gen * ROW_H;
      var color = type === "tts.fallback" ? C.fallback
        : type === "gen.error" ? C.error
        : type === "endpoint.switch" ? C.endpoint
        : type === "script.dispatch" ? C.coach
        : type === "tts.play" ? C.speed : C.gen;
      var ms = has(data.ms) ? num(data.ms) : NaN;
      var isFb = type === "tts.fallback" || type === "gen.error";
      if (isFb) {
        // red diamond
        var d = "M" + px + " " + (gy + 3) + "L" + (px + 5) + " " + (gy + ROW_H / 2) +
                "L" + px + " " + (gy + ROW_H - 3) + "L" + (px - 5) + " " + (gy + ROW_H / 2) + "Z";
        var dia = el("path", { d: d, fill: C.error, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
        withTitle(dia, type + " @ " + fmtClock(ev.t) + (data.reason ? ": " + data.reason : ""));
        clickable(dia, idx);
        chart.appendChild(dia);
      } else {
        var th = isFinite(ms) ? Math.min(Math.max(ms / 60, 5), ROW_H - 4) : 6;
        var tick = el("rect", { x: px - 1.5, y: gy + ROW_H - 1 - th, width: 3, height: th,
          fill: color, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
        var bits = [type, "@ " + fmtClock(ev.t)];
        if (isFinite(ms)) bits.push(ms + "ms");
        if (data.cached) bits.push("cached=" + data.cached);
        if (data.backend) bits.push(String(data.backend));
        if (data.trigger) bits.push(String(data.trigger));
        withTitle(tick, bits.join(" "));
        clickable(tick, idx);
        chart.appendChild(tick);
      }
      return;
    }

    if (type === "director.prewarm" || type === "coach.trigger" ||
        type === "voice.play" || type === "voice.dropStale" || type === "voice.preempt") {
      var cy = markTop + ROW.control * ROW_H;
      var cc = type === "director.prewarm" ? C.prewarm
        : type === "coach.trigger" ? C.coach
        : type === "voice.dropStale" ? C.drop
        : type === "voice.preempt" ? C.preempt : C.bound;
      var ch = (type === "voice.dropStale" || type === "voice.preempt") ? ROW_H - 6 : 7;
      var tk = el("rect", { x: px - 1.2, y: cy + (ROW_H - ch) / 2, width: 2.4, height: ch,
        fill: cc, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
      withTitle(tk, type + " @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : ""));
      clickable(tk, idx);
      chart.appendChild(tk);
      return;
    }

    if (type === "error") {
      var ey = markTop + ROW.director * ROW_H + ROW_H / 2;
      var d2 = "M" + px + " " + (ey - 5) + "L" + (px + 5) + " " + ey +
               "L" + px + " " + (ey + 5) + "L" + (px - 5) + " " + ey + "Z";
      var er = el("path", { d: d2, fill: C.error, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
      withTitle(er, "error @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : ""));
      clickable(er, idx);
      chart.appendChild(er);
      return;
    }

    // unknown: faint tick on the control row
    var uy = markTop + ROW.control * ROW_H + ROW_H - 6;
    var ut = el("rect", { x: px - 0.75, y: uy, width: 1.5, height: 5, fill: "#30363d",
      stroke: sel ? C.select : "none" });
    withTitle(ut, type + " @ " + fmtClock(ev.t));
    clickable(ut, idx);
    chart.appendChild(ut);
  });
}

// draw a metrics series as line (+ optional filled area to baseline).
function drawSeries(svg, X, getY, mapY, opt) {
  var m = state.metrics;
  if (!m.length) return;
  // build polyline segments, breaking on NaN gaps.
  var segs = [], cur = [];
  m.forEach(function (r) {
    var y = getY(r);
    if (!isFinite(y)) { if (cur.length) { segs.push(cur); cur = []; } return; }
    var xv = state.xmode === "dist" ? r.d : r.t;
    cur.push({ x: X(xv), y: mapY(y) });
  });
  if (cur.length) segs.push(cur);
  if (!segs.length) return;
  segs.forEach(function (seg) {
    if (opt.area) {
      var dArea = "M" + seg[0].x + " " + opt.clipBot;
      seg.forEach(function (p) { dArea += " L" + p.x + " " + clampY(p.y, opt) ; });
      dArea += " L" + seg[seg.length - 1].x + " " + opt.clipBot + " Z";
      svg.appendChild(el("path", { d: dArea, fill: opt.color, "fill-opacity": opt.areaOpacity,
        stroke: "none" }));
    }
    var dLine = "";
    seg.forEach(function (p, i) { dLine += (i ? " L" : "M") + p.x + " " + clampY(p.y, opt); });
    svg.appendChild(el("path", { d: dLine, fill: "none", stroke: opt.color,
      "stroke-width": opt.width, "stroke-opacity": opt.lineOpacity,
      "stroke-linejoin": "round", "stroke-linecap": "round" }));
  });
}
function clampY(y, opt) {
  if (y < opt.clipTop) return opt.clipTop;
  if (y > opt.clipBot) return opt.clipBot;
  return y;
}
function niceTicks(a, b, target) {
  var span = b - a;
  if (span <= 0) return [a];
  var raw = span / target;
  var mag = Math.pow(10, Math.floor(Math.log10(raw)));
  var norm = raw / mag;
  var step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
  var out = [], t = Math.ceil(a / step) * step;
  for (; t <= b + step * 0.001 && out.length < 60; t += step) out.push(t);
  return out;
}

// --- selection + detail -----------------------------------------------
function select(idx) {
  state.selected = idx;
  scheduleRender();
  highlightLogRow(idx);
  var ev = state.events[idx];
  if (!ev) return;
  document.getElementById("dhead").textContent =
    ev.type + (ev.detail ? " \\u2014 " + ev.detail : "");
  var wall = ev.wall ? " \\u00b7 " + ev.wall : "";
  document.getElementById("dtime").textContent = "t=" + fmtClock(num(ev.t) || 0) + wall;
  document.getElementById("djson").textContent = JSON.stringify(ev, null, 2);
  var canPlay = ev.type === "speech";
  var playBtn = document.getElementById("dplay");
  playBtn.style.display = canPlay ? "inline-block" : "none";
  if (canPlay) loadSpeech(ev, true);  // selecting a speech pill loads + plays
}

// --- audio: single reusable element, same-origin relative URL ----------
function resetAudio() {
  audio.pause();
  curAudio = null;
  document.getElementById("pbtn").disabled = true;
  document.getElementById("pbtn").innerHTML = "&#9654;";
  document.getElementById("ptext").textContent = "No audio selected";
  document.getElementById("psub").textContent = "Click a speech pill on the chart, or a speech row in the log.";
  document.getElementById("pstatus").textContent = "";
}
function voiceLabel(ev) {
  var vid = String((ev.data || {}).voiceId || "");
  if (vid === VOICE_JESSICA || String((ev.data || {}).source || "").indexOf("jessica") === 0) return "jessica";
  if (vid === VOICE_RICKY) return "ricky";
  return "voice";
}
function loadSpeech(ev, autoplay) {
  var data = ev.data || {};
  var text = String(ev.detail || "");
  var who = voiceLabel(ev);
  var chipColor = who === "jessica" ? C.jessica : who === "ricky" ? C.ricky : C.voiceOther;
  document.getElementById("ptext").textContent = text || "(no text)";
  document.getElementById("psub").innerHTML =
    '<span class="voicechip" style="background:' + chipColor + '">' + esc(who) + "</span>" +
    (data.cacheKey ? "tap play to hear it" : "no cacheKey on this line");
  var statusEl = document.getElementById("pstatus");
  var btn = document.getElementById("pbtn");

  if (!data.cacheKey) {
    statusEl.textContent = "audio key missing";
    btn.disabled = true; btn.innerHTML = "&#9654;";
    curAudio = null;
    return;
  }
  var url = "/api/runs/" + encodeURIComponent(state.runId) + "/audio/" + encodeURIComponent(data.cacheKey);
  curAudio = { url: url, text: text, who: who, cacheKey: data.cacheKey };
  btn.disabled = false;
  statusEl.textContent = "";
  if (autoplay) playCurrent();
}
function playCurrent() {
  if (!curAudio) return;
  var statusEl = document.getElementById("pstatus");
  var btn = document.getElementById("pbtn");
  // (re)load src only if changed, so pause/resume works.
  if (audio.getAttribute("data-key") !== curAudio.cacheKey) {
    audio.src = curAudio.url;
    audio.setAttribute("data-key", curAudio.cacheKey);
  }
  statusEl.textContent = "loading\\u2026";
  audio.play().then(function () {
    statusEl.textContent = "playing";
    btn.innerHTML = "&#10074;&#10074;";
  }).catch(function () {
    // distinguish 404 (not archived) vs 503 (archive disabled) vs other.
    fetch(curAudio.url, { method: "HEAD" }).then(function (r) {
      if (r.status === 404) statusEl.textContent = "audio not archived";
      else if (r.status === 503) statusEl.textContent = "audio archive disabled";
      else if (r.ok) statusEl.textContent = "couldn't play (decode error)";
      else statusEl.textContent = "audio unavailable (HTTP " + r.status + ")";
    }).catch(function () { statusEl.textContent = "audio unavailable"; });
    btn.innerHTML = "&#9654;";
  });
}
document.getElementById("pbtn").addEventListener("click", function () {
  if (!curAudio) return;
  if (!audio.paused && audio.getAttribute("data-key") === curAudio.cacheKey) {
    audio.pause();
    document.getElementById("pbtn").innerHTML = "&#9654;";
    document.getElementById("pstatus").textContent = "paused";
  } else {
    playCurrent();
  }
});
audio.addEventListener("ended", function () {
  document.getElementById("pbtn").innerHTML = "&#9654;";
  document.getElementById("pstatus").textContent = "done";
});
document.getElementById("dplay").addEventListener("click", function () {
  var ev = state.events[state.selected];
  if (ev && ev.type === "speech") { loadSpeech(ev, true); }
});

// --- telemetry log -----------------------------------------------------
var logFilter = { types: null };  // null = all
function eventTypes() {
  var set = {};
  state.events.forEach(function (ev) { set[ev.type] = (set[ev.type] || 0) + 1; });
  return set;
}
function isErr(type) {
  return type === "error" || type === "tts.fallback" || type === "gen.error";
}
function renderLog() {
  var bar = document.getElementById("logbar");
  bar.innerHTML = '<span class="lbl">Filter</span>';
  var types = eventTypes();
  var keys = Object.keys(types).sort();
  var allChip = document.createElement("span");
  allChip.className = "chip" + (logFilter.types === null ? " on" : "");
  allChip.textContent = "all";
  allChip.addEventListener("click", function () { logFilter.types = null; renderLog(); });
  bar.appendChild(allChip);
  keys.forEach(function (k) {
    var chip = document.createElement("span");
    var on = logFilter.types && logFilter.types[k];
    chip.className = "chip" + (on ? " on" : "") + (isErr(k) ? " err" : "");
    chip.textContent = k + " " + types[k];
    chip.addEventListener("click", function () {
      if (logFilter.types === null) logFilter.types = {};
      if (logFilter.types[k]) delete logFilter.types[k]; else logFilter.types[k] = true;
      if (Object.keys(logFilter.types).length === 0) logFilter.types = null;
      renderLog();
    });
    bar.appendChild(chip);
  });
  renderLogBody();
}
function renderLogBody() {
  var body = document.getElementById("logbody");
  body.innerHTML = "";
  state.events.forEach(function (ev, idx) {
    if (logFilter.types && !logFilter.types[ev.type]) return;
    var tr = document.createElement("tr");
    tr.className = (isErr(ev.type) ? "err " : "") + (idx === state.selected ? "sel" : "");
    tr.setAttribute("data-idx", String(idx));
    var dataStr = "";
    try { dataStr = JSON.stringify(ev.data || {}); } catch (e) { dataStr = ""; }
    if (dataStr === "{}") dataStr = "";
    tr.innerHTML =
      '<td class="c-t">' + esc(fmtClock(num(ev.t) || 0)) + "</td>" +
      '<td class="c-type">' + esc(ev.type) + "</td>" +
      '<td class="c-detail">' + esc(String(ev.detail || "")) + "</td>" +
      '<td class="c-data"><code>' + esc(dataStr) + "</code></td>";
    tr.addEventListener("click", function (e) {
      select(idx);
      toggleJsonRow(tr, ev);
    });
    body.appendChild(tr);
  });
}
function toggleJsonRow(tr, ev) {
  var next = tr.nextSibling;
  if (next && next.classList && next.classList.contains("jsonrow")) {
    next.parentNode.removeChild(next);
    return;
  }
  // remove any other open json row
  document.querySelectorAll(".jsonrow").forEach(function (n) { n.parentNode.removeChild(n); });
  var jr = document.createElement("tr");
  jr.className = "jsonrow";
  var td = document.createElement("td");
  td.colSpan = 4;
  var pre = document.createElement("pre");
  pre.textContent = JSON.stringify(ev, null, 2);
  td.appendChild(pre); jr.appendChild(td);
  tr.parentNode.insertBefore(jr, tr.nextSibling);
}
function highlightLogRow(idx) {
  var body = document.getElementById("logbody");
  body.querySelectorAll("tr.sel").forEach(function (r) { r.classList.remove("sel"); });
  var row = body.querySelector('tr[data-idx="' + idx + '"]');
  if (row) {
    row.classList.add("sel");
    row.scrollIntoView({ block: "nearest" });
  }
}

// --- x toggle ----------------------------------------------------------
document.querySelectorAll("#xtoggle button").forEach(function (b) {
  b.addEventListener("click", function () {
    if (b.classList.contains("on")) return;
    setXMode(b.getAttribute("data-x"), true);
    scheduleRender();
  });
});

// --- zoom + pan on the chart ------------------------------------------
chart.addEventListener("wheel", function (e) {
  if (!state.events.length) return;
  e.preventDefault();
  var W = chartWrap.clientWidth || 800;
  var plotW = Math.max(W - PAD_L - PAD_R, 10);
  var span = state.v1 - state.v0;
  var factor = e.deltaY > 0 ? 1.25 : 0.8;
  var minSpan = state.xmode === "dist" ? 5 : 0.5;
  var newSpan = Math.min(Math.max(span * factor, minSpan), state.domain1 * 1.1);
  var rect = chart.getBoundingClientRect();
  var px = (e.clientX - rect.left - PAD_L) / plotW;
  if (px < 0) px = 0; if (px > 1) px = 1;
  var pivot = state.v0 + px * span;
  state.v0 = pivot - px * newSpan;
  state.v1 = state.v0 + newSpan;
  clampView();
  scheduleRender();
}, { passive: false });

chart.addEventListener("pointerdown", function (e) {
  if (!state.events.length) return;
  state.pan = { x: e.clientX, v0: state.v0, v1: state.v1, moved: false };
  chart.classList.add("panning");
  try { chart.setPointerCapture(e.pointerId); } catch (err) {}
});
chart.addEventListener("pointermove", function (e) {
  if (!state.pan) return;
  var W = chartWrap.clientWidth || 800;
  var plotW = Math.max(W - PAD_L - PAD_R, 10);
  var dx = e.clientX - state.pan.x;
  if (Math.abs(dx) > 2) state.pan.moved = true;
  var dv = -dx / plotW * (state.pan.v1 - state.pan.v0);
  state.v0 = state.pan.v0 + dv;
  state.v1 = state.pan.v1 + dv;
  clampView();
  scheduleRender();
});
function endPan() { state.pan = null; chart.classList.remove("panning"); }
chart.addEventListener("pointerup", endPan);
chart.addEventListener("pointercancel", endPan);

function clampView() {
  var span = state.v1 - state.v0;
  var lo = state.domain0 - state.domain1 * 0.04;
  var hi = state.domain1 * 1.04;
  if (span > hi - lo) { state.v0 = lo; state.v1 = hi; return; }
  if (state.v0 < lo) { state.v0 = lo; state.v1 = lo + span; }
  if (state.v1 > hi) { state.v1 = hi; state.v0 = hi - span; }
}

window.addEventListener("resize", scheduleRender);
loadRuns();
</script>
</body>
</html>
`;
