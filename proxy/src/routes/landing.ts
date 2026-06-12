/// Public one-page marketing site for AARC, served at the apex domain
/// aarun.club (host-based routing in src/index.ts).
///
/// Self-contained: inline CSS, inline JS, zero CDN deps, system fonts only.
/// The hero centrepiece is the GlassRipple liquid-glass overlay — the SVG
/// feDisplacementMap + backdrop-filter tap-ripple ported VERBATIM from
/// assets/index.html (the GlassRipple class, createLensMapGenerator, and
/// cubicBezier helpers are copied faithfully; their math is unchanged).
///
/// This page is PUBLIC. It describes the running coach only — it must not
/// mention any second voice or adult content.
///
/// NOTE for editors: the embedded ES-module JS uses template literals and
/// "${...}" (inside GlassRipple). Because LANDING_HTML is itself a TS
/// template literal, every backtick and "${" in the embedded JS is escaped
/// as \` and \${ so the whole thing compiles. Do NOT un-escape them.

export const LANDING_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="AARC is an AI running coach that actually talks to you — a savage British roast-coach reacting live to your pace, heart rate and music. iPhone + Apple Watch.">
<meta name="theme-color" content="#0b0b10">
<meta property="og:title" content="AARC — an AI running coach that actually talks to you">
<meta property="og:description" content="Ricky, a savage British roast-coach voice, reacting live to your pace, heart rate and music — on iPhone and Apple Watch.">
<meta property="og:type" content="website">
<title>AARC — an AI running coach that actually talks to you</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0b0b10;
    --bg-2: #0d0d12;
    --ink: #f4f4f7;
    --muted: #a6a6b3;
    --faint: #74748a;
    --line: #23232c;
    --accent: #ff5a36;
    --accent-2: #9896ff;
    --accent-3: #39d1f9;
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    background:
      radial-gradient(1100px 700px at 80% -10%, #1a1a2455 0, transparent 60%),
      radial-gradient(900px 600px at -10% 30%, #16161d77 0, transparent 55%),
      var(--bg);
    color: var(--ink);
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, "Apple Color Emoji", sans-serif;
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
    min-height: 100vh;
  }
  a { color: inherit; }
  .wrap { max-width: 1080px; margin: 0 auto; padding: 0 24px; }

  /* ---- top bar ---- */
  header.nav {
    position: sticky; top: 0; z-index: 50;
    backdrop-filter: blur(14px) saturate(140%);
    background: #0b0b10cc;
    border-bottom: 1px solid var(--line);
  }
  .nav .wrap {
    display: flex; align-items: center; justify-content: space-between;
    height: 64px;
  }
  .brand { display: flex; align-items: center; gap: 11px; font-weight: 700; letter-spacing: -0.01em; }
  .brand .mark {
    width: 32px; height: 32px; display: block;
    filter: drop-shadow(0 4px 14px #ff5a3640);
  }
  .brand .name { font-size: 17px; }
  .signin {
    text-decoration: none; font-weight: 600; font-size: 14px;
    color: var(--ink);
    border: 1px solid var(--line); background: #16161c;
    padding: 9px 16px; border-radius: 10px;
    transition: border-color .18s ease, background .18s ease, transform .18s ease;
  }
  .signin:hover { border-color: #3a3a48; background: #1c1c24; }
  .signin:active { transform: translateY(1px); }

  /* ---- hero ---- */
  .hero { padding: 84px 0 56px; }
  .hero .wrap { display: grid; grid-template-columns: 1.05fr 1fr; gap: 56px; align-items: center; }
  .eyebrow {
    display: inline-flex; align-items: center; gap: 8px;
    font-size: 12.5px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase;
    color: var(--accent); margin-bottom: 18px;
  }
  .eyebrow .pip { width: 6px; height: 6px; border-radius: 50%; background: var(--accent); box-shadow: 0 0 0 4px #ff5a3622; }
  h1.head {
    font-size: clamp(34px, 5vw, 52px); line-height: 1.04; letter-spacing: -0.025em;
    margin: 0 0 18px; font-weight: 800;
  }
  h1.head .glow { color: transparent; background: linear-gradient(120deg, #fff, #cfcfe6 40%, var(--accent-2)); -webkit-background-clip: text; background-clip: text; }
  .lede { font-size: 18px; color: var(--muted); max-width: 30rem; margin: 0 0 28px; }
  .cta-row { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
  .cta {
    text-decoration: none; font-weight: 700; font-size: 15px;
    background: linear-gradient(150deg, var(--accent), #ff7a36);
    color: #160a05; padding: 14px 22px; border-radius: 12px;
    box-shadow: 0 8px 28px #ff5a3640, inset 0 0 0 1px #ffffff2a;
    transition: transform .18s ease, box-shadow .18s ease;
  }
  .cta:hover { transform: translateY(-1px); box-shadow: 0 12px 34px #ff5a3655, inset 0 0 0 1px #ffffff33; }
  .cta:active { transform: translateY(0); }
  .cta-note { font-size: 13.5px; color: var(--faint); }

  /* ---- waitlist / "I'm interested" capture ---- */
  .wl { width: 100%; max-width: 30rem; }
  .wl-form { display: flex; gap: 9px; flex-wrap: wrap; align-items: stretch; }
  .wl-email {
    flex: 1 1 14rem; min-width: 0;
    font: 500 15px/1 inherit; color: var(--ink);
    background: #14141b; border: 1px solid var(--line); border-radius: 12px;
    padding: 14px 16px; outline: none;
    transition: border-color .18s ease, background .18s ease;
  }
  .wl-email::placeholder { color: var(--faint); }
  .wl-email:focus { border-color: #4a3a3a; background: #181820; }
  .wl-form .cta { border: 0; cursor: pointer; white-space: nowrap; font-family: inherit; }
  .wl-form .cta:disabled { opacity: .6; cursor: default; transform: none; }
  .wl-msg { flex-basis: 100%; font-size: 13.5px; color: var(--faint); min-height: 1.1em; margin-top: 2px; }
  .wl-msg.ok { color: var(--accent-3); }
  .wl-msg.err { color: #ff7a6a; }
  .wl-note { font-size: 13px; color: var(--faint); margin-top: 11px; }
  .wl-note a { color: var(--muted); text-decoration: underline; text-underline-offset: 2px; }

  /* ---- hero glass scene (GlassRipple target) ---- */
  .stage { display: flex; justify-content: center; }
  .scene {
    position: relative;
    width: 100%; max-width: 420px; aspect-ratio: 4 / 5;
    border-radius: 26px; overflow: hidden; cursor: pointer;
    background:
      radial-gradient(circle at 22% 22%, #9896ff4d 0 18%, transparent 42%),
      radial-gradient(circle at 82% 18%, #39d1f94d 0 16%, transparent 42%),
      radial-gradient(circle at 72% 84%, #ff5a3640 0 22%, transparent 48%),
      linear-gradient(150deg, #16161f, #0a0a0f);
    box-shadow: 0 30px 80px #00000088, 0 0 0 1px #2a2a32;
    user-select: none;
  }
  .scene .grid {
    position: absolute; inset: 0;
    background-image:
      linear-gradient(#ffffff10 1px, transparent 1px),
      linear-gradient(90deg, #ffffff10 1px, transparent 1px);
    background-size: 38px 38px;
    mask-image: radial-gradient(120% 120% at 50% 30%, #000 40%, transparent 100%);
  }
  .scene .content { position: relative; height: 100%; padding: 26px; display: flex; flex-direction: column; }
  .watch-row { display: flex; align-items: center; gap: 9px; font-size: 12.5px; color: #c8c8d6; }
  .watch-row .ring { width: 10px; height: 10px; border-radius: 50%; border: 2px solid var(--accent-3); box-shadow: 0 0 12px #39d1f988; }
  .pace-block { margin-top: auto; }
  .pace-label { font-size: 12px; letter-spacing: 0.14em; text-transform: uppercase; color: var(--faint); margin-bottom: 4px; }
  .pace-val { font-size: 46px; font-weight: 800; letter-spacing: -0.03em; line-height: 1; font-variant-numeric: tabular-nums; }
  .pace-val small { font-size: 17px; font-weight: 600; color: var(--muted); margin-left: 6px; letter-spacing: 0; }
  .hr-chips { display: flex; gap: 8px; margin-top: 16px; flex-wrap: wrap; }
  .hr-chip {
    padding: 6px 12px; border-radius: 999px; font-size: 12.5px; font-weight: 600;
    background: #ffffff14; border: 1px solid #ffffff26; color: #e7e7f0;
  }
  .hr-chip.beat { color: var(--accent); border-color: #ff5a3655; background: #ff5a3618; }
  .coach-quote {
    margin-top: 18px; padding: 13px 15px; border-radius: 14px;
    background: linear-gradient(180deg, #ffffff14, #ffffff08);
    border: 1px solid #ffffff20;
    font-size: 13.5px; line-height: 1.45; color: #eaeaf2;
  }
  .coach-quote .who { display: block; font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; color: var(--accent); margin-bottom: 3px; }
  .glass-overlay { position: absolute; inset: 0; pointer-events: none; z-index: 10; border-radius: 26px; }
  .tap-hint {
    position: absolute; left: 0; right: 0; bottom: 12px; text-align: center;
    font-size: 11.5px; letter-spacing: 0.05em; color: #ffffff66; z-index: 11; pointer-events: none;
    transition: opacity .4s ease;
  }

  /* ---- feature row ---- */
  .features { padding: 28px 0 76px; }
  .feature-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
  .feature {
    border: 1px solid var(--line); background: linear-gradient(180deg, #14141a, #0e0e13);
    border-radius: 16px; padding: 22px 20px;
    transition: border-color .18s ease, transform .18s ease;
  }
  .feature:hover { border-color: #34343f; transform: translateY(-2px); }
  .feature .ico { width: 34px; height: 34px; margin-bottom: 14px; }
  .feature h3 { margin: 0 0 6px; font-size: 15.5px; font-weight: 700; letter-spacing: -0.01em; }
  .feature p { margin: 0; font-size: 13.5px; color: var(--muted); line-height: 1.5; }

  /* ---- closing band ---- */
  .band { border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); background: #0c0c11; padding: 60px 0; }
  .band .wrap { text-align: center; }
  .band h2 { font-size: clamp(24px, 3.5vw, 34px); letter-spacing: -0.02em; margin: 0 0 12px; font-weight: 800; }
  .band p { color: var(--muted); max-width: 34rem; margin: 0 auto 26px; }

  footer { padding: 34px 0 48px; }
  footer .wrap { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 12px; color: var(--faint); font-size: 13px; }
  footer .dot { color: #44444f; }

  @media (max-width: 860px) {
    .hero .wrap { grid-template-columns: 1fr; gap: 40px; }
    .hero { padding: 56px 0 40px; }
    .stage { order: -1; }
    .feature-grid { grid-template-columns: repeat(2, 1fr); }
  }
  @media (max-width: 480px) {
    .feature-grid { grid-template-columns: 1fr; }
  }
  @media (prefers-reduced-motion: reduce) {
    html { scroll-behavior: auto; }
    .feature, .signin, .cta { transition: none; }
  }
</style>
</head>
<body>

<header class="nav">
  <div class="wrap">
    <div class="brand">
      <svg class="mark" viewBox="0 0 40 40" width="32" height="32" aria-hidden="true">
        <defs>
          <linearGradient id="aarcLg" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stop-color="#ff8a4c"/>
            <stop offset="1" stop-color="#ff4f2e"/>
          </linearGradient>
        </defs>
        <rect x="1.5" y="1.5" width="37" height="37" rx="11" fill="url(#aarcLg)"/>
        <rect x="1.5" y="1.5" width="37" height="37" rx="11" fill="none" stroke="#fff" stroke-opacity=".18"/>
        <g stroke="#fff" stroke-linecap="round" fill="none">
          <line x1="6.5" y1="15" x2="12.5" y2="15" stroke-width="2.1" stroke-opacity=".5"/>
          <line x1="5.5" y1="20.5" x2="13.5" y2="20.5" stroke-width="2.1" stroke-opacity=".72"/>
          <line x1="7.5" y1="26" x2="11.5" y2="26" stroke-width="2.1" stroke-opacity=".4"/>
        </g>
        <path d="M15.5 29.5 L23 11.5 L30.5 29.5" fill="none" stroke="#fff" stroke-width="3.3" stroke-linejoin="round" stroke-linecap="round"/>
        <line x1="19" y1="23.4" x2="27" y2="23.4" stroke="#fff" stroke-width="2.9" stroke-linecap="round"/>
      </svg>
      <span class="name">AARC</span>
    </div>
    <a class="signin" href="https://my.aarun.club">Sign in</a>
  </div>
</header>

<section class="hero">
  <div class="wrap">
    <div class="copy">
      <span class="eyebrow"><span class="pip"></span>iPhone &amp; Apple Watch</span>
      <h1 class="head">An AI running coach that <span class="glow">actually talks to you.</span></h1>
      <p class="lede">
        Meet Ricky — a savage British roast-coach who reacts <em>live</em> to your pace,
        your heart rate and the music in your ears. Real lines. Real timing. Mid-run.
      </p>
      <div class="wl">
        <form class="wl-form" data-source="hero" novalidate>
          <input class="wl-email" type="email" inputmode="email" autocomplete="email"
                 placeholder="you@email.com" aria-label="Email address" required>
          <button class="cta" type="submit">I&rsquo;m interested</button>
          <div class="wl-msg" role="status" aria-live="polite"></div>
        </form>
        <p class="wl-note">Not public yet. Leave your email and I&rsquo;ll tell you the moment it&rsquo;s ready &mdash; no spam.
          Already in? <a href="https://my.aarun.club">Sign in</a>.</p>
      </div>
    </div>

    <div class="stage">
      <div class="scene" id="scene">
        <div class="grid"></div>
        <div class="content">
          <div class="watch-row"><span class="ring"></span>Apple Watch &middot; auto-launched</div>
          <div class="pace-block">
            <div class="pace-label">Current pace</div>
            <div class="pace-val">4:52<small>/km</small></div>
            <div class="hr-chips">
              <span class="hr-chip beat">&#9829; 168 bpm</span>
              <span class="hr-chip">3.4 km</span>
              <span class="hr-chip">&#9834; in time</span>
            </div>
            <div class="coach-quote">
              <span class="who">Ricky</span>
              That last split was almost respectable. Don&rsquo;t let it go to your head, sunshine.
            </div>
          </div>
        </div>
        <div class="glass-overlay" id="glass-overlay"></div>
        <div class="tap-hint" id="tap-hint">tap the glass</div>
      </div>
    </div>
  </div>
</section>

<section class="features">
  <div class="wrap">
    <div class="feature-grid">
      <div class="feature">
        <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="#ff5a36" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h3l2 6 4-14 2 8h4"/></svg>
        <h3>Live roast coaching</h3>
        <p>Ricky watches every split and reacts in real time — praise when you earn it, a roast when you don&rsquo;t.</p>
      </div>
      <div class="feature">
        <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="#39d1f9" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/></svg>
        <h3>Music-aware</h3>
        <p>Knows what&rsquo;s playing in your ears and times the banter around it, never over it.</p>
      </div>
      <div class="feature">
        <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="#9896ff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="4" width="12" height="16" rx="3"/><path d="M9 2h6M9 22h6"/><circle cx="12" cy="12" r="3"/></svg>
        <h3>Watch-native</h3>
        <p>Start on the phone and the Apple Watch launches itself — pace, heart rate and coaching, hands-free.</p>
      </div>
      <div class="feature">
        <svg class="ico" viewBox="0 0 24 24" fill="none" stroke="#ffb03a" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v5h5"/><path d="M3.05 13A9 9 0 1 0 6 5.3L3 8"/><path d="M12 7v5l3 2"/></svg>
        <h3>Full run replay</h3>
        <p>Every run is recorded — pace, heart rate and every line Ricky said, replayable end to end.</p>
      </div>
    </div>
  </div>
</section>

<section class="band">
  <div class="wrap">
    <h2>Lace up. Get roasted. Run faster.</h2>
    <p>AARC turns a solo run into a conversation — one that&rsquo;s funnier, sharper and more honest than the voice in your own head.</p>
    <div class="wl" style="margin: 0 auto;">
      <form class="wl-form" data-source="band" novalidate>
        <input class="wl-email" type="email" inputmode="email" autocomplete="email"
               placeholder="you@email.com" aria-label="Email address" required>
        <button class="cta" type="submit">Keep me posted</button>
        <div class="wl-msg" role="status" aria-live="polite"></div>
      </form>
    </div>
  </div>
</section>

<footer>
  <div class="wrap">
    <span>&copy; 2026 AARC</span>
    <span class="dot">&bull;</span>
    <span>aarun.club</span>
  </div>
</footer>

<script type="module">
// ===========================================================================
// GlassRipple — liquid-glass tap ripple overlay. Ported VERBATIM from
// assets/index.html (zero deps, single file, no WebGL). All motion constants
// and the displacement-map math are the originals; do not rewrite.
// ===========================================================================
const SVG_NS = "http://www.w3.org/2000/svg";
const LAYER_COUNT = 5;
const DEFAULT_EASE = [0.22, 1, 0.36, 1];
const MAP_SIZE = 128;
const SQRT_PI = 1.7724538509;

function erf(x) {
  return Math.tanh(SQRT_PI * x);
}

export function createLensMapGenerator() {
  let canvas = null;
  let ctx = null;
  let imageData = null;

  function ensure() {
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.width = MAP_SIZE;
      canvas.height = MAP_SIZE;
      ctx = canvas.getContext("2d");
      imageData = ctx.createImageData(MAP_SIZE, MAP_SIZE);
    }
    return { canvas, ctx, imageData };
  }

  return {
    generatePixelsOnly(params) {
      const { ctx, imageData } = ensure();
      const {
        lensHalfWidth: hw,
        lensHalfHeight: hh,
        borderRadius,
        depth,
        sdfBoundary,
        edgeFalloff,
      } = params;
      const data = imageData.data;
      const half = MAP_SIZE / 2;
      const radius = Math.min(borderRadius, Math.min(hw, hh));
      const innerW = Math.max(0, hw - depth);
      const innerH = Math.max(0, hh - depth);
      const innerR = Math.max(0, Math.min(borderRadius, Math.min(innerW, innerH)));
      const invDepth = depth > 0 ? 1 / (depth * Math.SQRT2) : 1e6;
      const stepX = (2 * hw) / MAP_SIZE;
      const stepY = (2 * hh) / MAP_SIZE;
      const invHw = 1 / hw;
      const invHh = 1 / hh;

      for (let py = 0; py < half; py++) {
        const my = MAP_SIZE - 1 - py;
        const ly = -((py + 0.5) * stepY - hh);
        const sdfY = ly - hh + radius;
        const fallY = edgeFalloff ? ly - innerH + innerR : 0;
        const gradYRaw = ly * invHh;
        const gradY = gradYRaw > 1 ? 1 : gradYRaw;

        for (let px = 0; px < half; px++) {
          const mx = MAP_SIZE - 1 - px;
          const lx = -((px + 0.5) * stepX - hw);
          const sdfX = lx - hw + radius;
          const dx = sdfX > 0 ? sdfX : 0;
          const dy = sdfY > 0 ? sdfY : 0;
          const sdf =
            Math.sqrt(dx * dx + dy * dy) +
            (sdfX > sdfY ? (sdfX > 0 ? 0 : sdfX) : sdfY > 0 ? 0 : sdfY) -
            radius;
          const iTL = (MAP_SIZE * py + px) * 4;
          const iTR = (MAP_SIZE * py + mx) * 4;
          const iBL = (MAP_SIZE * my + px) * 4;
          const iBR = (MAP_SIZE * my + mx) * 4;

          if (!sdfBoundary || sdf < 0) {
            const gradXRaw = lx * invHw;
            const gradX = gradXRaw > 1 ? 1 : gradXRaw;
            let falloff;
            if (edgeFalloff) {
              const fx = lx - innerW + innerR;
              const cx = fx > 0 ? fx : 0;
              const cy = fallY > 0 ? fallY : 0;
              const innerSdf =
                Math.sqrt(cx * cx + cy * cy) +
                (fx > fallY ? (fx > 0 ? 0 : fx) : fallY > 0 ? 0 : fallY) -
                innerR;
              falloff = 0.5 * (1 + erf(innerSdf * invDepth));
            } else {
              falloff = 1;
            }
            const dispX = 0.5 * gradX * falloff;
            const dispY = 0.5 * gradY * falloff;
            const rPos = ((0.5 + dispX) * 255 + 0.5) | 0;
            const rNeg = ((0.5 - dispX) * 255 + 0.5) | 0;
            const gPos = ((0.5 + dispY) * 255 + 0.5) | 0;
            const gNeg = ((0.5 - dispY) * 255 + 0.5) | 0;
            data[iTL] = rPos; data[iTL + 1] = gPos; data[iTL + 2] = 128; data[iTL + 3] = 255;
            data[iTR] = rNeg; data[iTR + 1] = gPos; data[iTR + 2] = 128; data[iTR + 3] = 255;
            data[iBL] = rPos; data[iBL + 1] = gNeg; data[iBL + 2] = 128; data[iBL + 3] = 255;
            data[iBR] = rNeg; data[iBR + 1] = gNeg; data[iBR + 2] = 128; data[iBR + 3] = 255;
          } else {
            data[iTL] = 128; data[iTL + 1] = 128; data[iTL + 2] = 128; data[iTL + 3] = 0;
            data[iTR] = 128; data[iTR + 1] = 128; data[iTR + 2] = 128; data[iTR + 3] = 0;
            data[iBL] = 128; data[iBL + 1] = 128; data[iBL + 2] = 128; data[iBL + 3] = 0;
            data[iBR] = 128; data[iBR + 1] = 128; data[iBR + 2] = 128; data[iBR + 3] = 0;
          }
        }
      }
      ctx.putImageData(imageData, 0, 0);
    },
    getCanvas: () => canvas,
    dispose() {
      if (canvas) {
        canvas.width = 0;
        canvas.height = 0;
        canvas = null;
      }
      ctx = null;
      imageData = null;
    },
  };
}

export function cubicBezier(x1, y1, x2, y2) {
  const sampleX = (t) => ((1 - 3 * x2 + 3 * x1) * t * t * t) + ((3 * x2 - 6 * x1) * t * t) + (3 * x1 * t);
  const sampleY = (t) => ((1 - 3 * y2 + 3 * y1) * t * t * t) + ((3 * y2 - 6 * y1) * t * t) + (3 * y1 * t);
  const sampleDX = (t) => 3 * (1 - 3 * x2 + 3 * x1) * t * t + 2 * (3 * x2 - 6 * x1) * t + 3 * x1;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const dx = sampleDX(t);
      if (Math.abs(dx) < 1e-6) break;
      t -= (sampleX(t) - x) / dx;
    }
    if (t < 0 || t > 1) {
      let lo = 0, hi = 1;
      t = x;
      while (hi - lo > 1e-6) {
        t = (lo + hi) / 2;
        if (sampleX(t) < x) lo = t;
        else hi = t;
      }
    }
    return sampleY(t);
  };
}

function el(name, attrs) {
  const node = document.createElementNS(SVG_NS, name);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  return node;
}

let uidCounter = 0;

export class GlassRipple {
  constructor(target, {
    mode = "backdrop",
    maxDisplacement = 24,
    chromaAmount = 1,
    depth = 30,
    duration = 6000,
    ease = DEFAULT_EASE,
    halfSize = null,
    sizeTo = 2.2,
    rampSize = null,
    startSize = 4,
    bindPointer = false,
  } = {}) {
    this.target = target;
    this.mode = mode;
    this.config = { maxDisplacement, chromaAmount, depth, duration, ease, halfSize, sizeTo, rampSize, startSize };
    this._ease = cubicBezier(...ease);
    this._uid = \`glass-ripple-\${++uidCounter}\`;

    this.layers = Array.from({ length: LAYER_COUNT }, () => ({
      active: false,
      x: 0,
      y: 0,
      v: 0,
      start: 0,
      seq: 0,
      gen: createLensMapGenerator(),
    }));
    this._next = 0;
    this._seq = 0;
    this._raf = 0;
    this._composite = null;
    this._compositeCtx = null;

    this._buildFilter();
    this._rect = { w: 0, h: 0 };
    this._resize = new ResizeObserver(() => this._updateRegion());
    this._resize.observe(target);
    this._updateRegion();

    const prop = mode === "backdrop" ? "backdropFilter" : "filter";
    this._filterProp = prop;
    this._prevFilter = target.style[prop];
    target.style[prop] = \`url(#\${this._uid})\`;
    target.style.willChange = prop === "backdropFilter" ? "backdrop-filter" : "filter";

    this._onPointerDown = null;
    if (bindPointer) {
      this._onPointerDown = (e) => {
        const r = this.target.getBoundingClientRect();
        this.ripple(e.clientX - r.left, e.clientY - r.top);
      };
      target.addEventListener("pointerdown", this._onPointerDown);
    }
  }

  _buildFilter() {
    this._svg = el("svg", { width: 0, height: 0, "aria-hidden": "true" });
    this._svg.style.position = "absolute";
    const filter = el("filter", {
      id: this._uid,
      filterUnits: "userSpaceOnUse",
      primitiveUnits: "userSpaceOnUse",
      "color-interpolation-filters": "sRGB",
      x: 0,
      y: 0,
      width: 0,
      height: 0,
    });
    filter.append(
      el("feFlood", { "flood-color": "rgb(128,128,128)", result: "neutral" }),
      el("feImage", { result: "map", preserveAspectRatio: "none", x: 0, y: 0, width: 0, height: 0 }),
      el("feComposite", { in: "map", in2: "neutral", operator: "over", result: "dispMap" })
    );
    this._feImage = filter.querySelector("feImage");
    this._dispMaps = [];
    if (this.config.chromaAmount > 0) {
      const passes = [
        ["R", "1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 0 1"],
        ["G", "0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 0 1"],
        ["B", "0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 0 1"],
      ];
      for (const [ch, matrix] of passes) {
        const disp = el("feDisplacementMap", {
          in: "SourceGraphic",
          in2: "dispMap",
          scale: 0,
          xChannelSelector: "R",
          yChannelSelector: "G",
          result: \`d\${ch}\`,
        });
        this._dispMaps.push(disp);
        filter.append(disp, el("feColorMatrix", { in: \`d\${ch}\`, type: "matrix", values: matrix, result: \`c\${ch}\` }));
      }
      filter.append(
        el("feBlend", { in: "cR", in2: "cG", mode: "screen", result: "cRG" }),
        el("feBlend", { in: "cRG", in2: "cB", mode: "screen" })
      );
    } else {
      const disp = el("feDisplacementMap", {
        in: "SourceGraphic",
        in2: "dispMap",
        scale: 0,
        xChannelSelector: "R",
        yChannelSelector: "G",
        result: "displaced",
      });
      this._dispMaps.push(disp);
      filter.append(disp, el("feColorMatrix", {
        in: "displaced",
        type: "matrix",
        values: "1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 1 0",
      }));
    }
    this._filter = filter;
    const defs = el("defs", {});
    defs.append(filter);
    this._svg.append(defs);
    document.body.append(this._svg);
  }

  _updateRegion() {
    const r = this.target.getBoundingClientRect();
    this._rect = { w: r.width, h: r.height };
    const margin = this.config.maxDisplacement * 3 + 8;
    this._filter.setAttribute("x", -margin);
    this._filter.setAttribute("y", -margin);
    this._filter.setAttribute("width", r.width + 2 * margin);
    this._filter.setAttribute("height", r.height + 2 * margin);
  }

  _halfSize() {
    return this.config.halfSize ?? 0.54 * Math.max(this._rect.w, this._rect.h);
  }

  _rampSize() {
    return this.config.rampSize ?? Math.min(this._rect.w, this._rect.h);
  }

  ripple(x = this._rect.w / 2, y = this._rect.h / 2) {
    const layer = this.layers[this._next];
    this._next = (this._next + 1) % LAYER_COUNT;
    layer.active = true;
    layer.x = x;
    layer.y = y;
    layer.v = this.config.startSize;
    layer.start = performance.now();
    layer.seq = ++this._seq;
    if (!this._raf) this._raf = requestAnimationFrame((t) => this._frame(t));
  }

  update(config) {
    const needsRebuild =
      config.chromaAmount !== undefined &&
      (config.chromaAmount > 0) !== (this.config.chromaAmount > 0);
    Object.assign(this.config, config);
    if (config.ease) this._ease = cubicBezier(...config.ease);
    if (needsRebuild) {
      this._svg.remove();
      this._buildFilter();
      this._updateRegion();
    }
  }

  _frame(now) {
    this._raf = 0;
    const { duration, startSize, sizeTo, depth } = this.config;
    const target = sizeTo * this._halfSize();
    const live = [];
    let anyActive = false;
    for (const layer of this.layers) {
      if (!layer.active) continue;
      const t = Math.min((now - layer.start) / duration, 1);
      if (t >= 1) {
        layer.active = false;
        continue;
      }
      anyActive = true;
      layer.v = startSize + (target - startSize) * this._ease(t);
      if (layer.v > 3) live.push(layer);
    }

    if (live.length === 0) {
      for (const d of this._dispMaps) d.setAttribute("scale", 0);
    } else {
      for (const layer of live) {
        layer.gen.generatePixelsOnly({
          lensHalfWidth: layer.v,
          lensHalfHeight: layer.v,
          borderRadius: layer.v,
          depth,
          sdfBoundary: true,
          edgeFalloff: true,
        });
      }
      this._apply(live);
    }

    if (anyActive) this._raf = requestAnimationFrame((t) => this._frame(t));
  }

  _apply(live) {
    let canvas, rect;
    if (live.length === 1) {
      const l = live[0];
      canvas = l.gen.getCanvas();
      rect = [l.x - l.v, l.y - l.v, 2 * l.v, 2 * l.v];
    } else {
      if (!this._composite) {
        this._composite = document.createElement("canvas");
        this._composite.width = MAP_SIZE;
        this._composite.height = MAP_SIZE;
        this._compositeCtx = this._composite.getContext("2d");
      }
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const l of live) {
        x0 = Math.min(x0, l.x - l.v);
        y0 = Math.min(y0, l.y - l.v);
        x1 = Math.max(x1, l.x + l.v);
        y1 = Math.max(y1, l.y + l.v);
      }
      const ctx = this._compositeCtx;
      ctx.globalCompositeOperation = "source-over";
      ctx.clearRect(0, 0, MAP_SIZE, MAP_SIZE);
      ctx.fillStyle = "rgb(128,128,128)";
      ctx.fillRect(0, 0, MAP_SIZE, MAP_SIZE);
      const sx = MAP_SIZE / (x1 - x0);
      const sy = MAP_SIZE / (y1 - y0);
      for (const l of [...live].sort((a, b) => a.seq - b.seq)) {
        ctx.drawImage(
          l.gen.getCanvas(),
          (l.x - l.v - x0) * sx,
          (l.y - l.v - y0) * sy,
          2 * l.v * sx,
          2 * l.v * sy
        );
      }
      canvas = this._composite;
      rect = [x0, y0, x1 - x0, y1 - y0];
    }

    this._feImage.setAttribute("href", canvas.toDataURL());
    this._feImage.setAttribute("x", rect[0]);
    this._feImage.setAttribute("y", rect[1]);
    this._feImage.setAttribute("width", rect[2]);
    this._feImage.setAttribute("height", rect[3]);

    const maxV = Math.max(...live.map((l) => l.v));
    const ramp = Math.min((2 * maxV) / this._rampSize(), 1);
    const base = this.config.maxDisplacement * ramp;
    const c = this.config.chromaAmount;
    const scales = this._dispMaps.length === 3 ? [base * (1 + 2 * c), base * (1 + c), base] : [base];
    this._dispMaps.forEach((d, i) => d.setAttribute("scale", scales[i]));
  }

  get active() {
    return this.layers.some((l) => l.active);
  }

  dispose() {
    if (this._raf) cancelAnimationFrame(this._raf);
    this._raf = 0;
    if (this._onPointerDown) this.target.removeEventListener("pointerdown", this._onPointerDown);
    this._resize.disconnect();
    this.target.style[this._filterProp] = this._prevFilter;
    this.target.style.willChange = "";
    this._svg.remove();
    for (const layer of this.layers) layer.gen.dispose();
  }
}

export default GlassRipple;

// ===========================================================================
// Hero wiring — GlassRipple over the AARC scene panel.
// ===========================================================================
const overlay = document.getElementById("glass-overlay");
const scene = document.getElementById("scene");
const hint = document.getElementById("tap-hint");

if (overlay && scene && "backdropFilter" in document.body.style) {
  const ripple = new GlassRipple(overlay, {
    maxDisplacement: 22,
    chromaAmount: 1,
    depth: 30,
    duration: 5200,
  });

  let tapped = false;
  scene.addEventListener("pointerdown", (e) => {
    const r = overlay.getBoundingClientRect();
    ripple.ripple(e.clientX - r.left, e.clientY - r.top);
    if (!tapped) { tapped = true; if (hint) hint.style.opacity = "0"; }
  });

  // A gentle opening ripple from centre so the effect is discoverable.
  window.addEventListener("load", () => {
    const r = overlay.getBoundingClientRect();
    setTimeout(() => ripple.ripple(r.width / 2, r.height * 0.42), 700);
  });
} else if (hint) {
  // No backdrop-filter support (e.g. some non-Chromium engines): hide the
  // tap hint; the scene still reads as a static branded panel.
  hint.style.display = "none";
}
</script>

<script>
// Waitlist capture — posts {email, source} to /api/waitlist and reports inline.
(function () {
  var EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
  var forms = document.querySelectorAll(".wl-form");
  for (var i = 0; i < forms.length; i++) wire(forms[i]);

  function wire(form) {
    var input = form.querySelector(".wl-email");
    var btn = form.querySelector(".cta");
    var msg = form.querySelector(".wl-msg");
    var done = false;
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (done) return;
      var email = (input.value || "").trim();
      if (!EMAIL_RE.test(email)) {
        show("err", "That doesn’t look like an email address.");
        input.focus();
        return;
      }
      btn.disabled = true;
      var label = btn.textContent;
      btn.textContent = "…";
      show("", "");
      fetch("/api/waitlist", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: email, source: form.getAttribute("data-source") || "site" })
      }).then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (res) {
          if (res.ok && res.j && res.j.ok) {
            done = true;
            input.disabled = true;
            btn.style.display = "none";
            show("ok", "You’re on the list — I’ll be in touch. 🏃");
          } else {
            btn.disabled = false; btn.textContent = label;
            show("err", "Couldn’t save that. Try again in a moment.");
          }
        })
        .catch(function () {
          btn.disabled = false; btn.textContent = label;
          show("err", "Network hiccup — try again.");
        });
    });
    function show(cls, text) {
      msg.className = "wl-msg" + (cls ? " " + cls : "");
      msg.textContent = text;
    }
  }
})();
</script>
</body>
</html>
`;

/// GET / on the apex host (aarun.club). Returns the marketing page.
export async function landingHandler(_request: Request, _env: unknown): Promise<Response> {
    return new Response(LANDING_HTML, {
        status: 200,
        headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "public, max-age=300",
        },
    });
}
