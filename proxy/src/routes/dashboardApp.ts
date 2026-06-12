/// Dashboard app shell for GET /dash with a valid session cookie.
/// Self-contained: inline CSS, inline vanilla JS + SVG, zero CDN deps.
///
/// REDESIGN (master-axis lanes + Control Room + Recycle Bin). Layout:
///   - left rail: runs list with inline pace/HR SPARKLINES + health dot + bin
///   - filmstrip header: KPI cards w/ word-size sparklines + radial gauges
///   - VIEW TABS: Performance | Control Room | Recycle Bin
///   - Performance: dual-series speed+HR hero chart, event swim-lanes incl.
///       the NETWORK lane, voice-density heat strip, net.req REQUEST WATERFALL,
///       shared crosshair, time/distance x-toggle, zoom/pan. Audio player +
///       filterable telemetry log + right detail panel kept and coupled.
///   - Control Room: network inspector (svc/phase/ms/bytes, newest first, with
///       11Labs p50/p95 + fail count), run-progress readout, voice-queue/
///       director/coach activity summary, full event tail.
///   - Recycle Bin: GET /api/runs/deleted listing w/ Restore + Delete-Forever;
///       active runs get a delete affordance that moves them to the bin.
///
/// Data contract (sibling data-API agent, ingestRun.ts):
///   GET  /api/runs                 -> [{run_id, started_at, event_count, meta}]
///   GET  /api/runs/:id/events      -> [{t, wall, type, detail, data}]
///   GET  /api/runs/:id/audio/:key  -> mp3 | 404 (not archived) | 503 (R2 off)
///   GET  /api/runs/deleted         -> [{run_id, started_at, event_count, meta, deleted_at?}]
///   POST /api/runs/:id/delete      -> move active run to bin
///   POST /api/runs/:id/restore     -> restore from bin
///   POST /api/runs/:id/purge       -> delete forever
/// (delete/restore/purge are added by a sibling agent; UI degrades if absent.)
///
/// "metrics" event: t = seconds since run start.
///   data = {d:distM, p:paceSecPerKm(""?), hr:bpm(""?), v:speedMps(""?)} (strings).
/// speech event: data = {voiceId, source, cacheKey}; voiceId picks the colour.
/// net.req event: data = {svc:"11Labs"|"LLM", phase:"received"|"failed"|"cached",
///   ms, bytes, chars, info} -> the network inspector / waterfall.
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
    --green: #3fb950; --amber: #d29922; --select: #58a6ff; --llm: #39c5cf;
    --radius: 8px;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body {
    font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); overflow: hidden;
  }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }

  header {
    height: 46px; display: flex; align-items: center; gap: 12px;
    padding: 0 14px; background: var(--panel); border-bottom: 1px solid var(--line);
  }
  header h1 { font-size: 14px; font-weight: 700; color: var(--textHi); letter-spacing: .02em; }
  header h1 .dot { color: var(--green); }
  header .runlabel { color: var(--textDim); font-size: 12px; }
  header .spacer { flex: 1; }
  header .hint { color: var(--textFaint); font-size: 11px; }

  /* view tabs */
  .tabs { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
  .tabs button {
    background: var(--panel2); color: var(--textDim); border: 0; padding: 6px 14px;
    font: 600 11px/1 inherit; cursor: pointer; transition: background .12s, color .12s;
  }
  .tabs button.on { background: #1c2632; color: var(--textHi); }
  .tabs button + button { border-left: 1px solid var(--line); }
  .tabs button .badge {
    display: inline-block; min-width: 15px; padding: 0 4px; margin-left: 5px;
    border-radius: 8px; background: var(--hr); color: #0b0e13; font-size: 10px; font-weight: 700;
  }

  .xtoggle { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
  .xtoggle button {
    background: var(--panel2); color: var(--textDim); border: 0; padding: 5px 10px;
    font: 600 11px/1 inherit; cursor: pointer;
  }
  .xtoggle button.on { background: #1c2632; color: var(--textHi); }
  .xtoggle button + button { border-left: 1px solid var(--line); }
  .dbgtoggle { display: inline-flex; align-items: center; gap: 5px; color: var(--textDim);
    font: 600 11px/1 inherit; cursor: pointer; user-select: none; }
  .dbgtoggle input { accent-color: var(--select); cursor: pointer; }

  #layout { display: flex; height: calc(100% - 46px); }

  /* left rail: runs */
  #runs {
    width: 252px; min-width: 252px; overflow-y: auto;
    background: var(--panel); border-right: 1px solid var(--line);
  }
  .run-row { padding: 9px 12px; border-bottom: 1px solid var(--line2); cursor: pointer; position: relative; }
  .run-row:hover { background: #161d27; }
  .run-row.active { background: #1c2632; box-shadow: inset 3px 0 0 var(--select); }
  .run-row .toprow { display: flex; align-items: center; gap: 7px; }
  .run-row .hdot { width: 7px; height: 7px; border-radius: 50%; flex: 0 0 7px; background: var(--green); }
  .run-row .hdot.bad { background: var(--hr); box-shadow: 0 0 5px rgba(248,81,73,.7); }
  .run-row .date { color: var(--textHi); font-weight: 600; font-size: 12px; flex: 1;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .run-row .spark { display: block; margin: 5px 0 3px; }
  .run-row .sub { color: var(--textDim); font-size: 11px; display: flex; gap: 8px; flex-wrap: wrap; }
  .run-row .sub b { color: #adbac7; font-weight: 600; }
  .run-row .del {
    position: absolute; top: 6px; right: 6px; width: 18px; height: 18px; border: 0;
    border-radius: 4px; background: transparent; color: var(--textFaint); cursor: pointer;
    font-size: 13px; line-height: 1; display: none; align-items: center; justify-content: center;
  }
  .run-row:hover .del { display: inline-flex; }
  .run-row .del:hover { background: rgba(248,81,73,.18); color: #ffb4ae; }
  #runs .empty { padding: 16px 12px; color: var(--textDim); font-size: 12px; }

  /* center column */
  #center { flex: 1; display: flex; flex-direction: column; min-width: 0; }

  /* filmstrip KPI header */
  #film {
    display: flex; gap: 10px; padding: 10px 14px; background: var(--panel);
    border-bottom: 1px solid var(--line); align-items: stretch; overflow-x: auto;
  }
  .kpi {
    flex: 1 1 0; min-width: 92px; background: var(--panel2); border: 1px solid var(--line);
    border-radius: var(--radius); padding: 8px 10px; display: flex; flex-direction: column; gap: 2px;
  }
  .kpi .k { color: var(--textFaint); font-size: 9px; text-transform: uppercase; letter-spacing: .06em; }
  .kpi .v { color: var(--textHi); font-size: 17px; font-weight: 700; font-variant-numeric: tabular-nums; line-height: 1.1; }
  .kpi .v small { font-size: 11px; font-weight: 600; color: var(--textDim); }
  .kpi svg { display: block; margin-top: auto; }
  .gauges { display: flex; gap: 8px; flex: 0 0 auto; }
  .gauge {
    width: 78px; background: var(--panel2); border: 1px solid var(--line); border-radius: var(--radius);
    padding: 6px; display: flex; flex-direction: column; align-items: center; gap: 2px;
  }
  .gauge .gk { color: var(--textFaint); font-size: 8.5px; text-transform: uppercase; letter-spacing: .04em; text-align: center; }
  .gauge text.gv { font-weight: 700; }

  /* performance / control / bin panes */
  .pane { display: none; flex: 1; min-height: 0; flex-direction: column; }
  .pane.on { display: flex; }

  /* hero chart + lanes */
  #chartwrap { position: relative; border-bottom: 1px solid var(--line); background: var(--panel2); }
  #chart { display: block; width: 100%; cursor: grab; touch-action: none; }
  #chart.panning { cursor: grabbing; }
  #chartempty {
    position: absolute; inset: 0; display: flex; align-items: center;
    justify-content: center; color: var(--textFaint); font-size: 13px; pointer-events: none;
  }
  .legend {
    position: absolute; top: 7px; left: 50%; transform: translateX(-50%); display: flex; gap: 13px; flex-wrap: wrap;
    justify-content: center; font-size: 11px; color: var(--textDim); pointer-events: none; max-width: 64%;
  }
  .legend span { display: inline-flex; align-items: center; gap: 5px; }
  body:not(.debug-on) .legend .dbgonly { display: none; }
  .legend i { width: 11px; height: 11px; border-radius: 2px; display: inline-block; }
  .crosspill {
    position: absolute; top: 4px; left: 50px; pointer-events: none; display: none;
    background: rgba(13,17,23,.92); border: 1px solid var(--line); border-radius: 5px;
    padding: 3px 7px; font: 600 11px/1.3 ui-monospace, Menlo, monospace; color: var(--textHi);
    white-space: nowrap; z-index: 3;
  }
  .crosspill b { color: var(--speed); } .crosspill .h { color: var(--hr); }
  .voicetip {
    position: absolute; pointer-events: none; display: none; z-index: 5;
    max-width: 340px; background: rgba(13,17,23,.97); border: 1px solid var(--line);
    border-radius: 6px; padding: 7px 10px; font: 12px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--textHi); box-shadow: 0 6px 22px rgba(0,0,0,.5); white-space: normal; word-break: break-word;
  }
  .voicetip .vt-h { font: 600 10px/1 ui-monospace, Menlo, monospace; letter-spacing: .04em; color: var(--textDim); margin-bottom: 5px; text-transform: uppercase; }

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
  #ptext { color: var(--textHi); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
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
  table.log { width: 100%; border-collapse: collapse; font-size: 12px; table-layout: fixed; }
  table.log col.col-t { width: 52px; }
  table.log col.col-type { width: 116px; }
  table.log col.col-data { width: 188px; }
  table.log th {
    position: sticky; top: 0; background: var(--panel); color: var(--textFaint);
    font-weight: 600; text-align: left; padding: 5px 10px; border-bottom: 1px solid var(--line);
    font-size: 10px; text-transform: uppercase; letter-spacing: .05em; z-index: 1;
  }
  table.log td { padding: 5px 10px; border-bottom: 1px solid var(--line2); vertical-align: top; }
  table.log tr { cursor: pointer; }
  table.log tr:hover { background: #161d27; }
  table.log tr.sel { background: #1c2632; box-shadow: inset 3px 0 0 var(--select); }
  table.log tr.flash { animation: flashrow .9s ease-out; }
  @keyframes flashrow { 0% { background: #243447; } 100% { background: transparent; } }
  table.log tr.err td { color: #ffb4ae; }
  table.log tr.err td.c-type { color: #ff7b72; font-weight: 600; }
  td.c-t { color: var(--textDim); font-variant-numeric: tabular-nums; white-space: nowrap; }
  td.c-type { color: #adbac7; white-space: nowrap; font-weight: 500; overflow: hidden; text-overflow: ellipsis; }
  td.c-detail { color: var(--text); white-space: normal; overflow-wrap: anywhere; word-break: normal; line-height: 1.5; }
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
  #dhead { font-size: 13px; color: var(--textHi); font-weight: 600; margin-bottom: 2px; word-break: break-word; }
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
  #dstats .row { display: flex; justify-content: space-between; padding: 3px 0; border-bottom: 1px solid var(--line2); }
  #dstats .row span:first-child { color: var(--textDim); }
  #dstats .row span:last-child { color: var(--textHi); font-variant-numeric: tabular-nums; }

  /* ---- Control Room pane ---- */
  #control { overflow-y: auto; padding: 14px; gap: 14px; }
  .cr-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 14px; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius); overflow: hidden; }
  .card > h3 {
    font-size: 11px; color: var(--textFaint); text-transform: uppercase; letter-spacing: .06em;
    padding: 9px 12px; border-bottom: 1px solid var(--line); display: flex; align-items: center; gap: 8px;
  }
  .card > h3 .tag { margin-left: auto; font-size: 10px; padding: 1px 7px; border-radius: 8px;
    background: #1c2632; color: var(--textDim); letter-spacing: 0; text-transform: none; }
  .card .body { padding: 10px 12px; }
  .statgrid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .stat { background: var(--panel2); border: 1px solid var(--line2); border-radius: 6px; padding: 7px 9px; }
  .stat .sk { color: var(--textFaint); font-size: 9px; text-transform: uppercase; letter-spacing: .05em; }
  .stat .sv { color: var(--textHi); font-size: 16px; font-weight: 700; font-variant-numeric: tabular-nums; }
  .stat .sv.bad { color: #ff7b72; } .stat .sv.good { color: var(--green); }
  .progress { height: 8px; border-radius: 4px; background: var(--panel2); overflow: hidden; border: 1px solid var(--line2); }
  .progress > i { display: block; height: 100%; background: linear-gradient(90deg, var(--speed), var(--llm)); transition: width .4s; }
  /* network inspector table */
  table.net { width: 100%; border-collapse: collapse; font-size: 11.5px; }
  table.net th { text-align: left; color: var(--textFaint); font-weight: 600; font-size: 9.5px;
    text-transform: uppercase; letter-spacing: .04em; padding: 4px 8px; border-bottom: 1px solid var(--line); position: sticky; top: 0; background: var(--panel); }
  table.net td { padding: 4px 8px; border-bottom: 1px solid var(--line2); white-space: nowrap; font-variant-numeric: tabular-nums; }
  table.net tr:hover { background: #161d27; cursor: pointer; }
  .svc { display: inline-block; padding: 0 6px; border-radius: 7px; font-size: 10px; font-weight: 700; color: #0b0e13; }
  .ph { font-weight: 600; } .ph.received { color: var(--green); } .ph.failed { color: #ff7b72; } .ph.cached { color: var(--textDim); }
  .net-scroll { max-height: 280px; overflow-y: auto; }
  .actline { display: flex; align-items: center; gap: 8px; padding: 4px 0; border-bottom: 1px solid var(--line2); font-size: 12px; }
  .actline:last-child { border-bottom: 0; }
  .actline .an { color: var(--text); flex: 1; } .actline .ac { color: var(--textHi); font-weight: 700; font-variant-numeric: tabular-nums; }
  .actline .ab { width: 5px; height: 5px; border-radius: 50%; }
  .tail { max-height: 320px; overflow-y: auto; font: 11.5px/1.5 ui-monospace, Menlo, monospace; }
  .tail .tl { display: flex; gap: 8px; padding: 2px 0; border-bottom: 1px solid var(--line2); }
  .tail .tl .tt { color: var(--textFaint); flex: 0 0 46px; text-align: right; }
  .tail .tl .ty { color: #79c0ff; flex: 0 0 118px; overflow: hidden; text-overflow: ellipsis; }
  .tail .tl .td { color: var(--textDim); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tail .tl.err .ty { color: #ff7b72; }

  /* ---- Recycle Bin pane ---- */
  #bin { overflow-y: auto; padding: 18px; }
  #bin .binhead { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
  #bin .binhead h2 { font-size: 15px; color: var(--textHi); }
  #bin .binhead p { color: var(--textDim); font-size: 12px; }
  .bincard {
    display: flex; align-items: center; gap: 14px; background: var(--panel); border: 1px solid var(--line);
    border-radius: var(--radius); padding: 12px 14px; margin-bottom: 10px;
  }
  .bincard .bmeta { flex: 1; min-width: 0; }
  .bincard .bdate { color: var(--textHi); font-weight: 600; }
  .bincard .bsub { color: var(--textDim); font-size: 12px; margin-top: 2px; }
  .bincard button {
    border: 1px solid var(--line); background: var(--panel2); color: var(--text);
    border-radius: 6px; padding: 7px 13px; font: 600 12px/1 inherit; cursor: pointer; transition: filter .12s;
  }
  .bincard button:hover { filter: brightness(1.25); }
  .bincard .restore { border-color: #2ea043; color: var(--green); }
  .bincard .purge { border-color: #6e2b28; color: #ff7b72; }
  #bin .empty { color: var(--textDim); padding: 40px; text-align: center; border: 1px dashed var(--line); border-radius: var(--radius); }

  .toast {
    position: fixed; bottom: 18px; left: 50%; transform: translateX(-50%) translateY(8px);
    background: #1c2632; border: 1px solid var(--line); color: var(--textHi); padding: 9px 16px;
    border-radius: 8px; font-size: 12px; opacity: 0; pointer-events: none; transition: opacity .2s, transform .2s; z-index: 50;
  }
  .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
  .fade-in { animation: fadeIn .35s ease-out both; }
  @keyframes fadeIn { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
  text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
</style>
</head>
<body>
<header>
  <h1><span class="dot">&#9679;</span> AARC dash</h1>
  <span class="runlabel" id="runlabel">no run selected</span>
  <span class="spacer"></span>
  <span class="tabs" id="tabs">
    <button data-tab="perf" class="on">Performance</button>
    <button data-tab="control">Control Room</button>
    <button data-tab="bin">Recycle Bin <span class="badge" id="binbadge" style="display:none">0</span></button>
  </span>
  <span class="xtoggle" id="xtoggle">
    <button data-x="time" class="on">Time</button>
    <button data-x="dist">Distance</button>
  </span>
  <label class="dbgtoggle" id="dbgtoggle" title="Show network + pipeline diagnostics lanes">
    <input type="checkbox" id="dbgchk"> Debug
  </label>
  <span class="hint">wheel = zoom &middot; drag = pan</span>
</header>
<div id="layout">
  <nav id="runs"><div class="empty">Loading runs&hellip;</div></nav>
  <main id="center">
    <div id="film"></div>

    <!-- ============ PERFORMANCE PANE ============ -->
    <section class="pane on" id="perf">
      <div id="chartwrap">
        <svg id="chart" xmlns="http://www.w3.org/2000/svg"></svg>
        <div class="legend">
          <span><i style="background:var(--speed)"></i>speed</span>
          <span><i style="background:var(--hr)"></i>HR</span>
          <span><i style="background:var(--jessica)"></i>jessica</span>
          <span><i style="background:var(--ricky)"></i>ricky</span>
          <span class="dbgonly"><i style="background:var(--amber)"></i>11Labs</span>
          <span class="dbgonly"><i style="background:var(--llm)"></i>LLM</span>
        </div>
        <div class="crosspill" id="crosspill"></div>
        <div class="voicetip" id="voicetip"></div>
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
    </section>

    <!-- ============ CONTROL ROOM PANE ============ -->
    <section class="pane" id="control"></section>

    <!-- ============ RECYCLE BIN PANE ============ -->
    <section class="pane" id="bin"></section>
  </main>
  <aside id="detail">
    <h2>Selected event</h2>
    <div id="dhead">—</div>
    <div id="dtime"></div>
    <button id="dplay">&#9654; Play audio</button>
    <h2 style="margin-top:14px">Run summary</h2>
    <div id="dstats"><div class="row"><span>—</span><span></span></div></div>
    <h2>Raw JSON</h2>
    <pre id="djson">Click an event.</pre>
  </aside>
</div>
<div class="toast" id="toast"></div>
<script>
"use strict";
var SVG_NS = "http://www.w3.org/2000/svg";

var VOICE_RICKY = "lKMAeQD7Brvj7QCWByqK";
var VOICE_JESSICA = "jP5jSWhfXz3nfQENMtf4";

var SPEED_MIN_KMH = 0, SPEED_MAX_KMH = 28;
var HR_MIN = 30, HR_MAX = 220;
var HR_AXIS_MAX = 200;

var C = {
  speed: "#58a6ff", hr: "#f85149", ricky: "#e8a13a", jessica: "#ef6da8",
  voiceOther: "#8b949e",
  protect: "rgba(248,81,73,0.16)", protectEdge: "#f85149",
  prewarm: "#a371f7", coach: "#388bfd", drop: "#f85149", preempt: "#d29922",
  fallback: "#d29922", gen: "#1f6feb", endpoint: "#2ea043",
  bound: "#8b949e", error: "#f85149",
  net11Labs: "#d29922", netLLM: "#39c5cf", netFail: "#f85149", netCached: "#4a6b8a",
  axis: "#21262d", grid: "#1b212a", axisText: "#8b949e", select: "#58a6ff",
  heatJess: "#ef6da8", heatRicky: "#e8a13a"
};

// chart geometry: stacked lanes sharing one x-scale
var PAD_L = 46, PAD_R = 46, PAD_T = 14;
var PLOT_H = 158;          // performance plot (speed area + HR line + glyphs)
var HEAT_H = 50;           // VOICE lane: clickable bars sized to how long each line was spoken (jessica + ricky rows)
var MARK_H = 58;           // event-marker swim lanes
var WF_H = 86;             // net.req request waterfall
var AXIS_H = 22;
var GAP = 8;               // gap between lanes
var MARK_ROWS = 4;         // speech, gen, director, control
var ROW = { speech: 0, gen: 1, director: 2, control: 3 };
var ROW_H = MARK_H / MARK_ROWS;

var state = {
  runs: [], deleted: [], runId: null, events: [], metrics: [],
  xmode: "time", dur: 60, maxDist: 0,
  v0: 0, v1: 60, domain0: 0, domain1: 60,
  selected: -1, directorIntervals: [], summary: null, net: [], pan: null,
  tab: "perf", debug: false
};

var chart = document.getElementById("chart");
var chartWrap = document.getElementById("chartwrap");
var crosspill = document.getElementById("crosspill");
var voicetip = document.getElementById("voicetip");
var audio = new Audio();
var curAudio = null;

function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
function num(v) { var n = Number(v); return isFinite(n) ? n : NaN; }
function has(s) { return s !== undefined && s !== null && String(s).trim() !== ""; }

function fmtClock(sec) {
  var neg = sec < 0 ? "-" : ""; sec = Math.abs(sec);
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
  if (state.xmode === "dist") return v >= 1000 ? (v / 1000).toFixed(v < 10000 ? 2 : 1) + "k" : Math.round(v) + "m";
  return fmtClock(v);
}
function metaObj(meta) {
  if (meta == null) return {};
  if (typeof meta === "object") return meta;
  if (typeof meta === "string") { try { return JSON.parse(meta); } catch (e) { return {}; } }
  return {};
}
function metaDurDist(meta) {
  var durS = has(meta.duration_s) ? num(meta.duration_s) : (has(meta.duration) ? num(meta.duration) : NaN);
  var distM = has(meta.distance_m) ? num(meta.distance_m) : (has(meta.distance) ? num(meta.distance) : NaN);
  return { dur: durS, dist: distM };
}
function toast(msg) {
  var t = document.getElementById("toast");
  t.textContent = msg; t.classList.add("show");
  clearTimeout(t._h); t._h = setTimeout(function () { t.classList.remove("show"); }, 2200);
}

// --- runs list --------------------------------------------------------
function loadRuns(keepSel) {
  return fetch("/api/runs").then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }).then(function (runs) {
    state.runs = Array.isArray(runs) ? runs : [];
    renderRuns();
    if (!keepSel && state.runs.length > 0) selectRun(state.runs[0].run_id);
    else if (keepSel && state.runId && !state.runs.some(function (r) { return r.run_id === state.runId; })) {
      if (state.runs.length > 0) selectRun(state.runs[0].run_id); else clearRun();
    }
  }).catch(function (e) {
    document.getElementById("runs").innerHTML = '<div class="empty">Failed to load runs: ' + esc(e.message) + "</div>";
  });
}

// tiny pace + HR sparkline for a runs-list row (no event fetch: uses meta if
// present, otherwise a flat placeholder; the real per-point spark is built on
// select). Health dot is set later when events load (cached on the run obj).
function rowSpark(run) {
  var W = 132, H = 18;
  var svg = '<svg class="spark" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '">';
  var pts = run._spark;
  if (pts && pts.kmh && pts.kmh.length > 1) {
    svg += sparkPath(pts.kmh, W, H, C.speed, 1.4, 0.7);
    if (pts.hr && pts.hr.length > 1) svg += sparkPath(pts.hr, W, H, C.hr, 1, 0.85);
  } else {
    svg += '<line x1="0" y1="' + (H - 2) + '" x2="' + W + '" y2="' + (H - 2) + '" stroke="' + C.grid + '"/>';
  }
  return svg + "</svg>";
}
function sparkPath(arr, W, H, color, width, op) {
  var min = Infinity, max = -Infinity;
  arr.forEach(function (v) { if (isFinite(v)) { if (v < min) min = v; if (v > max) max = v; } });
  if (!isFinite(min) || max <= min) max = min + 1;
  var d = "", n = arr.length, started = false;
  for (var i = 0; i < n; i++) {
    var v = arr[i]; if (!isFinite(v)) continue;
    var x = (i / (n - 1)) * W;
    var y = (H - 2) - ((v - min) / (max - min)) * (H - 4);
    d += (started ? "L" : "M") + x.toFixed(1) + " " + y.toFixed(1) + " "; started = true;
  }
  if (!d) return "";
  return '<path d="' + d + '" fill="none" stroke="' + color + '" stroke-width="' + width + '" stroke-opacity="' + op + '" stroke-linejoin="round"/>';
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
    var md = metaDurDist(metaObj(run.meta));
    var bits = [];
    var fd = fmtDur(md.dur); if (fd) bits.push("<b>" + esc(fd) + "</b>");
    var fdist = fmtDist(md.dist); if (fdist) bits.push("<b>" + esc(fdist) + "</b>");
    bits.push(esc(run.event_count + " events"));
    var bad = run._health === "bad";
    row.innerHTML =
      '<div class="toprow"><span class="hdot' + (bad ? " bad" : "") + '"></span>' +
      '<span class="date">' + esc(dateStr) + "</span></div>" +
      rowSpark(run) +
      '<div class="sub">' + bits.join(" ") + "</div>" +
      '<button class="del" title="Move to recycle bin">&#10005;</button>';
    row.addEventListener("click", function () { selectRun(run.run_id); });
    row.querySelector(".del").addEventListener("click", function (e) {
      e.stopPropagation(); deleteRun(run.run_id);
    });
    nav.appendChild(row);
  });
}
function clearRun() {
  state.runId = null; state.events = []; state.metrics = []; state.net = [];
  document.getElementById("runlabel").textContent = "no run selected";
  document.getElementById("film").innerHTML = "";
  scheduleRender(); renderLog(); renderControl();
}

// --- run selection + normalization ------------------------------------
function selectRun(id) {
  state.runId = id; state.selected = -1;
  resetAudio(); renderRuns();
  document.getElementById("runlabel").textContent = "run " + id + " (loading\\u2026)";
  fetch("/api/runs/" + encodeURIComponent(id) + "/events").then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }).then(function (events) {
    if (state.runId !== id) return;
    events = Array.isArray(events) ? events : [];
    events.forEach(function (ev) { ev.t = num(ev.t); if (isNaN(ev.t)) ev.t = 0; ev.data = ev.data || {}; });
    events.sort(function (a, b) { return a.t - b.t; });
    var maxT = events.length ? events[events.length - 1].t : 0;
    if (maxT > 21600) { events.forEach(function (ev) { ev.t = ev.t / 1000; }); maxT = maxT / 1000; }
    state.events = events;
    extractMetrics();
    extractNet();
    var run = null;
    state.runs.forEach(function (r2) { if (r2.run_id === id) run = r2; });
    var meta = run ? metaObj(run.meta) : {};
    var metaDur = metaDurDist(meta).dur;
    state.dur = Math.max(maxT, isNaN(metaDur) ? 0 : metaDur, 10);
    state.maxDist = state.metrics.length ? state.metrics[state.metrics.length - 1].d : 0;
    if (!(state.maxDist > 0)) { var md = metaDurDist(meta).dist; if (md > 0) state.maxDist = md; }
    buildDirectorIntervals();
    computeSummary(meta);
    // cache health + spark on the run obj for the list
    if (run) {
      run._health = (state.summary.netFailCt > 0 || state.summary.errCt > 0) ? "bad" : "ok";
      run._spark = { kmh: state.metrics.map(function (m) { return m.kmh; }),
                     hr: state.metrics.map(function (m) { return m.hr; }) };
    }
    setXMode(state.xmode, true);
    document.getElementById("runlabel").textContent =
      "run " + id + " \\u00b7 " + events.length + " events \\u00b7 " + (fmtDur(state.dur) || "");
    var hasData = events.length > 0;
    document.getElementById("chartempty").style.display = hasData ? "none" : "flex";
    document.getElementById("chartempty").textContent = hasData ? "" : "No events in this run";
    renderFilm();
    renderRuns();
    renderLog();
    renderControl();
    scheduleRender();
  }).catch(function (e) {
    document.getElementById("runlabel").textContent = "run " + id + " \\u2014 failed: " + e.message;
  });
}

function extractMetrics() {
  var out = [];
  state.events.forEach(function (ev) {
    if (ev.type !== "metrics") return;
    var d = ev.data || {};
    var dist = num(d.d), speedMps = num(d.v), paceSpk = num(d.p), hr = num(d.hr);
    var kmh = NaN;
    if (isFinite(speedMps) && speedMps >= 0) kmh = speedMps * 3.6;
    else if (isFinite(paceSpk) && paceSpk > 0) kmh = 3600 / paceSpk;
    var rec = {
      t: num(ev.t),
      d: isFinite(dist) && dist >= 0 ? dist : NaN,
      kmh: (isFinite(kmh) && kmh >= SPEED_MIN_KMH && kmh <= SPEED_MAX_KMH) ? kmh : NaN,
      pace: (isFinite(paceSpk) && paceSpk > 0) ? paceSpk : (isFinite(kmh) && kmh > 0 ? 3600 / kmh : NaN),
      hr: (isFinite(hr) && hr >= HR_MIN && hr <= HR_MAX) ? hr : NaN
    };
    if (isNaN(rec.t)) return;
    out.push(rec);
  });
  out.sort(function (a, b) { return a.t - b.t; });
  var lastD = 0;
  out.forEach(function (r) { if (isFinite(r.d)) lastD = r.d; else r.d = lastD; });
  state.metrics = out;
}

// pull net.req events into a structured array for waterfall + inspector.
function extractNet() {
  var out = [];
  state.events.forEach(function (ev, idx) {
    if (ev.type !== "net.req") return;
    var d = ev.data || {};
    out.push({
      idx: idx, t: num(ev.t), wall: ev.wall,
      svc: String(d.svc || ""), phase: String(d.phase || ""),
      ms: num(d.ms), bytes: num(d.bytes), chars: num(d.chars),
      info: String(d.info || ev.detail || "")
    });
  });
  state.net = out;
}

function computeSummary(meta) {
  var m = state.metrics, hrs = [], kmhs = [];
  m.forEach(function (r) { if (isFinite(r.hr)) hrs.push(r.hr); if (isFinite(r.kmh)) kmhs.push(r.kmh); });
  function avg(a) { if (!a.length) return NaN; var s = 0; a.forEach(function (x) { s += x; }); return s / a.length; }
  function max(a) { return a.length ? Math.max.apply(null, a) : NaN; }
  var speechCt = 0, errCt = 0, cacheHit = 0, ttsTot = 0;
  var netCt = 0, netFailCt = 0, elevenMs = [], llmMs = [];
  state.events.forEach(function (ev) {
    if (ev.type === "speech") speechCt++;
    if (ev.type === "error" || ev.type === "tts.fallback" || ev.type === "gen.error") errCt++;
    if (ev.type === "tts.play") { ttsTot++; if (String((ev.data || {}).cached) === "true" || (ev.data || {}).cached === true) cacheHit++; }
    if (ev.type === "net.req") {
      netCt++; var nd = ev.data || {};
      if (String(nd.phase) === "failed") netFailCt++;
      if (String(nd.phase) === "cached") cacheHit++;
      var nms = num(nd.ms);
      if (String(nd.svc) === "11Labs" && String(nd.phase) !== "cached" && isFinite(nms) && nms >= 0) elevenMs.push(nms);
      if (String(nd.svc) === "LLM" && String(nd.phase) !== "cached" && isFinite(nms) && nms >= 0) llmMs.push(nms);
    }
  });
  function pct(a, p) {
    if (!a.length) return NaN;
    var s = a.slice().sort(function (x, y) { return x - y; });
    var i = Math.min(s.length - 1, Math.max(0, Math.round((p / 100) * (s.length - 1))));
    return s[i];
  }
  var dist = state.maxDist > 0 ? state.maxDist : (has(meta.distance_m) ? num(meta.distance_m) : NaN);
  var avgPace = (isFinite(dist) && dist > 0 && state.dur > 0) ? state.dur / (dist / 1000) : NaN;
  // coaching coverage: fraction of run timeline within ~8s of a speech event.
  var cov = computeCoverage();
  var cacheTotal = ttsTot + state.net.filter(function (n) { return n.phase === "cached" || n.phase === "received"; }).length;
  state.summary = {
    duration: state.dur, distance: dist, avgPace: avgPace,
    avgHr: avg(hrs), maxHr: max(hrs), avgKmh: avg(kmhs), maxKmh: max(kmhs),
    metricsCt: m.length, speechCt: speechCt, errCt: errCt,
    netCt: netCt, netFailCt: netFailCt,
    elevenP50: pct(elevenMs, 50), elevenP95: pct(elevenMs, 95),
    llmP50: pct(llmMs, 50), llmP95: pct(llmMs, 95),
    elevenN: elevenMs.length, llmN: llmMs.length,
    coverage: cov, cacheHitRate: cacheTotal > 0 ? cacheHit / cacheTotal : NaN
  };
  renderSummary();
}
function computeCoverage() {
  if (state.dur <= 0) return NaN;
  var win = 8, covered = 0, marks = [];
  state.events.forEach(function (ev) { if (ev.type === "speech") marks.push(ev.t); });
  if (!marks.length) return 0;
  marks.sort(function (a, b) { return a - b; });
  // union of [t, t+win] intervals
  var cs = -1, ce = -1;
  marks.forEach(function (t) {
    var s = t, e = t + win;
    if (cs < 0) { cs = s; ce = e; }
    else if (s <= ce) { if (e > ce) ce = e; }
    else { covered += (ce - cs); cs = s; ce = e; }
  });
  if (cs >= 0) covered += (ce - cs);
  return Math.min(covered / state.dur, 1);
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

// ---- filmstrip KPI header (big numbers + word-size sparklines + gauges) ----
function renderFilm() {
  var s = state.summary, film = document.getElementById("film");
  if (!s) { film.innerHTML = ""; return; }
  function spark(arr, color) {
    var W = 78, H = 16;
    var p = sparkPath(arr, W, H, color, 1.3, 0.8);
    return '<svg width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '">' +
      (p || '<line x1="0" y1="' + (H - 2) + '" x2="' + W + '" y2="' + (H - 2) + '" stroke="' + C.grid + '"/>') + "</svg>";
  }
  function kpi(k, v, sub, arr, color) {
    return '<div class="kpi fade-in"><div class="k">' + esc(k) + '</div><div class="v">' + v +
      (sub ? ' <small>' + esc(sub) + "</small>" : "") + "</div>" + (arr ? spark(arr, color) : "") + "</div>";
  }
  var paceArr = state.metrics.map(function (m) { return isFinite(m.pace) ? -m.pace : NaN; }); // invert: up=faster
  var html = "";
  html += kpi("Distance", fmtDist(s.distance) ? esc(fmtDist(s.distance)) : "—", null,
    state.metrics.map(function (m) { return m.d; }), C.speed);
  html += kpi("Duration", esc(fmtDur(s.duration) || "—"), null, null, null);
  html += kpi("Avg pace", esc(fmtPace(s.avgPace) || "—"), null, paceArr, C.green);
  html += kpi("Avg HR", isFinite(s.avgHr) ? Math.round(s.avgHr) : "—", isFinite(s.avgHr) ? "bpm" : null,
    state.metrics.map(function (m) { return m.hr; }), C.hr);

  // radial gauges: HR (avg/max), coaching coverage, cache-hit rate
  var gauges = '<div class="gauges">';
  gauges += gauge("HR load", isFinite(s.avgHr) && isFinite(s.maxHr) ? s.avgHr / Math.max(s.maxHr, 1) : NaN,
    isFinite(s.avgHr) ? Math.round(s.avgHr) + "" : "\\u2014", C.hr);
  gauges += gauge("Coverage", s.coverage, isFinite(s.coverage) ? Math.round(s.coverage * 100) + "%" : "\\u2014", C.jessica);
  gauges += gauge("Cache", s.cacheHitRate, isFinite(s.cacheHitRate) ? Math.round(s.cacheHitRate * 100) + "%" : "\\u2014", C.green);
  gauges += "</div>";

  film.innerHTML = html + gauges;
}
function gauge(label, frac, center, color) {
  var R = 22, CX = 30, CY = 28, circ = 2 * Math.PI * R;
  var f = isFinite(frac) ? Math.max(0, Math.min(1, frac)) : 0;
  var off = circ * (1 - f);
  return '<div class="gauge fade-in"><svg width="60" height="56" viewBox="0 0 60 56">' +
    '<circle cx="' + CX + '" cy="' + CY + '" r="' + R + '" fill="none" stroke="' + C.grid + '" stroke-width="5"/>' +
    '<circle cx="' + CX + '" cy="' + CY + '" r="' + R + '" fill="none" stroke="' + color + '" stroke-width="5" ' +
      'stroke-linecap="round" stroke-dasharray="' + circ.toFixed(1) + '" stroke-dashoffset="' + off.toFixed(1) + '" ' +
      'transform="rotate(-90 ' + CX + " " + CY + ')" style="transition:stroke-dashoffset .6s ease-out"/>' +
    '<text class="gv" x="' + CX + '" y="' + (CY + 4) + '" text-anchor="middle" font-size="13" fill="' + C.axisText.replace("8b949e", "e6edf3") + '">' + center + "</text>" +
    "</svg><div class=\\"gk\\">" + esc(label) + "</div></div>";
}

function buildDirectorIntervals() {
  var out = [], open = null;
  state.events.forEach(function (ev) {
    if (ev.type !== "director.protect" && ev.type !== "director.room") return;
    var detail = String(ev.detail || "");
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
function tToX(t) {
  if (state.xmode === "time") return t;
  var m = state.metrics;
  if (!m.length) return 0;
  if (t <= m[0].t) return m[0].d;
  if (t >= m[m.length - 1].t) return m[m.length - 1].d;
  var lo = 0, hi = m.length - 1;
  while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (m[mid].t <= t) lo = mid; else hi = mid; }
  var a = m[lo], b = m[hi], span = b.t - a.t;
  if (span <= 0) return a.d;
  return a.d + (b.d - a.d) * (t - a.t) / span;
}
function setXMode(mode, keepFullZoom) {
  state.xmode = mode;
  document.querySelectorAll("#xtoggle button").forEach(function (b) {
    b.classList.toggle("on", b.getAttribute("data-x") === mode);
  });
  state.domain0 = 0;
  state.domain1 = mode === "dist" ? Math.max(state.maxDist, 1) : Math.max(state.dur, 1);
  if (keepFullZoom || state.v1 <= state.v0) { state.v0 = state.domain0; state.v1 = state.domain1; }
  else clampView();
}

// --- svg helpers -------------------------------------------------------
function el(name, attrs) {
  var node = document.createElementNS(SVG_NS, name);
  for (var k in attrs) node.setAttribute(k, attrs[k]);
  return node;
}
function withTitle(node, text) {
  var t = document.createElementNS(SVG_NS, "title"); t.textContent = text; node.appendChild(t); return node;
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

// lane Y offsets (computed each render so resize is fine)
function laneGeo() {
  // DEBUG OFF (default): performance + the VOICE lane only. DEBUG ON adds the
  // EVENTS swim-lanes + the NETWORK request waterfall.
  var plotTop = PAD_T, plotBot = plotTop + PLOT_H;
  var heatTop = plotBot + GAP, heatBot = heatTop + HEAT_H;
  var markTop = heatBot, markBot = heatBot, wfTop = heatBot, wfBot = heatBot;
  if (state.debug) {
    markTop = heatBot + GAP; markBot = markTop + MARK_H;
    wfTop = markBot + GAP; wfBot = wfTop + WF_H;
  }
  var axisY = wfBot;
  return { plotTop: plotTop, plotBot: plotBot, heatTop: heatTop, heatBot: heatBot,
    markTop: markTop, markBot: markBot, wfTop: wfTop, wfBot: wfBot, axisY: axisY,
    total: axisY + AXIS_H };
}

function render() {
  var W = chartWrap.clientWidth || 800;
  var g = laneGeo();
  var CHART_H = g.total;
  chart.setAttribute("viewBox", "0 0 " + W + " " + CHART_H);
  chart.setAttribute("height", CHART_H);
  while (chart.firstChild) chart.removeChild(chart.firstChild);

  var plotW = W - PAD_L - PAD_R; if (plotW < 10) plotW = 10;
  var v0 = state.v0, v1 = state.v1, span = v1 - v0; if (span <= 0) span = 1;
  function X(v) { return PAD_L + (v - v0) / span * plotW; }

  var maxKmh = 0;
  state.metrics.forEach(function (r) { if (isFinite(r.kmh) && r.kmh > maxKmh) maxKmh = r.kmh; });
  var speedTop = Math.max(Math.ceil((maxKmh * 1.18) / 2) * 2, 6);
  if (speedTop > SPEED_MAX_KMH) speedTop = SPEED_MAX_KMH;
  function Yspeed(kmh) { return g.plotBot - (kmh / speedTop) * PLOT_H; }
  function Yhr(hr) { return g.plotBot - (hr / HR_AXIS_MAX) * PLOT_H; }

  // ---- speed area gradient def ----
  var defs = el("defs", {});
  var grad = el("linearGradient", { id: "spdgrad", x1: 0, y1: 0, x2: 0, y2: 1 });
  grad.appendChild(el("stop", { offset: "0%", "stop-color": C.speed, "stop-opacity": 0.34 }));
  grad.appendChild(el("stop", { offset: "100%", "stop-color": C.speed, "stop-opacity": 0.02 }));
  defs.appendChild(grad);
  chart.appendChild(defs);

  // ---- plot frame + speed gridlines ----
  chart.appendChild(el("rect", { x: PAD_L, y: g.plotTop, width: plotW, height: PLOT_H, fill: "none", stroke: C.axis }));
  var sStep = speedTop <= 8 ? 2 : speedTop <= 16 ? 4 : 5;
  for (var sv = 0; sv <= speedTop + 0.01; sv += sStep) {
    var gy = Yspeed(sv);
    chart.appendChild(el("line", { x1: PAD_L, y1: gy, x2: PAD_L + plotW, y2: gy, stroke: C.grid, "stroke-opacity": sv === 0 ? 0 : 0.7 }));
    var sl = el("text", { x: PAD_L - 6, y: gy + 3, fill: C.speed, "font-size": 10, "text-anchor": "end", "pointer-events": "none" });
    sl.textContent = String(sv); chart.appendChild(sl);
  }
  [0, 50, 100, 150, 200].forEach(function (hv) {
    var hy = Yhr(hv);
    var hl = el("text", { x: PAD_L + plotW + 6, y: hy + 3, fill: C.hr, "font-size": 10, "text-anchor": "start", "pointer-events": "none" });
    hl.textContent = String(hv); chart.appendChild(hl);
  });
  var stitle = el("text", { x: PAD_L - 6, y: g.plotTop - 3, fill: C.speed, "font-size": 9, "text-anchor": "start", "pointer-events": "none" });
  stitle.textContent = "km/h"; chart.appendChild(stitle);
  var htitle = el("text", { x: PAD_L + plotW + 6, y: g.plotTop - 3, fill: C.hr, "font-size": 9, "text-anchor": "end", "pointer-events": "none" });
  htitle.textContent = "bpm"; chart.appendChild(htitle);

  // lane labels
  laneLabel("SPEED / HR", g.plotTop + 2);
  laneLabel("VOICES", g.heatTop + 2);
  if (state.debug) { laneLabel("EVENTS", g.markTop + 2); laneLabel("NETWORK", g.wfTop + 2); }

  // ---- shared x grid across ALL lanes ----
  var ticks = niceTicks(v0, v1, 10);
  ticks.forEach(function (tv) {
    var tx = X(tv);
    if (tx < PAD_L - 1 || tx > PAD_L + plotW + 1) return;
    chart.appendChild(el("line", { x1: tx, y1: g.plotTop, x2: tx, y2: g.axisY, stroke: C.grid, "stroke-opacity": 0.4 }));
    var lbl = el("text", { x: tx, y: g.axisY + 14, fill: C.axisText, "font-size": 10, "text-anchor": "middle", "pointer-events": "none" });
    lbl.textContent = fmtXAxis(tv); chart.appendChild(lbl);
  });

  // ---- speed area + HR line ----
  drawSeries(chart, X, function (r) { return r.kmh; }, Yspeed, {
    area: true, color: C.speed, areaFill: "url(#spdgrad)", lineOpacity: 0.7, width: 1.6,
    clipTop: g.plotTop, clipBot: g.plotBot });
  drawSeries(chart, X, function (r) { return r.hr; }, Yhr, {
    area: false, color: C.hr, lineOpacity: 0.95, width: 1.7, clipTop: g.plotTop, clipBot: g.plotBot });

  // ---- director protect bands (behind glyphs) — debug only ----
  if (state.debug) state.directorIntervals.forEach(function (iv) {
    var x0 = Math.max(X(tToX(iv.start)), PAD_L), x1 = Math.min(X(tToX(iv.end)), PAD_L + plotW);
    if (x1 <= PAD_L || x0 >= PAD_L + plotW) return;
    var idx = state.events.indexOf(iv.ev);
    var band = el("rect", { x: x0, y: g.plotTop, width: Math.max(x1 - x0, 2), height: PLOT_H,
      fill: C.protect, stroke: state.selected === idx ? C.select : C.protectEdge,
      "stroke-width": state.selected === idx ? 1.5 : 0.5, "stroke-opacity": state.selected === idx ? 1 : 0.4 });
    withTitle(band, "director.protect " + fmtClock(iv.start) + " \\u2192 " + fmtClock(iv.end));
    clickable(band, idx); chart.appendChild(band);
  });

  // ---- speech glyphs pinned on the speed curve ----
  drawSpeechGlyphs(X, Yspeed, g, speedTop);

  // ---- VOICES lane: clickable bars sized to how long each line was spoken ----
  drawVoiceBars(X, g, plotW);

  // ---- DEBUG-only lanes: EVENTS swim lanes + NETWORK waterfall ----
  if (state.debug) {
    for (var ri = 1; ri < MARK_ROWS; ri++) {
      var ry = g.markTop + ri * ROW_H;
      chart.appendChild(el("line", { x1: PAD_L, y1: ry, x2: PAD_L + plotW, y2: ry, stroke: C.grid, "stroke-opacity": 0.4 }));
    }
    drawEventMarkers(X, g, v0, v1, span, plotW);
    drawWaterfall(X, g, plotW);
  }
}

function laneLabel(txt, y) {
  var t = el("text", { x: 4, y: y + 9, fill: C.axisText, "font-size": 9, "letter-spacing": ".06em", "pointer-events": "none", opacity: 0.5 });
  t.textContent = txt; chart.appendChild(t);
}

function drawSpeechGlyphs(X, Yspeed, g, speedTop) {
  state.events.forEach(function (ev, idx) {
    var type = String(ev.type || "");
    var debugGlyph = (type === "coach.trigger" || type === "endpoint.switch" || type === "tts.fallback");
    if (type !== "speech" && type !== "milestone.owner" && !debugGlyph) return;
    if (debugGlyph && !state.debug) return;   // declutter: debug glyphs hidden by default
    var px = X(tToX(ev.t));
    if (px < PAD_L - 4 || px > PAD_L + (chartWrap.clientWidth - PAD_L - PAD_R) + 4) return;
    // anchor glyph to speed curve height at this t
    var ky = metricAt(ev.t);
    var cy = isFinite(ky) ? Yspeed(ky) : g.plotBot - 10;
    if (cy < g.plotTop + 4) cy = g.plotTop + 4; if (cy > g.plotBot - 4) cy = g.plotBot - 4;
    var sel = state.selected === idx, data = ev.data || {};
    var node, title;
    if (type === "speech") {
      var vid = String(data.voiceId || "");
      var isJess = vid === VOICE_JESSICA || String(data.source || "").indexOf("jessica") === 0;
      var col = isJess ? C.jessica : C.ricky;
      node = el("circle", { cx: px, cy: cy, r: sel ? 4.5 : 3.4, fill: col, "fill-opacity": 0.92,
        stroke: sel ? C.select : "#0b0e13", "stroke-width": sel ? 2 : 0.8 });
      title = (isJess ? "jessica" : "ricky") + " @ " + fmtClock(ev.t) + ": " + String(ev.detail || "");
    } else if (type === "milestone.owner") {
      var d = "M" + px + " " + (cy - 5) + "L" + (px + 5) + " " + cy + "L" + px + " " + (cy + 5) + "L" + (px - 5) + " " + cy + "Z";
      node = el("path", { d: d, fill: C.green, stroke: sel ? C.select : "#0b0e13", "stroke-width": sel ? 2 : 0.8 });
      title = "milestone " + (data.km ? data.km + "km " : "") + "@ " + fmtClock(ev.t);
    } else if (type === "endpoint.switch") {
      node = el("path", { d: "M" + (px - 3) + " " + (cy - 5) + "L" + (px + 1) + " " + cy + "L" + (px - 1) + " " + cy + "L" + (px + 3) + " " + (cy + 5),
        fill: "none", stroke: C.amber, "stroke-width": sel ? 2.4 : 1.6, "stroke-linejoin": "round" });
      title = "endpoint.switch @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : "");
    } else if (type === "tts.fallback") {
      node = el("path", { d: "M" + px + " " + (cy - 5) + "L" + (px + 5) + " " + (cy + 4) + "L" + (px - 5) + " " + (cy + 4) + "Z",
        fill: C.amber, stroke: sel ? C.select : "#0b0e13", "stroke-width": sel ? 2 : 0.8 });
      title = "tts.fallback @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : "");
    } else { // coach.trigger
      node = el("circle", { cx: px, cy: cy, r: sel ? 4 : 2.8, fill: "none", stroke: C.coach, "stroke-width": sel ? 2.2 : 1.4 });
      title = "coach.trigger @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : "");
    }
    withTitle(node, title); clickable(node, idx); chart.appendChild(node);
  });
}
function metricAt(t) {
  var m = state.metrics; if (!m.length) return NaN;
  if (t <= m[0].t) return m[0].kmh;
  if (t >= m[m.length - 1].t) return m[m.length - 1].kmh;
  var lo = 0, hi = m.length - 1;
  while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (m[mid].t <= t) lo = mid; else hi = mid; }
  var a = m[lo].kmh, b = m[hi].kmh;
  if (!isFinite(a)) return b; if (!isFinite(b)) return a;
  return (a + b) / 2;
}

// VOICE-DENSITY HEAT STRIP: two sub-rows (jessica/ricky), color intensity =
// speech seconds per bucket. Faint ticks for voice.dropStale/deferGap.
// VOICES lane: one bar per spoken line, its WIDTH = how long it took to say
// (estimated from text length, ~14 chars/sec). Jessica on top, Ricky below.
// Hover shows the full quote; click selects + replays the audio.
function drawVoiceBars(X, g, plotW) {
  var subH = HEAT_H / 2;
  chart.appendChild(el("rect", { x: PAD_L, y: g.heatTop, width: plotW, height: HEAT_H, fill: "#0c0f14", stroke: C.axis, "stroke-opacity": 0.5 }));
  chart.appendChild(el("line", { x1: PAD_L, y1: g.heatTop + subH, x2: PAD_L + plotW, y2: g.heatTop + subH, stroke: "#0b0e13", "stroke-opacity": 0.6 }));
  var jl = el("text", { x: PAD_L + 3, y: g.heatTop + 10, fill: C.jessica, "font-size": 8, "pointer-events": "none", opacity: 0.65 });
  jl.textContent = "jessica"; chart.appendChild(jl);
  var rl = el("text", { x: PAD_L + 3, y: g.heatTop + subH + 10, fill: C.ricky, "font-size": 8, "pointer-events": "none", opacity: 0.65 });
  rl.textContent = "ricky"; chart.appendChild(rl);

  var plotRight = PAD_L + plotW;
  state.events.forEach(function (ev, idx) {
    if (ev.type !== "speech") return;
    var who = voiceLabel(ev), isJess = who === "jessica";
    var text = String(ev.detail || "");
    var dur = Math.max(1.6, text.length / 13);   // estimated spoken seconds (~13 chars/s)
    var x0 = X(tToX(ev.t)), x1 = X(tToX(num(ev.t) + dur));
    if (x1 < PAD_L || x0 > plotRight) return;
    // clip the bar to the plot area so it never shoots past the time axis
    var cx0 = Math.max(x0, PAD_L), cx1 = Math.min(x1, plotRight);
    var w = Math.max(cx1 - cx0, 4);
    var rowY = (isJess ? g.heatTop : g.heatTop + subH) + 3, barH = subH - 6;
    var sel = state.selected === idx, col = isJess ? C.jessica : C.ricky;
    var bar = el("rect", { x: cx0, y: rowY, width: w, height: barH, rx: 3,
      fill: col, "fill-opacity": sel ? 1 : 0.78, stroke: sel ? C.select : "none", "stroke-width": 2,
      style: "cursor:pointer" });
    var tipHead = who + " \\u00b7 " + fmtClock(ev.t) + " \\u00b7 ~" + Math.round(dur) + "s";
    bar.addEventListener("pointerenter", function (e) { showVoiceTip(e, tipHead, text); });
    bar.addEventListener("pointermove", positionVoiceTip);
    bar.addEventListener("pointerleave", hideVoiceTip);
    clickable(bar, idx); chart.appendChild(bar);
    if (w > 44) {
      var maxChars = Math.max(4, Math.floor((w - 8) / 5));
      var label = text.length > maxChars ? text.slice(0, maxChars - 1) + "\\u2026" : text;
      var tx = el("text", { x: cx0 + 5, y: rowY + barH - 3.5, fill: "#0b0e13", "font-size": 9, "font-weight": 600, "pointer-events": "none" });
      tx.textContent = label; chart.appendChild(tx);
    }
  });

  if (state.debug) state.events.forEach(function (ev) {
    if (ev.type !== "voice.dropStale" && ev.type !== "voice.deferGap") return;
    var px = X(tToX(ev.t)); if (px < PAD_L || px > PAD_L + plotW) return;
    var tk = el("line", { x1: px, y1: g.heatTop, x2: px, y2: g.heatBot, stroke: ev.type === "voice.dropStale" ? C.drop : C.preempt, "stroke-width": 1, "stroke-opacity": 0.85 });
    withTitle(tk, ev.type + " @ " + fmtClock(ev.t)); clickable(tk, state.events.indexOf(ev)); chart.appendChild(tk);
  });
}

function drawEventMarkers(X, g, v0, v1, span, plotW) {
  state.events.forEach(function (ev, idx) {
    var type = String(ev.type || "");
    if (type === "metrics") return;
    if (type === "director.protect" || type === "director.room") return;
    if (type === "speech" || type === "milestone.owner" || type === "endpoint.switch" || type === "coach.trigger") return; // on chart
    if (type === "net.req") return; // waterfall
    var vx = tToX(ev.t);
    if (vx < v0 - span * 0.02 || vx > v1 + span * 0.02) return;
    var px = X(vx);
    if (px < PAD_L - 2 || px > PAD_L + plotW + 2) return;
    var sel = state.selected === idx, data = ev.data || {};

    if (type === "run.start" || type === "run.end" ||
        (type === "run" && (ev.detail === "started" || ev.detail === "ended"))) {
      var isStart = type === "run.start" || ev.detail === "started";
      var line = el("line", { x1: px, y1: g.markTop, x2: px, y2: g.axisY, stroke: sel ? C.select : C.bound,
        "stroke-dasharray": "4 3", "stroke-width": sel ? 2 : 1 });
      withTitle(line, (isStart ? "run start" : "run end") + " @ " + fmtClock(ev.t));
      clickable(line, idx); chart.appendChild(line);
      var bl = el("text", { x: px + 3, y: g.markTop + 10, fill: C.bound, "font-size": 9, "pointer-events": "none" });
      bl.textContent = isStart ? "start" : "end"; chart.appendChild(bl); return;
    }
    if (type === "jessica.react" || type === "jessica.skip" || type === "jessica.ready") {
      var jy = g.markTop + ROW.speech * ROW_H + ROW_H / 2;
      var jc = el("circle", { cx: px, cy: jy, r: 3.2, fill: type === "jessica.skip" ? "none" : C.jessica, stroke: C.jessica, "stroke-width": sel ? 2 : 1 });
      withTitle(jc, type + " @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : ""));
      clickable(jc, idx); chart.appendChild(jc); return;
    }
    if (type === "tts.play" || type === "tts.fallback" || type.indexOf("gen.") === 0 ||
        type === "script.dispatch" || type === "director.prewarm" || type === "milestone") {
      var gy = g.markTop + ROW.gen * ROW_H;
      var color = type === "tts.fallback" ? C.fallback : type === "gen.error" ? C.error
        : type === "script.dispatch" ? C.coach : type === "director.prewarm" ? C.prewarm
        : type === "tts.play" ? C.speed : C.gen;
      var ms = has(data.ms) ? num(data.ms) : NaN;
      if (type === "tts.fallback" || type === "gen.error") {
        var d = "M" + px + " " + (gy + 3) + "L" + (px + 5) + " " + (gy + ROW_H / 2) + "L" + px + " " + (gy + ROW_H - 3) + "L" + (px - 5) + " " + (gy + ROW_H / 2) + "Z";
        var dia = el("path", { d: d, fill: C.error, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
        withTitle(dia, type + " @ " + fmtClock(ev.t) + (data.reason ? ": " + data.reason : ""));
        clickable(dia, idx); chart.appendChild(dia);
      } else {
        var th = isFinite(ms) ? Math.min(Math.max(ms / 60, 5), ROW_H - 4) : 6;
        var tick = el("rect", { x: px - 1.5, y: gy + ROW_H - 1 - th, width: 3, height: th, fill: color, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
        var bits = [type, "@ " + fmtClock(ev.t)];
        if (isFinite(ms)) bits.push(ms + "ms");
        if (data.cached) bits.push("cached=" + data.cached);
        withTitle(tick, bits.join(" ")); clickable(tick, idx); chart.appendChild(tick);
      }
      return;
    }
    if (type === "voice.play" || type === "voice.dropStale" || type === "voice.preempt" || type === "voice.deferGap") {
      var cy = g.markTop + ROW.control * ROW_H;
      var cc = type === "voice.dropStale" ? C.drop : type === "voice.preempt" ? C.preempt : type === "voice.deferGap" ? C.amber : C.bound;
      var ch = (type === "voice.play") ? 7 : ROW_H - 6;
      var tk = el("rect", { x: px - 1.2, y: cy + (ROW_H - ch) / 2, width: 2.4, height: ch, fill: cc, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
      withTitle(tk, type + " @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : ""));
      clickable(tk, idx); chart.appendChild(tk); return;
    }
    if (type === "error") {
      var ey = g.markTop + ROW.director * ROW_H + ROW_H / 2;
      var d2 = "M" + px + " " + (ey - 5) + "L" + (px + 5) + " " + ey + "L" + px + " " + (ey + 5) + "L" + (px - 5) + " " + ey + "Z";
      var er = el("path", { d: d2, fill: C.error, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
      withTitle(er, "error @ " + fmtClock(ev.t) + (ev.detail ? ": " + ev.detail : ""));
      clickable(er, idx); chart.appendChild(er); return;
    }
    // unknown: faint tick on the control row
    var uy = g.markTop + ROW.control * ROW_H + ROW_H - 6;
    var ut = el("rect", { x: px - 0.75, y: uy, width: 1.5, height: 5, fill: "#30363d", stroke: sel ? C.select : "none" });
    withTitle(ut, type + " @ " + fmtClock(ev.t)); clickable(ut, idx); chart.appendChild(ut);
  });
}

// NET.REQ REQUEST WATERFALL: each request = a horizontal bar starting at its t,
// width = data.ms (mapped through the shared x time-scale when in time mode,
// else a ms-proportional width). Greedy lane-packing reveals concurrency.
// 11Labs=amber, LLM=cyan; failed=red+x; cached=ghosted+lightning.
function drawWaterfall(X, g, plotW) {
  chart.appendChild(el("rect", { x: PAD_L, y: g.wfTop, width: plotW, height: WF_H, fill: "#0c0f14", stroke: C.axis, "stroke-opacity": 0.5 }));
  if (!state.net.length) {
    var em = el("text", { x: PAD_L + plotW / 2, y: g.wfTop + WF_H / 2 + 3, fill: C.axisText, "font-size": 10, "text-anchor": "middle", "pointer-events": "none", opacity: 0.6 });
    em.textContent = "no net.req events"; chart.appendChild(em); return;
  }
  var v0 = state.v0, v1 = state.v1, span = (v1 - v0) || 1;
  // ms->px: in time mode use the real time scale; otherwise a fixed scale.
  var pxPerMs = (state.xmode === "time") ? (plotW / span) / 1000 : (plotW / Math.max(maxNetMs(), 1)) * 0.18;
  var barH = 9, gap = 3, lanes = [];
  function rowFor(x0, x1) {
    for (var i = 0; i < lanes.length; i++) { if (x0 >= lanes[i] - 1) { lanes[i] = x1; return i; } }
    lanes.push(x1); return lanes.length - 1;
  }
  var maxLanes = Math.floor((WF_H - 6) / (barH + gap));
  state.net.forEach(function (n) {
    var x0 = X(tToX(n.t));
    var w = isFinite(n.ms) && n.ms > 0 ? Math.max(n.ms * pxPerMs, 2) : 3;
    if (n.phase === "cached") w = 3;
    var x1 = x0 + w;
    if (x1 < PAD_L || x0 > PAD_L + plotW) return;
    var lane = rowFor(x0, x1);
    if (lane >= maxLanes) lane = maxLanes - 1;
    var y = g.wfTop + 3 + lane * (barH + gap);
    var failed = n.phase === "failed", cached = n.phase === "cached";
    var col = failed ? C.netFail : cached ? C.netCached : n.svc === "LLM" ? C.netLLM : n.svc === "11Labs" ? C.net11Labs : C.bound;
    var sel = state.selected === n.idx;
    var cx0 = Math.max(x0, PAD_L), cx1 = Math.min(x1, PAD_L + plotW);
    var bar = el("rect", { x: cx0, y: y, width: Math.max(cx1 - cx0, 2), height: barH, rx: 2,
      fill: col, "fill-opacity": cached ? 0.45 : 0.9, stroke: sel ? C.select : "none", "stroke-width": 1.5 });
    var bits = [(n.svc || "net"), n.phase || "", (isFinite(n.ms) ? Math.round(n.ms) + "ms" : ""), (isFinite(n.bytes) ? n.bytes + "b" : ""), (isFinite(n.chars) ? n.chars + "ch" : ""), n.info];
    withTitle(bar, bits.filter(function (b) { return b; }).join(" \\u00b7 "));
    clickable(bar, n.idx); chart.appendChild(bar);
    // label at right edge when there's room
    if (cx1 - cx0 > 34 && isFinite(n.ms)) {
      var lbl = el("text", { x: cx1 - 3, y: y + barH - 1.5, fill: "#0b0e13", "font-size": 8, "text-anchor": "end", "pointer-events": "none" });
      lbl.textContent = Math.round(n.ms) + "ms"; chart.appendChild(lbl);
    }
    if (failed) {
      var fx = cx0 + 2, fy = y + 2;
      chart.appendChild(el("path", { d: "M" + fx + " " + fy + "l4 5 m0 -5 l-4 5", stroke: "#fff", "stroke-width": 1, "pointer-events": "none", "stroke-opacity": 0.9 }));
    }
    if (cached) {
      var zt = el("text", { x: cx0 + 5, y: y + barH - 1.5, fill: C.netCached.replace("4a6b8a", "9fc1e0"), "font-size": 8, "pointer-events": "none" });
      zt.textContent = "\\u26a1"; chart.appendChild(zt);
    }
  });
}
function maxNetMs() { var mx = 1; state.net.forEach(function (n) { if (isFinite(n.ms) && n.ms > mx) mx = n.ms; }); return mx; }

function drawSeries(svg, X, getY, mapY, opt) {
  var m = state.metrics; if (!m.length) return;
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
      seg.forEach(function (p) { dArea += " L" + p.x + " " + clampY(p.y, opt); });
      dArea += " L" + seg[seg.length - 1].x + " " + opt.clipBot + " Z";
      svg.appendChild(el("path", { d: dArea, fill: opt.areaFill || opt.color, stroke: "none" }));
    }
    var dLine = "";
    seg.forEach(function (p, i) { dLine += (i ? " L" : "M") + p.x + " " + clampY(p.y, opt); });
    svg.appendChild(el("path", { d: dLine, fill: "none", stroke: opt.color, "stroke-width": opt.width,
      "stroke-opacity": opt.lineOpacity, "stroke-linejoin": "round", "stroke-linecap": "round" }));
  });
}
function clampY(y, opt) { if (y < opt.clipTop) return opt.clipTop; if (y > opt.clipBot) return opt.clipBot; return y; }
function niceTicks(a, b, target) {
  var span = b - a; if (span <= 0) return [a];
  var raw = span / target, mag = Math.pow(10, Math.floor(Math.log10(raw))), norm = raw / mag;
  var step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
  var out = [], t = Math.ceil(a / step) * step;
  for (; t <= b + step * 0.001 && out.length < 60; t += step) out.push(t);
  return out;
}

// --- shared crosshair --------------------------------------------------
var crossLine = null;
chart.addEventListener("pointermove", function (e) {
  if (state.pan) return;
  showCrosshair(e);
});
chart.addEventListener("pointerleave", function () {
  if (crossLine && crossLine.parentNode) crossLine.parentNode.removeChild(crossLine);
  crossLine = null; crosspill.style.display = "none";
});
function showCrosshair(e) {
  if (!state.events.length) return;
  var W = chartWrap.clientWidth || 800;
  var plotW = Math.max(W - PAD_L - PAD_R, 10);
  var rect = chart.getBoundingClientRect();
  var sx = (e.clientX - rect.left);
  if (sx < PAD_L || sx > PAD_L + plotW) { crosspill.style.display = "none"; if (crossLine && crossLine.parentNode) crossLine.parentNode.removeChild(crossLine); crossLine = null; return; }
  var g = laneGeo();
  if (!crossLine) { crossLine = el("line", { stroke: C.select, "stroke-width": 1, "stroke-opacity": 0.55, "pointer-events": "none" }); chart.appendChild(crossLine); }
  else chart.appendChild(crossLine); // keep on top
  crossLine.setAttribute("x1", sx); crossLine.setAttribute("x2", sx);
  crossLine.setAttribute("y1", g.plotTop); crossLine.setAttribute("y2", g.axisY);
  // x-value under cursor -> nearest metric
  var v = state.v0 + (sx - PAD_L) / plotW * (state.v1 - state.v0);
  var t = (state.xmode === "time") ? v : distToT(v);
  var mr = nearestMetric(t);
  var parts = ["t " + fmtClock(t)];
  if (state.xmode === "dist") parts[0] = "d " + fmtXAxis(v);
  if (mr) {
    if (isFinite(mr.kmh)) parts.push("<b>" + mr.kmh.toFixed(1) + " km/h</b>");
    if (isFinite(mr.pace)) parts.push("<b>" + (fmtPace(mr.pace) || "") + "</b>");
    if (isFinite(mr.hr)) parts.push('<span class="h">' + Math.round(mr.hr) + " bpm</span>");
  }
  crosspill.innerHTML = parts.join(" &middot; ");
  crosspill.style.display = "block";
  var pw = crosspill.offsetWidth || 120;
  var left = sx - pw / 2; if (left < 50) left = 50; if (left > W - pw - 6) left = W - pw - 6;
  crosspill.style.left = left + "px";
}
// --- voice-bar hover tooltip (full quote text) -------------------------
function showVoiceTip(e, head, text) {
  voicetip.innerHTML = '<div class="vt-h">' + esc(head) + "</div>" + esc(text);
  voicetip.style.display = "block";
  positionVoiceTip(e);
}
function positionVoiceTip(e) {
  if (voicetip.style.display === "none") return;
  var r = chartWrap.getBoundingClientRect();
  var x = e.clientX - r.left, y = e.clientY - r.top;
  var tw = voicetip.offsetWidth, th = voicetip.offsetHeight, W = chartWrap.clientWidth;
  var left = x + 14; if (left + tw > W - 6) left = x - tw - 14; if (left < 4) left = 4;
  var top = y - th - 12; if (top < 4) top = y + 20;
  voicetip.style.left = left + "px"; voicetip.style.top = top + "px";
}
function hideVoiceTip() { voicetip.style.display = "none"; }

function distToT(d) {
  var m = state.metrics; if (!m.length) return 0;
  if (d <= m[0].d) return m[0].t; if (d >= m[m.length - 1].d) return m[m.length - 1].t;
  var lo = 0, hi = m.length - 1;
  while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (m[mid].d <= d) lo = mid; else hi = mid; }
  var a = m[lo], b = m[hi], span = b.d - a.d; if (span <= 0) return a.t;
  return a.t + (b.t - a.t) * (d - a.d) / span;
}
function nearestMetric(t) {
  var m = state.metrics; if (!m.length) return null;
  var lo = 0, hi = m.length - 1;
  if (t <= m[0].t) return m[0]; if (t >= m[hi].t) return m[hi];
  while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (m[mid].t <= t) lo = mid; else hi = mid; }
  return (t - m[lo].t < m[hi].t - t) ? m[lo] : m[hi];
}

// --- selection + detail -----------------------------------------------
function select(idx) {
  state.selected = idx;
  scheduleRender();
  highlightLogRow(idx, true);
  var ev = state.events[idx];
  if (!ev) return;
  document.getElementById("dhead").textContent = ev.type + (ev.detail ? " \\u2014 " + ev.detail : "");
  var wall = ev.wall ? " \\u00b7 " + ev.wall : "";
  document.getElementById("dtime").textContent = "t=" + fmtClock(num(ev.t) || 0) + wall;
  document.getElementById("djson").textContent = JSON.stringify(ev, null, 2);
  var canPlay = ev.type === "speech";
  var playBtn = document.getElementById("dplay");
  playBtn.style.display = canPlay ? "inline-block" : "none";
  if (canPlay) loadSpeech(ev, true);
}

// --- audio -------------------------------------------------------------
function resetAudio() {
  audio.pause(); curAudio = null;
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
  var data = ev.data || {}, text = String(ev.detail || ""), who = voiceLabel(ev);
  var chipColor = who === "jessica" ? C.jessica : who === "ricky" ? C.ricky : C.voiceOther;
  document.getElementById("ptext").textContent = text || "(no text)";
  document.getElementById("psub").innerHTML =
    '<span class="voicechip" style="background:' + chipColor + '">' + esc(who) + "</span>" +
    (data.cacheKey ? "tap play to hear it" : "no cacheKey on this line");
  var statusEl = document.getElementById("pstatus"), btn = document.getElementById("pbtn");
  if (!data.cacheKey) { statusEl.textContent = "audio key missing"; btn.disabled = true; btn.innerHTML = "&#9654;"; curAudio = null; return; }
  var url = "/api/runs/" + encodeURIComponent(state.runId) + "/audio/" + encodeURIComponent(data.cacheKey);
  curAudio = { url: url, text: text, who: who, cacheKey: data.cacheKey };
  btn.disabled = false; statusEl.textContent = "";
  if (autoplay) playCurrent();
}
function playCurrent() {
  if (!curAudio) return;
  var statusEl = document.getElementById("pstatus"), btn = document.getElementById("pbtn");
  if (audio.getAttribute("data-key") !== curAudio.cacheKey) {
    audio.src = curAudio.url; audio.setAttribute("data-key", curAudio.cacheKey);
  }
  statusEl.textContent = "loading\\u2026";
  audio.play().then(function () { statusEl.textContent = "playing"; btn.innerHTML = "&#10074;&#10074;"; }).catch(function () {
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
    audio.pause(); document.getElementById("pbtn").innerHTML = "&#9654;"; document.getElementById("pstatus").textContent = "paused";
  } else playCurrent();
});
audio.addEventListener("ended", function () { document.getElementById("pbtn").innerHTML = "&#9654;"; document.getElementById("pstatus").textContent = "done"; });
document.getElementById("dplay").addEventListener("click", function () {
  var ev = state.events[state.selected];
  if (ev && ev.type === "speech") loadSpeech(ev, true);
});

// --- telemetry log -----------------------------------------------------
var logFilter = { types: null };
function eventTypes() { var set = {}; state.events.forEach(function (ev) { set[ev.type] = (set[ev.type] || 0) + 1; }); return set; }
function isErr(type) { return type === "error" || type === "tts.fallback" || type === "gen.error"; }
function renderLog() {
  var bar = document.getElementById("logbar");
  bar.innerHTML = '<span class="lbl">Filter</span>';
  var types = eventTypes(), keys = Object.keys(types).sort();
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
    tr.addEventListener("click", function () { select(idx); toggleJsonRow(tr, ev); });
    body.appendChild(tr);
  });
}
function toggleJsonRow(tr, ev) {
  var next = tr.nextSibling;
  if (next && next.classList && next.classList.contains("jsonrow")) { next.parentNode.removeChild(next); return; }
  document.querySelectorAll(".jsonrow").forEach(function (n) { n.parentNode.removeChild(n); });
  var jr = document.createElement("tr"); jr.className = "jsonrow";
  var td = document.createElement("td"); td.colSpan = 4;
  var pre = document.createElement("pre"); pre.textContent = JSON.stringify(ev, null, 2);
  td.appendChild(pre); jr.appendChild(td);
  tr.parentNode.insertBefore(jr, tr.nextSibling);
}
function highlightLogRow(idx, flash) {
  var body = document.getElementById("logbody");
  body.querySelectorAll("tr.sel").forEach(function (r) { r.classList.remove("sel"); });
  var row = body.querySelector('tr[data-idx="' + idx + '"]');
  if (row) {
    row.classList.add("sel");
    if (flash && state.tab === "perf") { row.classList.remove("flash"); void row.offsetWidth; row.classList.add("flash"); }
    row.scrollIntoView({ block: "nearest" });
  }
}

// ============ CONTROL ROOM ============
function renderControl() {
  var root = document.getElementById("control");
  if (!state.runId || !state.events.length) { root.innerHTML = '<div class="empty" style="margin:30px;color:var(--textDim)">Select a run to view its Control Room.</div>'; return; }
  var s = state.summary;
  // run progress
  var progPct = isFinite(s.distance) && s.distance > 0 ? 100 : (state.dur > 0 ? 100 : 0);
  // activity rollups
  var act = { speech: 0, "voice.play": 0, "voice.dropStale": 0, "voice.deferGap": 0, "voice.preempt": 0,
    "coach.trigger": 0, "director.protect": 0, "director.prewarm": 0, "director.room": 0,
    "milestone.owner": 0, "jessica.ready": 0, "script.dispatch": 0, "tts.play": 0, "tts.fallback": 0, "endpoint.switch": 0 };
  state.events.forEach(function (ev) { if (act[ev.type] !== undefined) act[ev.type]++; });

  function statBox(k, v, cls) { return '<div class="stat"><div class="sk">' + esc(k) + '</div><div class="sv ' + (cls || "") + '">' + v + "</div></div>"; }

  // network inspector (newest first)
  var nets = state.net.slice().sort(function (a, b) { return b.t - a.t; });
  var netRows = nets.map(function (n) {
    var col = n.svc === "11Labs" ? C.net11Labs : n.svc === "LLM" ? C.netLLM : C.bound;
    return '<tr data-idx="' + n.idx + '">' +
      '<td>' + esc(fmtClock(n.t)) + "</td>" +
      '<td><span class="svc" style="background:' + col + '">' + esc(n.svc || "?") + "</span></td>" +
      '<td class="ph ' + esc(n.phase) + '">' + esc(n.phase || "\\u2014") + "</td>" +
      '<td>' + (isFinite(n.ms) ? Math.round(n.ms) + " ms" : "\\u2014") + "</td>" +
      '<td>' + (isFinite(n.bytes) ? n.bytes + " b" : (isFinite(n.chars) ? n.chars + " ch" : "\\u2014")) + "</td>" +
      "</tr>";
  }).join("");
  var netSummary =
    statBox("Requests", String(s.netCt), "") +
    statBox("Failures", String(s.netFailCt), s.netFailCt ? "bad" : "good") +
    statBox("11Labs p50", isFinite(s.elevenP50) ? Math.round(s.elevenP50) + " ms" : "\\u2014", "") +
    statBox("11Labs p95", isFinite(s.elevenP95) ? Math.round(s.elevenP95) + " ms" : "\\u2014", "") +
    statBox("LLM p50", isFinite(s.llmP50) ? Math.round(s.llmP50) + " ms" : "\\u2014", "") +
    statBox("Cache hit", isFinite(s.cacheHitRate) ? Math.round(s.cacheHitRate * 100) + "%" : "\\u2014", "");

  // voice/director/coach activity lines
  function actLine(name, n, color) {
    return '<div class="actline"><span class="ab" style="background:' + color + '"></span><span class="an">' + esc(name) + '</span><span class="ac">' + n + "</span></div>";
  }
  var voiceCard = actLine("speech lines", act.speech, C.jessica) +
    actLine("voice.play", act["voice.play"], C.speed) +
    actLine("voice.deferGap", act["voice.deferGap"], C.amber) +
    actLine("voice.dropStale", act["voice.dropStale"], C.drop) +
    actLine("voice.preempt", act["voice.preempt"], C.preempt);
  var directorCard = actLine("director.protect", act["director.protect"], C.protectEdge) +
    actLine("director.prewarm", act["director.prewarm"], C.prewarm) +
    actLine("director.room", act["director.room"], C.bound) +
    actLine("milestone.owner", act["milestone.owner"], C.green) +
    actLine("jessica.ready", act["jessica.ready"], C.jessica);
  var coachCard = actLine("coach.trigger", act["coach.trigger"], C.coach) +
    actLine("script.dispatch", act["script.dispatch"], C.coach) +
    actLine("tts.play", act["tts.play"], C.speed) +
    actLine("tts.fallback", act["tts.fallback"], C.amber) +
    actLine("endpoint.switch", act["endpoint.switch"], C.endpoint);

  // event tail (newest 60)
  var tail = state.events.slice().reverse().slice(0, 80).map(function (ev) {
    var dat = String(ev.detail || "");
    if (!dat) { try { var ds = JSON.stringify(ev.data || {}); if (ds !== "{}") dat = ds; } catch (e) {} }
    return '<div class="tl' + (isErr(ev.type) ? " err" : "") + '" data-idx="' + state.events.indexOf(ev) + '">' +
      '<span class="tt">' + esc(fmtClock(ev.t)) + '</span><span class="ty">' + esc(ev.type) + '</span><span class="td">' + esc(dat) + "</span></div>";
  }).join("");

  root.innerHTML =
    '<div class="cr-grid">' +
      '<div class="card fade-in"><h3>Run progress<span class="tag">' + esc(fmtDur(s.duration) || "") + (fmtDist(s.distance) ? " \\u00b7 " + esc(fmtDist(s.distance)) : "") + '</span></h3><div class="body">' +
        '<div class="progress"><i style="width:' + progPct + '%"></i></div>' +
        '<div class="statgrid" style="margin-top:10px">' +
          statBox("Avg pace", esc(fmtPace(s.avgPace) || "\\u2014")) +
          statBox("Avg HR", isFinite(s.avgHr) ? Math.round(s.avgHr) + " bpm" : "\\u2014") +
          statBox("Metrics", String(s.metricsCt)) +
          statBox("Coverage", isFinite(s.coverage) ? Math.round(s.coverage * 100) + "%" : "\\u2014") +
        "</div></div></div>" +
      '<div class="card fade-in"><h3>Network inspector<span class="tag">' + s.netCt + ' req</span></h3><div class="body" style="padding:0">' +
        '<div class="statgrid" style="padding:10px">' + netSummary + "</div>" +
        '<div class="net-scroll"><table class="net"><thead><tr><th>t</th><th>svc</th><th>phase</th><th>ms</th><th>size</th></tr></thead><tbody>' +
        (netRows || '<tr><td colspan="5" style="color:var(--textDim);padding:12px">no net.req events</td></tr>') + "</tbody></table></div></div></div>" +
      '<div class="card fade-in"><h3>Voice queue</h3><div class="body">' + voiceCard + "</div></div>" +
      '<div class="card fade-in"><h3>Director</h3><div class="body">' + directorCard + "</div></div>" +
      '<div class="card fade-in"><h3>Coach pipeline</h3><div class="body">' + coachCard + "</div></div>" +
      '<div class="card fade-in" style="grid-column:1/-1"><h3>Event tail<span class="tag">newest first</span></h3><div class="body" style="padding:0"><div class="tail">' + tail + "</div></div></div>" +
    "</div>";

  // wire clicks: jump to event + perf tab
  root.querySelectorAll("table.net tr[data-idx], .tail .tl[data-idx]").forEach(function (r) {
    r.addEventListener("click", function () {
      var i = Number(r.getAttribute("data-idx"));
      if (isFinite(i)) { setTab("perf"); select(i); }
    });
  });
}

// ============ RECYCLE BIN ============
function loadDeleted() {
  return fetch("/api/runs/deleted").then(function (r) {
    if (r.status === 404) return []; // endpoint not deployed yet
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }).then(function (rows) {
    state.deleted = Array.isArray(rows) ? rows : [];
    var badge = document.getElementById("binbadge");
    if (state.deleted.length) { badge.style.display = "inline-block"; badge.textContent = state.deleted.length; }
    else badge.style.display = "none";
    renderBin();
  }).catch(function () { state.deleted = []; renderBin(); });
}
function renderBin() {
  var root = document.getElementById("bin");
  var head = '<div class="binhead"><h2>Recycle Bin</h2><p>Deleted runs are kept here. Restore brings a run back; Delete Forever is permanent.</p></div>';
  if (!state.deleted.length) { root.innerHTML = head + '<div class="empty">The recycle bin is empty.</div>'; return; }
  var cards = state.deleted.map(function (run) {
    var d = new Date(run.started_at);
    var dateStr = isNaN(d.getTime()) ? String(run.started_at)
      : d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) + " " +
        d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    var md = metaDurDist(metaObj(run.meta));
    var bits = [];
    var fd = fmtDur(md.dur); if (fd) bits.push(fd);
    var fdist = fmtDist(md.dist); if (fdist) bits.push(fdist);
    bits.push(run.event_count + " events");
    var del = run.deleted_at ? (" \\u00b7 deleted " + new Date(run.deleted_at).toLocaleString()) : "";
    return '<div class="bincard fade-in"><div class="bmeta"><div class="bdate">' + esc(dateStr) + '</div>' +
      '<div class="bsub">' + esc(bits.join(" \\u00b7 ")) + esc(del) + '</div></div>' +
      '<button class="restore" data-id="' + esc(run.run_id) + '">Restore</button>' +
      '<button class="purge" data-id="' + esc(run.run_id) + '">Delete Forever</button></div>';
  }).join("");
  root.innerHTML = head + cards;
  root.querySelectorAll("button.restore").forEach(function (b) {
    b.addEventListener("click", function () { restoreRun(b.getAttribute("data-id")); });
  });
  root.querySelectorAll("button.purge").forEach(function (b) {
    b.addEventListener("click", function () { purgeRun(b.getAttribute("data-id")); });
  });
}
function postRun(id, action) {
  return fetch("/api/runs/" + encodeURIComponent(id) + "/" + action, { method: "POST" }).then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r;
  });
}
function deleteRun(id) {
  postRun(id, "delete").then(function () {
    toast("Moved to recycle bin");
    return Promise.all([loadRuns(true), loadDeleted()]);
  }).catch(function (e) { toast("Delete failed: " + e.message); });
}
function restoreRun(id) {
  postRun(id, "restore").then(function () {
    toast("Run restored");
    return Promise.all([loadRuns(true), loadDeleted()]);
  }).catch(function (e) { toast("Restore failed: " + e.message); });
}
function purgeRun(id) {
  if (!window.confirm("Delete this run forever? This cannot be undone.")) return;
  postRun(id, "purge").then(function () {
    toast("Run permanently deleted");
    return loadDeleted();
  }).catch(function (e) { toast("Purge failed: " + e.message); });
}

// --- tabs --------------------------------------------------------------
function setTab(tab) {
  state.tab = tab;
  document.querySelectorAll("#tabs button").forEach(function (b) { b.classList.toggle("on", b.getAttribute("data-tab") === tab); });
  document.getElementById("perf").classList.toggle("on", tab === "perf");
  document.getElementById("control").classList.toggle("on", tab === "control");
  document.getElementById("bin").classList.toggle("on", tab === "bin");
  // x-toggle only meaningful for perf
  document.getElementById("xtoggle").style.visibility = tab === "perf" ? "visible" : "hidden";
  document.getElementById("film").style.display = tab === "bin" ? "none" : "flex";
  if (tab === "control") renderControl();
  if (tab === "bin") loadDeleted();
  if (tab === "perf") scheduleRender();
}
document.querySelectorAll("#tabs button").forEach(function (b) {
  b.addEventListener("click", function () { setTab(b.getAttribute("data-tab")); });
});

// --- x toggle ----------------------------------------------------------
document.querySelectorAll("#xtoggle button").forEach(function (b) {
  b.addEventListener("click", function () {
    if (b.classList.contains("on")) return;
    setXMode(b.getAttribute("data-x"), true);
    scheduleRender();
  });
});

// --- debug toggle: show/hide network + pipeline diagnostics lanes -------
document.getElementById("dbgchk").addEventListener("change", function () {
  state.debug = this.checked;
  document.body.classList.toggle("debug-on", state.debug);
  scheduleRender();
});

// --- zoom + pan --------------------------------------------------------
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
  state.v0 = pivot - px * newSpan; state.v1 = state.v0 + newSpan;
  clampView(); scheduleRender();
}, { passive: false });
// Pan tracking lives on window (not setPointerCapture) so a real click still
// reaches the speech bars — capture would retarget the click to the SVG root
// and the bars would never fire. A pan only begins after the pointer actually
// moves past a small threshold, so a tap selects instead of nudging the view.
chart.addEventListener("pointerdown", function (e) {
  if (!state.events.length || e.button !== 0) return;
  state.pan = { x: e.clientX, v0: state.v0, v1: state.v1, moved: false };
});
window.addEventListener("pointermove", function (e) {
  if (!state.pan) return;
  var W = chartWrap.clientWidth || 800;
  var plotW = Math.max(W - PAD_L - PAD_R, 10);
  var dx = e.clientX - state.pan.x;
  if (!state.pan.moved) {
    if (Math.abs(dx) <= 3) return;        // tap, not a drag — leave clicks alone
    state.pan.moved = true; chart.classList.add("panning"); hideVoiceTip();
  }
  var dv = -dx / plotW * (state.pan.v1 - state.pan.v0);
  state.v0 = state.pan.v0 + dv; state.v1 = state.pan.v1 + dv;
  clampView(); scheduleRender();
});
function endPan() { state.pan = null; chart.classList.remove("panning"); }
window.addEventListener("pointerup", endPan);
window.addEventListener("pointercancel", endPan);

function clampView() {
  var span = state.v1 - state.v0;
  var lo = state.domain0 - state.domain1 * 0.04, hi = state.domain1 * 1.04;
  if (span > hi - lo) { state.v0 = lo; state.v1 = hi; return; }
  if (state.v0 < lo) { state.v0 = lo; state.v1 = lo + span; }
  if (state.v1 > hi) { state.v1 = hi; state.v0 = hi - span; }
}

window.addEventListener("resize", scheduleRender);
loadRuns();
loadDeleted();
</script>
</body>
</html>
`;
