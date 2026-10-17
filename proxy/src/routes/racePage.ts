/// Race day Control Room page: GET /race on my.aarun.club (dashboard session
/// cookie, or the admin header). Shows the runner live on the course over
/// relayed Amap tiles, the numbers, batteries, the camera, and every spoken
/// line. Built for a screen recording next to the agent's terminal (founder,
/// 2026-10-17: B-roll for the race video, shown in Phi Browser). No external
/// dependencies: the page must survive a flaky link on race morning.

import { isAdminOrSession, type LiveEnv } from "./live";

export async function racePageHandler(request: Request, env: LiveEnv): Promise<Response> {
    // One-shot sign-in for the agent's own browser: /race?key=<LIVE_ADMIN_TOKEN>
    // sets the dashboard session cookie and drops the key from the URL.
    const key = new URL(request.url).searchParams.get("key");
    if (key && env.LIVE_ADMIN_TOKEN && key === env.LIVE_ADMIN_TOKEN && env.DEVICE_TOKEN) {
        return new Response(null, { status: 302, headers: {
            location: "/race",
            "set-cookie": `aarc_session=${env.DEVICE_TOKEN}; Path=/; Max-Age=${90 * 24 * 3600}; HttpOnly; Secure; SameSite=Lax`,
        } });
    }
    if (!isAdminOrSession(request, env)) {
        return new Response(null, { status: 302, headers: { location: "/" } });
    }
    return new Response(RACE_HTML, { status: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

const RACE_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AARC Control Room</title>
<style>
:root{--bg:#0b0f14;--panel:#121923;--ink:#e8edf2;--muted:#8b98a8;--line:#1f2a36;--red:#ff3b5c;--green:#2ee59d;--amber:#ffb020;--blue:#4da3ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,'PingFang SC','Hiragino Sans GB',sans-serif;height:100vh;overflow:hidden}
#grid{display:grid;grid-template-columns:1fr 400px;grid-template-rows:64px 1fr 150px;height:100vh;gap:10px;padding:10px}
header{grid-column:1/3;display:flex;align-items:center;gap:18px;padding:0 14px;background:var(--panel);border:1px solid var(--line);border-radius:12px}
header h1{font-size:20px;margin:0;letter-spacing:.04em}
header .sub{color:var(--muted);font-size:14px}
#status{margin-left:auto;display:flex;align-items:center;gap:14px;font-variant-numeric:tabular-nums}
.badge{padding:4px 10px;border-radius:999px;font-size:13px;font-weight:700;letter-spacing:.06em;background:#233}
.badge.live{background:#0f3d2a;color:var(--green)} .badge.stale{background:#4a3200;color:var(--amber)} .badge.off{background:#4a1020;color:var(--red)}
#clock{font-size:26px;font-weight:700}
#maps{position:relative;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
canvas{display:block}
#follow{width:100%;height:100%}
#overview{position:absolute;right:12px;bottom:12px;width:300px;height:280px;border:1px solid #334;border-radius:10px;background:#0b0f14;box-shadow:0 6px 24px rgba(0,0,0,.5)}
#where{position:absolute;left:12px;top:12px;background:rgba(11,15,20,.85);padding:8px 12px;border-radius:10px;font-size:15px;max-width:60%}
#where b{color:var(--blue)}
aside{display:flex;flex-direction:column;gap:10px;overflow:hidden}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.kpi{display:grid;grid-template-columns:1fr 1fr;gap:10px 14px}
.kpi .v{font-size:34px;font-weight:800;font-variant-numeric:tabular-nums;line-height:1.1}
.kpi .l{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
.kpi .w{grid-column:1/3}
.row{display:flex;justify-content:space-between;font-size:15px;padding:3px 0;border-top:1px solid var(--line)}
.row:first-child{border-top:0}
.row span:last-child{font-variant-numeric:tabular-nums;font-weight:600}
.bat{display:inline-block;min-width:44px;text-align:right}
.ok{color:var(--green)} .warn{color:var(--amber)} .bad{color:var(--red)}
#ticker{grid-column:1/3;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:8px 14px;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end}
.line{display:flex;gap:12px;font-size:16px;padding:3px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.line .who{min-width:92px;font-weight:700} .line .t{color:var(--muted);min-width:64px;font-variant-numeric:tabular-nums}
.who.ricky{color:#ff7a59} .who.jessica{color:#d98cff} .who.home{color:var(--green)} .who.sys{color:var(--muted)}
#err{position:absolute;left:12px;bottom:12px;color:var(--amber);font-size:13px;background:rgba(11,15,20,.85);padding:6px 10px;border-radius:8px;display:none}
</style></head><body>
<div id="grid">
<header><h1>AARC CONTROL ROOM</h1><span class="sub" id="race">Tianjin Marathon · 25 Oct 2026</span>
<div id="status"><span id="badge" class="badge off">NO FEED</span><span id="age" class="sub"></span><span id="clock">--:--:--</span></div></header>
<div id="maps"><canvas id="follow"></canvas><canvas id="overview" width="600" height="560"></canvas><div id="where">waiting for the first fix…</div><div id="err"></div></div>
<aside>
<div class="card kpi">
  <div class="w"><div class="v" id="elapsed">0:00:00</div><div class="l" id="elapsedL">race clock</div></div>
  <div><div class="v" id="dist">0.00</div><div class="l">km</div></div>
  <div><div class="v" id="pace">--:--</div><div class="l">pace /km</div></div>
  <div><div class="v" id="avg">--:--</div><div class="l">avg /km</div></div>
  <div><div class="v" id="hr">--</div><div class="l">heart rate</div></div>
  <div class="w"><div class="v" id="eta">--:--:--</div><div class="l">projected finish</div></div>
</div>
<div class="card" id="course">
  <div class="row"><span>on the course</span><span id="ckm">--</span></div>
  <div class="row"><span>next aid station</span><span id="station">--</span></div>
  <div class="row"><span>to the finish</span><span id="togo">--</span></div>
  <div class="row"><span>gate</span><span id="gate">not yet</span></div>
</div>
<div class="card" id="devices">
  <div class="row"><span>watch</span><span class="bat" id="bwatch">--</span></div>
  <div class="row"><span>phone</span><span class="bat" id="bphone">--</span></div>
  <div class="row"><span>camera</span><span id="camera">--</span></div>
  <div class="row"><span>uplink</span><span id="uplink">--</span></div>
</div>
</aside>
<div id="ticker"></div>
</div>
<script>
(() => {
const COURSE_ID = 'tianjin2026';
const $ = (id) => document.getElementById(id);
let courseErr = ''; const err = (m) => { const e = $('err'); const t = [courseErr, m].filter(Boolean).join(' · '); e.textContent = t; e.style.display = t ? 'block' : 'none'; };

// --- WGS-84 -> GCJ-02 (the phone logs WGS; the tiles and the course are GCJ)
const PI = Math.PI, A = 6378245.0, EE = 0.00669342162296594323;
function tLat(x, y){ let r = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*Math.sqrt(Math.abs(x)); r += (20*Math.sin(6*x*PI) + 20*Math.sin(2*x*PI))*2/3; r += (20*Math.sin(y*PI) + 40*Math.sin(y/3*PI))*2/3; r += (160*Math.sin(y/12*PI) + 320*Math.sin(y*PI/30))*2/3; return r; }
function tLon(x, y){ let r = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*Math.sqrt(Math.abs(x)); r += (20*Math.sin(6*x*PI) + 20*Math.sin(2*x*PI))*2/3; r += (20*Math.sin(x*PI) + 40*Math.sin(x/3*PI))*2/3; r += (150*Math.sin(x/12*PI) + 300*Math.sin(x/30*PI))*2/3; return r; }
function wgs2gcj(lon, lat){ let dLat = tLat(lon-105, lat-35), dLon = tLon(lon-105, lat-35); const rl = lat/180*PI; let m = Math.sin(rl); m = 1 - EE*m*m; const sm = Math.sqrt(m); dLat = (dLat*180)/((A*(1-EE))/(m*sm)*PI); dLon = (dLon*180)/(A/sm*Math.cos(rl)*PI); return [lon+dLon, lat+dLat]; }

// --- Web Mercator helpers (tile space at zoom z)
function proj(lon, lat, z){ const n = Math.pow(2, z); return [(lon+180)/360*n, (1 - Math.log(Math.tan(lat*PI/180) + 1/Math.cos(lat*PI/180))/PI)/2*n]; }
const tiles = new Map();
function tile(x, y, z, onload){ const k = z+'/'+x+'/'+y; let t = tiles.get(k); if (t) return t; t = new Image(); t.onload = onload; t.tries = (tiles.get(k + '#n') || 0) + 1; t.onerror = () => { t.failed = true; if (t.tries < 7) setTimeout(() => { tiles.delete(k); tiles.set(k + '#n', t.tries); requestRedraw(); }, 1500 * t.tries); }; t.src = '/maptile?x='+x+'&y='+y+'&z='+z; tiles.set(k, t); return t; }

const state = { course: null, events: [], next: 0, run: null, fixes: [], last: {}, lines: [], gateT: null, serverSkew: 0, lastOK: 0, fails: 0 };

function drawMap(cv, centerLonLat, z, opts){
  const ctx = cv.getContext('2d'); const W = cv.width, H = cv.height;
  ctx.fillStyle = '#0b0f14'; ctx.fillRect(0, 0, W, H);
  const c = proj(centerLonLat[0], centerLonLat[1], z);
  const ox = c[0]*256 - W/2, oy = c[1]*256 - H/2;
  const x0 = Math.floor(ox/256), x1 = Math.floor((ox+W)/256), y0 = Math.floor(oy/256), y1 = Math.floor((oy+H)/256);
  for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) { const t = tile(x, y, z, () => requestRedraw()); if (t.complete && t.naturalWidth) ctx.drawImage(t, x*256-ox, y*256-oy); }
  if (opts.dim) { ctx.fillStyle = 'rgba(11,15,20,0.35)'; ctx.fillRect(0, 0, W, H); }
  const P = (lon, lat) => { const p = proj(lon, lat, z); return [p[0]*256-ox, p[1]*256-oy]; };
  // course
  if (state.course) {
    ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    ctx.beginPath(); state.course.polyline.forEach((p, i) => { const q = P(p[0], p[1]); i ? ctx.lineTo(q[0], q[1]) : ctx.moveTo(q[0], q[1]); });
    ctx.strokeStyle = 'rgba(255,59,92,0.95)'; ctx.lineWidth = opts.courseWidth; ctx.stroke();
    // km markers
    const every = opts.kmEvery;
    for (const k of state.course.kmPoints) { if (k.km % every) continue; const q = P(k.lon, k.lat); ctx.beginPath(); ctx.arc(q[0], q[1], opts.kmR, 0, 2*PI); ctx.fillStyle = '#111'; ctx.fill(); ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; ctx.stroke(); if (opts.kmLabel) { ctx.fillStyle = '#fff'; ctx.font = 'bold ' + opts.kmFont + 'px -apple-system,Helvetica'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillText(String(k.km), q[0], q[1]+0.5); } }
    if (opts.stations) for (const k of state.course.km) { if (!k.stations || !k.stations.length) continue; const pt = state.course.kmPoints[k.km]; if (!pt) continue; const q = P(pt.lon, pt.lat); ctx.fillStyle = '#4da3ff'; ctx.beginPath(); ctx.rect(q[0]-5, q[1]-20, 10, 10); ctx.fill(); }
  }
  // trail + runner
  if (state.fixes.length) {
    ctx.beginPath(); state.fixes.forEach((f, i) => { const q = P(f.g[0], f.g[1]); i ? ctx.lineTo(q[0], q[1]) : ctx.moveTo(q[0], q[1]); });
    ctx.strokeStyle = 'rgba(46,229,157,0.9)'; ctx.lineWidth = opts.trailWidth; ctx.stroke();
    const f = state.fixes[state.fixes.length-1]; const q = P(f.g[0], f.g[1]);
    const pulse = 0.5 + 0.5*Math.sin(Date.now()/300);
    ctx.beginPath(); ctx.arc(q[0], q[1], opts.dotR*(1.6+pulse), 0, 2*PI); ctx.fillStyle = 'rgba(46,229,157,0.25)'; ctx.fill();
    ctx.beginPath(); ctx.arc(q[0], q[1], opts.dotR, 0, 2*PI); ctx.fillStyle = '#2ee59d'; ctx.fill(); ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.stroke();
  }
}
let redrawQueued = false;
function requestRedraw(){ if (redrawQueued) return; redrawQueued = true; requestAnimationFrame(() => { redrawQueued = false; draw(); }); }
function draw(){
  const fv = $('follow'); const box = $('maps').getBoundingClientRect(); if (fv.width !== Math.floor(box.width) || fv.height !== Math.floor(box.height)) { fv.width = Math.floor(box.width); fv.height = Math.floor(box.height); }
  const last = state.fixes[state.fixes.length-1];
  const center = last ? last.g : (state.course ? state.course.center : [117.21, 39.11]);
  drawMap(fv, center, 16, { courseWidth: 7, kmEvery: 1, kmR: 11, kmFont: 12, kmLabel: true, stations: true, trailWidth: 5, dotR: 9, dim: false });
  if (state.course) drawMap($('overview'), state.course.center, state.course.zoom, { courseWidth: 3, kmEvery: 5, kmR: 7, kmFont: 9, kmLabel: true, stations: false, trailWidth: 3, dotR: 7, dim: true });
}

// --- course
async function loadCourse(){
  const r = await fetch('/course/' + COURSE_ID + '?polyline=1', { cache: 'force-cache' }); const j = await r.json(); const c = j.course || j; if (!c.polyline) throw new Error('course payload');
  const pl = c.polyline; const lons = pl.map(p => p[0]), lats = pl.map(p => p[1]);
  const minLon = Math.min(...lons), maxLon = Math.max(...lons), minLat = Math.min(...lats), maxLat = Math.max(...lats);
  const center = [(minLon+maxLon)/2, (minLat+maxLat)/2];
  let zoom = 13; for (let z = 15; z >= 10; z--) { const a = proj(minLon, maxLat, z), b = proj(maxLon, minLat, z); if ((b[0]-a[0])*256 < 560 && (b[1]-a[1])*256 < 520) { zoom = z; break; } }
  const kmPoints = []; for (let k = 0; k <= 42; k++) { let best = pl[0]; for (const p of pl) if (Math.abs(p[2]-k*1000) < Math.abs(best[2]-k*1000)) best = p; kmPoints[k] = { km: k, lon: best[0], lat: best[1] }; }
  state.course = { polyline: pl, km: c.km, kmPoints, center, zoom, totalM: c.totalM || 42195, name: c.name };
  $('race').textContent = c.name + ' · ' + c.date;
}
function courseMetres(g){ const pl = state.course.polyline; let best = null, bd = 1e12; for (const p of pl) { const dx = (p[0]-g[0])*Math.cos(g[1]*PI/180)*111320, dy = (p[1]-g[1])*110540; const d = dx*dx+dy*dy; if (d < bd) { bd = d; best = p; } } return { m: best[2], off: Math.sqrt(bd) }; }

// --- feed
function who(ev){ const v = (ev.data && (ev.data.voiceId || '')) || ''; const src = (ev.data && ev.data.source) || ''; if (src === 'home' || ev.type === 'home.readout' || v.startsWith('Awx8')) return ['home', 'HOME BASE']; if (v.startsWith('qXT8')) return ['jessica', 'JESSICA']; if (v.startsWith('lKMA') || src.startsWith('script') || src === 'fallback') return ['ricky', 'RICKY']; return ['sys', ev.type.toUpperCase()]; }
function ingest(ev){
  state.events.push(ev); const d = ev.data || {};
  if (ev.type === 'gps' && d.lat && d.lon) { const g = wgs2gcj(parseFloat(d.lon), parseFloat(d.lat)); state.fixes.push({ t: ev.t, g, kmh: parseFloat(d.kmh) || null, hr: parseInt(d.hr) || null }); if (state.fixes.length > 9000) state.fixes.shift(); }
  else if (ev.type === 'metrics') state.last.metrics = { t: ev.t, d: parseFloat(d.d) || 0, p: parseFloat(d.p) || null, hr: parseFloat(d.hr) || null };
  else if (ev.type === 'battery') state.last.battery = { watch: d.watch, phone: d.phone };
  else if (ev.type.startsWith('camera.')) { state.last.camera = ev; if (/battery|%/.test(ev.detail)) state.last.cameraBattery = ev.detail; }
  else if (ev.type === 'race.gate') state.gateT = ev.t;
  else if (ev.type === 'speech' || ev.type === 'home.readout') { const w = who(ev); state.lines.push({ t: ev.t, who: w, text: ev.detail }); if (state.lines.length > 60) state.lines.shift(); }
  else if (ev.type === 'run.end') state.ended = true;
  state.lastT = Math.max(state.lastT || 0, ev.t);
}
async function poll(){
  try {
    const r = await fetch('/live/feed?since=' + state.next + '&limit=4000', { cache: 'no-store' });
    if (r.status === 401) { location.href = '/'; return; }
    const j = await r.json(); if (!j.ok) throw new Error(j.error || 'feed');
    if (j.run && (!state.run || state.run.runId !== j.run.runId)) { state.events = []; state.fixes = []; state.lines = []; state.last = {}; state.gateT = null; state.next = 0; state.ended = false; }
    state.run = j.run; state.serverSkew = Date.now() - new Date(j.serverTime).getTime();
    for (const ev of j.events) ingest(ev); state.next = j.next; state.lastOK = Date.now(); state.fails = 0; err('');
    if (j.more) setTimeout(poll, 200); else setTimeout(poll, 8000);
  } catch (e) { state.fails++; err('feed: ' + (e && e.message ? e.message : e) + ' · retry ' + state.fails); setTimeout(poll, Math.min(30000, 2000 * state.fails)); }
  render(); requestRedraw();
}

// --- render numbers
const fmtT = (s) => { s = Math.max(0, Math.round(s)); const h = Math.floor(s/3600), m = Math.floor(s%3600/60), x = s%60; return h + ':' + String(m).padStart(2,'0') + ':' + String(x).padStart(2,'0'); };
const fmtP = (p) => (!p || !isFinite(p) || p <= 0 || p > 1800) ? '--:--' : Math.floor(p/60) + ':' + String(Math.round(p%60)).padStart(2,'0');
function render(){
  const run = state.run;
  const badge = $('badge');
  if (!run) { badge.className = 'badge off'; badge.textContent = 'NO RACE RUN'; $('age').textContent = ''; return; }
  const age = run.lastEventAt ? Math.round((Date.now() - state.serverSkew - new Date(run.lastEventAt).getTime())/1000) : null;
  if (run.endedAt || state.ended) { badge.className = 'badge'; badge.textContent = 'ENDED'; }
  else if (age !== null && age < 60) { badge.className = 'badge live'; badge.textContent = 'LIVE'; }
  else if (age !== null && age < 240) { badge.className = 'badge stale'; badge.textContent = 'STALE'; }
  else { badge.className = 'badge off'; badge.textContent = 'NO SIGNAL'; }
  $('age').textContent = age === null ? '' : ('last data ' + (age < 60 ? age + 's' : Math.round(age/60) + 'min') + ' ago');
  $('uplink').textContent = age === null ? '--' : (age < 60 ? 'ok' : 'silent ' + fmtT(age));
  const m = state.last.metrics; const lastT = state.lastT || 0;
  const raceStart = state.gateT !== null ? state.gateT : 0;
  const el = Math.max(0, lastT - raceStart);
  $('elapsed').textContent = fmtT(el); $('elapsedL').textContent = state.gateT !== null ? 'race clock (from the gate)' : 'session clock (gate not pressed)';
  $('gate').textContent = state.gateT !== null ? ('pressed at ' + fmtT(state.gateT) + ' of session') : 'not yet';
  if (m) {
    $('dist').textContent = (m.d/1000).toFixed(2); $('pace').textContent = fmtP(m.p); $('hr').textContent = m.hr ? Math.round(m.hr) : '--';
    const avg = m.d > 200 ? el / (m.d/1000) : null; $('avg').textContent = fmtP(avg);
    const total = state.course ? state.course.totalM : 42195;
    $('eta').textContent = avg ? fmtT(el + (total - m.d)/1000*avg) : '--:--:--';
    $('togo').textContent = ((total - m.d)/1000).toFixed(1) + ' km';
    if (state.course) { const next = state.course.km.find(k => k.km*1000 > m.d && k.stations && k.stations.length); $('station').textContent = next ? ('km ' + next.km + ' · ' + ((next.km*1000 - m.d)/1000).toFixed(1) + ' km') : '--'; }
  }
  const f = state.fixes[state.fixes.length-1];
  if (f && state.course) { const cm = courseMetres(f.g); const k = state.course.km[Math.min(42, Math.floor(cm.m/1000))]; $('ckm').textContent = 'km ' + (cm.m/1000).toFixed(1) + (cm.off > 80 ? ' (off course ' + Math.round(cm.off) + ' m)' : ''); $('where').innerHTML = '<b>' + (k.street || '') + '</b> ' + (k.district || '') + (k.landmarks && k.landmarks.length ? ' · ' + k.landmarks.slice(0,2).join(', ') : '') + '<br><span style="color:#8b98a8">' + (f.kmh ? f.kmh.toFixed(1) + ' km/h' : '') + (f.hr ? ' · ' + f.hr + ' bpm' : '') + ' · fix at ' + fmtT(f.t) + '</span>'; }
  const b = state.last.battery || {}; const cls = (v) => v === '' || v === undefined ? '' : (parseInt(v) <= 15 ? 'bad' : parseInt(v) <= 30 ? 'warn' : 'ok');
  $('bwatch').textContent = b.watch ? b.watch + '%' : '--'; $('bwatch').className = 'bat ' + cls(b.watch);
  $('bphone').textContent = b.phone ? b.phone + '%' : '--'; $('bphone').className = 'bat ' + cls(b.phone);
  const c = state.last.camera; $('camera').textContent = c ? (c.type.replace('camera.', '') + ' ' + c.detail).slice(0, 40) : '--';
  const tk = $('ticker'); tk.innerHTML = state.lines.slice(-6).map(l => '<div class="line"><span class="t">' + fmtT(l.t - raceStart) + '</span><span class="who ' + l.who[0] + '">' + l.who[1] + '</span><span>' + esc(l.text) + '</span></div>').join('');
}
const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
setInterval(() => { const d = new Date(); $('clock').textContent = d.toTimeString().slice(0, 8); render(); }, 1000);
setInterval(requestRedraw, 400);
window.addEventListener('resize', requestRedraw);
loadCourse().catch(e => { courseErr = 'course: ' + e.message; err(''); setTimeout(() => loadCourse().then(() => { courseErr = ''; err(''); requestRedraw(); }).catch(() => {}), 10000); }).then(() => { requestRedraw(); poll(); });
})();
</script>
</body></html>`;
