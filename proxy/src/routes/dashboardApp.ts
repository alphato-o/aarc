/// Dashboard app shell for GET /dash with a valid session cookie.
/// Self-contained: inline CSS, inline vanilla JS + SVG, zero CDN deps.
///
/// Data contract (sibling data-API agent):
///   GET /api/runs                    -> [{run_id, started_at, event_count, meta}]
///   GET /api/runs/:id/events        -> [{t, wall, type, detail, data}]
///   GET /api/runs/:id/audio/:key    -> audio (may 503 until R2 enabled)
///
/// NOTE for editors: the embedded JS deliberately avoids backticks and
/// "${" so it can live inside this TS template literal unescaped.
export const APP_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>AARC dash</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body {
    font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #0e1116; color: #c9d1d9; overflow: hidden;
  }
  header {
    height: 42px; display: flex; align-items: center; gap: 12px;
    padding: 0 14px; background: #161b22; border-bottom: 1px solid #21262d;
  }
  header h1 { font-size: 14px; font-weight: 600; color: #e6edf3; }
  header .runlabel { color: #8b949e; font-size: 12px; }
  header .spacer { flex: 1; }
  header .hint { color: #484f58; font-size: 11px; }
  #layout { display: flex; height: calc(100% - 42px); }

  /* left rail: runs */
  #runs {
    width: 230px; min-width: 230px; overflow-y: auto;
    background: #11151c; border-right: 1px solid #21262d;
  }
  .run-row {
    padding: 8px 12px; border-bottom: 1px solid #1b212a; cursor: pointer;
  }
  .run-row:hover { background: #161d27; }
  .run-row.active { background: #1c2632; box-shadow: inset 3px 0 0 #58a6ff; }
  .run-row .date { color: #e6edf3; font-weight: 600; font-size: 12px; }
  .run-row .sub { color: #8b949e; font-size: 11px; margin-top: 2px; }
  #runs .empty { padding: 16px 12px; color: #8b949e; font-size: 12px; }

  /* main: timeline */
  #main { flex: 1; display: flex; flex-direction: column; min-width: 0; }
  #tlwrap { flex: 1; position: relative; overflow: hidden; }
  #tl { display: block; width: 100%; height: 100%; cursor: grab; }
  #tl.panning { cursor: grabbing; }
  #tlempty {
    position: absolute; inset: 0; display: flex; align-items: center;
    justify-content: center; color: #484f58; font-size: 13px; pointer-events: none;
  }

  /* right: detail */
  #detail {
    width: 320px; min-width: 320px; overflow-y: auto;
    background: #11151c; border-left: 1px solid #21262d; padding: 12px;
  }
  #detail h2 { font-size: 12px; color: #8b949e; text-transform: uppercase;
    letter-spacing: .06em; margin-bottom: 8px; }
  #dhead { font-size: 13px; color: #e6edf3; font-weight: 600; margin-bottom: 2px;
    word-break: break-word; }
  #dtime { font-size: 11px; color: #8b949e; margin-bottom: 8px; }
  #dplay {
    display: none; background: #238636; color: #fff; border: 0; border-radius: 6px;
    font: 600 12px/1 inherit; padding: 8px 14px; margin-bottom: 8px; cursor: pointer;
  }
  #dplay:hover { background: #2ea043; }
  #daudiostatus { font-size: 11px; color: #d29922; margin-bottom: 8px; min-height: 14px; }
  #djson {
    font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    background: #0e1116; border: 1px solid #21262d; border-radius: 6px;
    padding: 10px; white-space: pre-wrap; word-break: break-word; color: #a5d6ff;
  }
  text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
</style>
</head>
<body>
<header>
  <h1>AARC dash</h1>
  <span class="runlabel" id="runlabel">no run selected</span>
  <span class="spacer"></span>
  <span class="hint">wheel = zoom &middot; drag = pan &middot; click = inspect/play</span>
</header>
<div id="layout">
  <nav id="runs"><div class="empty">Loading runs&hellip;</div></nav>
  <main id="main">
    <div id="tlwrap">
      <svg id="tl" xmlns="http://www.w3.org/2000/svg"></svg>
      <div id="tlempty">Select a run</div>
    </div>
  </main>
  <aside id="detail">
    <h2>Event detail</h2>
    <div id="dhead">&mdash;</div>
    <div id="dtime"></div>
    <button id="dplay">&#9654; Play audio</button>
    <div id="daudiostatus"></div>
    <pre id="djson">Click an event on the timeline.</pre>
  </aside>
</div>
<script>
"use strict";
var SVG_NS = "http://www.w3.org/2000/svg";

// --- colors -----------------------------------------------------------
var C = {
  ricky: "#e8a13a", jessica: "#ef6da8", voiceOther: "#8b949e",
  genReq: "#388bfd", genResp: "#1f6feb", genErr: "#f85149",
  ttsFetch: "#6e7681", ttsPlay: "#3fb950", ttsFallback: "#d29922",
  protect: "rgba(248,81,73,0.30)", protectEdge: "#f85149",
  room: "rgba(63,185,80,0.18)", roomEdge: "#2ea043",
  qEnqueue: "#30363d", qDrop: "#f85149", qPreempt: "#d29922",
  track: "#a371f7", lyric: "#6e7681",
  error: "#f85149", bound: "#8b949e",
  axis: "#30363d", axisText: "#8b949e", laneLabel: "#484f58",
  laneLine: "#1b212a", select: "#58a6ff"
};

// --- layout -----------------------------------------------------------
var STRIP_H = 18;
var LANES = [
  { key: "voice", label: "VOICE", h: 64 },
  { key: "gen", label: "GEN", h: 48 },
  { key: "director", label: "DIRECTOR", h: 34 },
  { key: "queue", label: "QUEUE", h: 30 },
  { key: "music", label: "MUSIC", h: 36 }
];
var AXIS_H = 24;
function laneTop(idx) {
  var y = STRIP_H;
  for (var i = 0; i < idx; i++) y += LANES[i].h;
  return y;
}
var TOTAL_H = laneTop(LANES.length) + AXIS_H;

// --- state ------------------------------------------------------------
var state = {
  runs: [], runId: null, events: [], dur: 60,
  t0: 0, t1: 60, selected: -1,
  directorIntervals: []
};
var svg = document.getElementById("tl");
var wrap = document.getElementById("tlwrap");
var audio = new Audio();

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function fmtT(t) {
  var neg = t < 0 ? "-" : "";
  t = Math.abs(t);
  var m = Math.floor(t / 60), s = t - m * 60;
  var span = state.t1 - state.t0;
  var ss = span < 20 ? s.toFixed(1) : String(Math.round(s));
  if (Number(ss) < 10) ss = "0" + ss;
  return neg + m + ":" + ss;
}
function fmtDur(sec) {
  if (sec == null || isNaN(sec)) return null;
  var m = Math.floor(sec / 60), s = Math.round(sec - m * 60);
  return m + "m" + (s < 10 ? "0" : "") + s + "s";
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
  if (state.runs.length === 0) {
    nav.innerHTML = '<div class="empty">No runs yet.</div>';
    return;
  }
  state.runs.forEach(function (run) {
    var row = document.createElement("div");
    row.className = "run-row" + (run.run_id === state.runId ? " active" : "");
    var d = new Date(run.started_at);
    var dateStr = isNaN(d.getTime()) ? String(run.started_at)
      : d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + " " +
        d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    var meta = metaObj(run.meta);
    var durS = meta.duration_s != null ? Number(meta.duration_s)
      : (meta.duration != null ? Number(meta.duration) : null);
    var bits = [];
    var fd = fmtDur(durS);
    if (fd) bits.push(fd);
    bits.push(run.event_count + " events");
    row.innerHTML = '<div class="date">' + esc(dateStr) + '</div>' +
      '<div class="sub">' + esc(bits.join(" \\u00b7 ")) + "</div>";
    row.addEventListener("click", function () { selectRun(run.run_id); });
    nav.appendChild(row);
  });
}

// --- run selection + event normalization -------------------------------
function selectRun(id) {
  state.runId = id;
  state.selected = -1;
  renderRuns();
  document.getElementById("runlabel").textContent = "run " + id + " (loading\\u2026)";
  fetch("/api/runs/" + encodeURIComponent(id) + "/events").then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }).then(function (events) {
    if (state.runId !== id) return; // user clicked elsewhere meanwhile
    events = Array.isArray(events) ? events : [];
    events.sort(function (a, b) { return (a.t || 0) - (b.t || 0); });
    var maxT = events.length ? Number(events[events.length - 1].t) || 0 : 0;
    if (maxT > 21600) { // heuristic: t in milliseconds -> convert to seconds
      events.forEach(function (ev) { ev.t = Number(ev.t) / 1000; });
      maxT = maxT / 1000;
    }
    state.events = events;
    var run = null;
    state.runs.forEach(function (r2) { if (r2.run_id === id) run = r2; });
    var meta = run ? metaObj(run.meta) : {};
    var metaDur = meta.duration_s != null ? Number(meta.duration_s)
      : (meta.duration != null ? Number(meta.duration) : NaN);
    state.dur = Math.max(maxT, isNaN(metaDur) ? 0 : metaDur, 10);
    state.t0 = 0; state.t1 = state.dur;
    buildDirectorIntervals();
    document.getElementById("runlabel").textContent =
      "run " + id + " \\u00b7 " + events.length + " events \\u00b7 " + (fmtDur(state.dur) || "");
    document.getElementById("tlempty").style.display = events.length ? "none" : "flex";
    document.getElementById("tlempty").textContent = events.length ? "" : "No events in this run";
    scheduleRender();
  }).catch(function (e) {
    document.getElementById("runlabel").textContent = "run " + id + " \\u2014 failed: " + e.message;
  });
}

// director.protect / director.room are treated as state toggles: each one
// opens an interval that the next director.* event (or run end) closes.
// If the event carries data.ms, that wins as an explicit duration.
function buildDirectorIntervals() {
  var out = [], open = null;
  state.events.forEach(function (ev) {
    if (ev.type !== "director.protect" && ev.type !== "director.room") return;
    var t = Number(ev.t) || 0;
    if (open) { open.end = t; out.push(open); open = null; }
    var kind = ev.type === "director.protect" ? "protect" : "room";
    var ms = ev.data && ev.data.ms != null ? Number(ev.data.ms) : NaN;
    if (!isNaN(ms) && ms > 0) {
      out.push({ kind: kind, start: t, end: t + ms / 1000, ev: ev });
    } else {
      open = { kind: kind, start: t, end: state.dur, ev: ev };
    }
  });
  if (open) out.push(open);
  state.directorIntervals = out;
}

// --- svg helpers --------------------------------------------------------
function el(name, attrs) {
  var node = document.createElementNS(SVG_NS, name);
  for (var k in attrs) node.setAttribute(k, attrs[k]);
  return node;
}
function withTitle(node, text) {
  var t = document.createElementNS(SVG_NS, "title");
  t.textContent = text;
  node.appendChild(t);
  return node;
}
function clickable(node, idx) {
  node.style.cursor = "pointer";
  node.addEventListener("click", function (e) {
    e.stopPropagation();
    select(idx);
  });
  return node;
}

// --- timeline rendering --------------------------------------------------
var renderQueued = false;
function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(function () { renderQueued = false; render(); });
}

function render() {
  var W = wrap.clientWidth || 600;
  var H = Math.max(wrap.clientHeight || TOTAL_H, TOTAL_H);
  svg.setAttribute("viewBox", "0 0 " + W + " " + H);
  while (svg.firstChild) svg.removeChild(svg.firstChild);
  var span = state.t1 - state.t0;
  if (span <= 0) span = 1;
  function x(t) { return (t - state.t0) / span * W; }
  var axisY = H - AXIS_H;

  // lane backgrounds + labels
  LANES.forEach(function (lane, i) {
    var y = laneTop(i);
    svg.appendChild(el("line", { x1: 0, y1: y, x2: W, y2: y, stroke: C.laneLine }));
    var label = el("text", { x: 6, y: y + 12, fill: C.laneLabel, "font-size": 9,
      "letter-spacing": "1", "pointer-events": "none" });
    label.textContent = lane.label;
    svg.appendChild(label);
  });
  svg.appendChild(el("line", { x1: 0, y1: axisY, x2: W, y2: axisY, stroke: C.axis }));

  // time axis ticks
  var steps = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600];
  var step = steps[steps.length - 1];
  for (var si = 0; si < steps.length; si++) {
    if (span / steps[si] <= 12) { step = steps[si]; break; }
  }
  var t = Math.ceil(state.t0 / step) * step;
  for (; t <= state.t1; t += step) {
    var tx = x(t);
    svg.appendChild(el("line", { x1: tx, y1: 0, x2: tx, y2: axisY, stroke: C.axis, "stroke-opacity": 0.35 }));
    var lbl = el("text", { x: tx + 3, y: axisY + 15, fill: C.axisText, "font-size": 10 });
    lbl.textContent = fmtT(t);
    svg.appendChild(lbl);
  }

  // director bands (drawn before pills so they sit behind)
  var dLaneIdx = 2, dy = laneTop(dLaneIdx), dh = LANES[dLaneIdx].h;
  state.directorIntervals.forEach(function (iv) {
    if (iv.end < state.t0 || iv.start > state.t1) return;
    var x0 = Math.max(x(iv.start), 0), x1 = Math.min(x(iv.end), W);
    var idx = state.events.indexOf(iv.ev);
    var fill = iv.kind === "protect" ? C.protect : C.room;
    var edge = iv.kind === "protect" ? C.protectEdge : C.roomEdge;
    var band = el("rect", { x: x0, y: dy + 4, width: Math.max(x1 - x0, 2), height: dh - 8,
      fill: fill, stroke: edge, "stroke-width": state.selected === idx ? 1.5 : 0.5,
      "stroke-opacity": state.selected === idx ? 1 : 0.6, rx: 2 });
    if (state.selected === idx) band.setAttribute("stroke", C.select);
    withTitle(band, "director." + iv.kind + " " + fmtT(iv.start) + " \\u2192 " + fmtT(iv.end));
    clickable(band, idx);
    svg.appendChild(band);
  });

  // events
  state.events.forEach(function (ev, idx) {
    var et = Number(ev.t) || 0;
    var type = String(ev.type || "");
    var data = ev.data || {};
    var sel = state.selected === idx;

    // run boundaries: full height
    if (type === "run.start" || type === "run.end") {
      if (et < state.t0 || et > state.t1) return;
      var bx = x(et);
      var line = el("line", { x1: bx, y1: 0, x2: bx, y2: axisY, stroke: sel ? C.select : C.bound,
        "stroke-dasharray": "4 3", "stroke-width": sel ? 2 : 1 });
      withTitle(line, type + " @ " + fmtT(et));
      clickable(line, idx);
      svg.appendChild(line);
      var bl = el("text", { x: bx + 3, y: 12, fill: C.bound, "font-size": 9, "pointer-events": "none" });
      bl.textContent = type === "run.start" ? "start" : "end";
      svg.appendChild(bl);
      return;
    }

    // error strip
    if (type === "error") {
      if (et < state.t0 || et > state.t1) return;
      var ex = x(et), eyc = STRIP_H / 2;
      var dia = el("path", {
        d: "M" + ex + " " + (eyc - 6) + "L" + (ex + 6) + " " + eyc + "L" + ex + " " + (eyc + 6) +
           "L" + (ex - 6) + " " + eyc + "Z",
        fill: C.error, stroke: sel ? C.select : "none", "stroke-width": 1.5
      });
      withTitle(dia, "error @ " + fmtT(et) + (ev.detail ? ": " + ev.detail : ""));
      clickable(dia, idx);
      svg.appendChild(dia);
      return;
    }

    if (type === "speech") {
      var vIdx = 0, vy = laneTop(vIdx);
      var text = String(ev.detail || "");
      var estDur = Math.max(text.length / 15, 0.8); // ~15 chars/sec speech
      if (et + estDur < state.t0 || et > state.t1) return;
      var px = x(et), pw = Math.max(x(et + estDur) - px, 8);
      var voice = String(data.voice || "");
      var fill = voice === "ricky" ? C.ricky : voice === "jessica" ? C.jessica : C.voiceOther;
      var pill = el("rect", { x: px, y: vy + 16, width: pw, height: 22, rx: 6,
        fill: fill, "fill-opacity": 0.85,
        stroke: sel ? C.select : "none", "stroke-width": 2 });
      withTitle(pill, voice + " @ " + fmtT(et) + ": " + text);
      clickable(pill, idx);
      svg.appendChild(pill);
      if (pw > 40) {
        var maxChars = Math.floor((pw - 8) / 5.6);
        var snippet = text.length > maxChars ? text.slice(0, Math.max(maxChars - 1, 1)) + "\\u2026" : text;
        var tn = el("text", { x: px + 4, y: vy + 31, fill: "#0e1116", "font-size": 10,
          "pointer-events": "none" });
        tn.textContent = snippet;
        svg.appendChild(tn);
      }
      return;
    }

    if (type.indexOf("tts.") === 0) {
      if (et < state.t0 || et > state.t1) return;
      var ty = laneTop(0) + 46;
      var color = type === "tts.play" ? C.ttsPlay : type === "tts.fallback" ? C.ttsFallback : C.ttsFetch;
      var mark = el("rect", { x: x(et) - 2, y: ty, width: 4, height: 10,
        fill: color, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
      var bits = [type, "@ " + fmtT(et)];
      if (data.ms != null) bits.push(data.ms + "ms");
      if (data.backend) bits.push(String(data.backend));
      if (data.reason) bits.push(String(data.reason));
      withTitle(mark, bits.join(" "));
      clickable(mark, idx);
      svg.appendChild(mark);
      return;
    }

    if (type.indexOf("gen.") === 0) {
      var gy = laneTop(1);
      var ms = data.ms != null ? Number(data.ms) : NaN;
      var gDur = !isNaN(ms) && ms > 0 ? ms / 1000 : 0.5;
      if (et + gDur < state.t0 || et > state.t1) return;
      var gx = x(et), gw = Math.max(x(et + gDur) - gx, 5);
      var gFill = type === "gen.error" ? C.genErr : type === "gen.response" ? C.genResp : C.genReq;
      var gOp = type === "gen.request" ? 0.45 : 0.9;
      var gp = el("rect", { x: gx, y: gy + 14, width: gw, height: 18, rx: 4,
        fill: gFill, "fill-opacity": gOp,
        stroke: sel ? C.select : "none", "stroke-width": 2 });
      var glabel = type + (data.endpoint ? " " + data.endpoint : "") + " @ " + fmtT(et) +
        (!isNaN(ms) ? " \\u00b7 " + ms + "ms" : "");
      withTitle(gp, glabel);
      clickable(gp, idx);
      svg.appendChild(gp);
      if (gw > 50 && !isNaN(ms)) {
        var gt = el("text", { x: gx + 4, y: gy + 27, fill: "#e6edf3", "font-size": 9,
          "pointer-events": "none" });
        gt.textContent = ms + "ms";
        svg.appendChild(gt);
      }
      return;
    }

    if (type.indexOf("queue.") === 0) {
      if (et < state.t0 || et > state.t1) return;
      var qy = laneTop(3);
      var qColor = type === "queue.drop" ? C.qDrop : type === "queue.preempt" ? C.qPreempt : C.qEnqueue;
      var qh = type === "queue.enqueue" ? 8 : 16;
      var tick = el("rect", { x: x(et) - 1.5, y: qy + (LANES[3].h - qh) / 2, width: 3, height: qh,
        fill: qColor, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
      withTitle(tick, type + " @ " + fmtT(et) + (ev.detail ? ": " + ev.detail : ""));
      clickable(tick, idx);
      svg.appendChild(tick);
      return;
    }

    if (type.indexOf("music.") === 0) {
      if (et < state.t0 || et > state.t1) return;
      var my = laneTop(4);
      var isTrack = type === "music.track";
      var mc = el("circle", { cx: x(et), cy: my + LANES[4].h / 2, r: isTrack ? 5 : 3,
        fill: isTrack ? C.track : C.lyric,
        stroke: sel ? C.select : "none", "stroke-width": 1.5 });
      withTitle(mc, type + " @ " + fmtT(et) + (ev.detail ? ": " + ev.detail : ""));
      clickable(mc, idx);
      svg.appendChild(mc);
      if (isTrack && ev.detail) {
        var mt = el("text", { x: x(et) + 8, y: my + LANES[4].h / 2 + 3, fill: C.track,
          "font-size": 9, "pointer-events": "none" });
        mt.textContent = String(ev.detail).slice(0, 30);
        svg.appendChild(mt);
      }
      return;
    }

    // unknown event types: faint tick in the queue lane region (bottom)
    if (type === "director.protect" || type === "director.room") return; // drawn as bands
    if (et < state.t0 || et > state.t1) return;
    var uy = axisY - 8;
    var ut = el("rect", { x: x(et) - 1, y: uy, width: 2, height: 6, fill: "#30363d",
      stroke: sel ? C.select : "none" });
    withTitle(ut, type + " @ " + fmtT(et));
    clickable(ut, idx);
    svg.appendChild(ut);
  });
}

// --- selection + detail panel ---------------------------------------------
function select(idx) {
  state.selected = idx;
  var ev = state.events[idx];
  scheduleRender();
  if (!ev) return;
  document.getElementById("dhead").textContent =
    ev.type + (ev.detail ? " \\u2014 " + ev.detail : "");
  var wall = ev.wall ? " \\u00b7 " + ev.wall : "";
  document.getElementById("dtime").textContent = "t=" + fmtT(Number(ev.t) || 0) + wall;
  document.getElementById("djson").textContent = JSON.stringify(ev, null, 2);
  var playBtn = document.getElementById("dplay");
  var canPlay = ev.type === "speech" && ev.data && ev.data.cacheKey;
  playBtn.style.display = canPlay ? "inline-block" : "none";
  document.getElementById("daudiostatus").textContent = "";
  if (canPlay) playSpeech(ev); // click-to-play: selecting a speech pill plays it
}
function playSpeech(ev) {
  var statusEl = document.getElementById("daudiostatus");
  var url = "/api/runs/" + encodeURIComponent(state.runId) + "/audio/" +
    encodeURIComponent(ev.data.cacheKey);
  audio.pause();
  audio.src = url;
  statusEl.textContent = "loading audio\\u2026";
  audio.play().then(function () {
    statusEl.textContent = "playing (" + String(ev.data.voice || "?") + ")";
  }).catch(function () {
    // 503 until R2 audio archive is enabled, or decode failure
    fetch(url, { method: "HEAD" }).then(function (r) {
      statusEl.textContent = r.status === 503
        ? "audio archive not enabled yet (503)"
        : "audio unavailable (HTTP " + r.status + ")";
    }).catch(function () { statusEl.textContent = "audio unavailable"; });
  });
}
document.getElementById("dplay").addEventListener("click", function () {
  var ev = state.events[state.selected];
  if (ev) playSpeech(ev);
});

// --- zoom + pan -------------------------------------------------------------
wrap.addEventListener("wheel", function (e) {
  if (!state.events.length) return;
  e.preventDefault();
  var W = wrap.clientWidth || 600;
  var span = state.t1 - state.t0;
  var factor = e.deltaY > 0 ? 1.25 : 0.8;
  var newSpan = Math.min(Math.max(span * factor, 0.5), state.dur * 1.1);
  var pivot = state.t0 + (e.offsetX / W) * span;
  var frac = span > 0 ? (pivot - state.t0) / span : 0.5;
  state.t0 = pivot - frac * newSpan;
  state.t1 = state.t0 + newSpan;
  clampView();
  scheduleRender();
}, { passive: false });

var pan = null;
svg.addEventListener("pointerdown", function (e) {
  if (!state.events.length) return;
  pan = { x: e.clientX, t0: state.t0, t1: state.t1 };
  svg.classList.add("panning");
  svg.setPointerCapture(e.pointerId);
});
svg.addEventListener("pointermove", function (e) {
  if (!pan) return;
  var W = wrap.clientWidth || 600;
  var dt = (pan.x - e.clientX) / W * (pan.t1 - pan.t0);
  state.t0 = pan.t0 + dt;
  state.t1 = pan.t1 + dt;
  clampView();
  scheduleRender();
});
svg.addEventListener("pointerup", function () { pan = null; svg.classList.remove("panning"); });
svg.addEventListener("pointercancel", function () { pan = null; svg.classList.remove("panning"); });

function clampView() {
  var span = state.t1 - state.t0;
  var lo = -state.dur * 0.05, hi = state.dur * 1.05;
  if (state.t0 < lo) { state.t0 = lo; state.t1 = lo + span; }
  if (state.t1 > hi) { state.t1 = hi; state.t0 = hi - span; }
}

window.addEventListener("resize", scheduleRender);
loadRuns();
</script>
</body>
</html>
`;
