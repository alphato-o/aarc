/* AARC iPhone 18 Pro mockup with a live replica of ActiveRunView.
   Usage: AARCPhone.mount(el, { mapSrc: 'london.webp' }) -> { destroy() }
   Subscribes to window.AARC_SIM (see CONTRACT.md). */
(function () {
  'use strict';

  // Hyde Park loop on london.jpg (2400x1840), image px x10, flat [x,y,x,y,...].
  var ROUTE_RAW = [18640,5131,18619,5184,18564,5369,18535,5429,18439,5532,18345,5574,18214,5592,17844,5584,15125,5651,12794,5725,12808,5876,12823,6027,12253,6176,12253,6176,11620,6348,11308,6415,11004,6463,10803,6487,10586,6495,10411,6429,10256,6546,10197,6575,9993,6595,9437,6669,9349,6659,9299,6625,9241,6652,9095,6679,8903,6766,8696,6824,8326,6977,8326,6977,8179,7038,7995,7046,7651,7026,7606,7034,7495,7100,7392,7235,7307,7309,7292,7304,7276,7270,7248,7274,7221,7277,7224,7295,7245,7465,7306,7636,7686,8394,7736,8454,7795,8495,7769,8548,7754,8605,7724,8618,7583,8712,7505,8784,7329,8951,7268,9240,7223,9554,7189,9654,7059,9838,6768,10146,6696,10217,6483,10382,6434,10432,6382,10541,6292,10965,6076,12405,6076,12405,6067,12465,6242,12536,6692,12716,6738,12721,7208,12641,7421,12601,7578,12795,7845,12611,7898,12556,7959,12575,8046,12576,8337,12584,8501,12485,8919,12289,10249,11691,10647,11522,11221,11342,11221,11342,11372,11305,11461,11304,11505,11287,12450,11017,12660,11261,13215,11905,13356,11925,14350,12022,14523,12425,14696,12828,14950,13287,14950,13287,15030,13432,15015,13013,15000,12594,15192,12420,15327,12289,15418,12151,15456,12063,15733,11190,15861,10854,16496,9670,16837,9025,16993,8947,17587,8644,17587,8644,18746,6610,18773,6607,18798,6614,18763,6441,18742,6234,18713,6201,18728,6184,18848,6041,18790,5998,18753,5947,18778,5824,18823,5692,18953,5311,18941,5306,18922,5295,18780,5230,18631,5164,18640,5131];

  var IMG_W = 2400, IMG_H = 1840;
  var MAP_SCALE = 0.6;              // points per map-image pixel
  var NS = 'http://www.w3.org/2000/svg';

  var ROUTE = [], CUM = [0];
  for (var i = 0; i < ROUTE_RAW.length; i += 2) ROUTE.push([ROUTE_RAW[i] / 10, ROUTE_RAW[i + 1] / 10]);
  for (i = 1; i < ROUTE.length; i++) {
    CUM.push(CUM[i - 1] + Math.hypot(ROUTE[i][0] - ROUTE[i - 1][0], ROUTE[i][1] - ROUTE[i - 1][1]));
  }
  var ROUTE_LEN = CUM[CUM.length - 1];

  function routeAt(frac) {
    var d = Math.max(0, Math.min(1, frac)) * ROUTE_LEN;
    var lo = 0, hi = CUM.length - 1;
    while (hi - lo > 1) { var m = (lo + hi) >> 1; if (CUM[m] <= d) lo = m; else hi = m; }
    var seg = CUM[hi] - CUM[lo], t = seg > 0 ? (d - CUM[lo]) / seg : 0;
    return { i: lo, x: ROUTE[lo][0] + (ROUTE[hi][0] - ROUTE[lo][0]) * t, y: ROUTE[lo][1] + (ROUTE[hi][1] - ROUTE[lo][1]) * t };
  }

  // ---------- icons (SF Symbols look-alikes) ----------
  var IC = {
    watch: '<svg width="9" height="13" viewBox="0 0 9 13"><path d="M2.2 0h4.6l.5 2H1.7zM1.7 11h5.6l-.5 2H2.2z" fill="currentColor"/><rect x=".9" y="2.1" width="7.2" height="8.8" rx="2.3" fill="none" stroke="currentColor" stroke-width="1.3"/><rect x="8.3" y="5" width=".9" height="2.4" rx=".4" fill="currentColor"/></svg>',
    phone: '<svg width="8" height="13" viewBox="0 0 8 13"><rect x=".7" y=".7" width="6.6" height="11.6" rx="1.7" fill="none" stroke="currentColor" stroke-width="1.3"/><rect x="2.8" y="1.9" width="2.4" height=".9" rx=".45" fill="currentColor"/></svg>',
    camera: '<svg width="15" height="11" viewBox="0 0 15 11"><path d="M5.2.4h4.6l1.1 1.6h1.9A2.2 2.2 0 0 1 15 4.2v4.6A2.2 2.2 0 0 1 12.8 11H2.2A2.2 2.2 0 0 1 0 8.8V4.2A2.2 2.2 0 0 1 2.2 2h1.9z" fill="currentColor"/><circle cx="7.5" cy="6.4" r="2.6" fill="#120c1e"/><circle cx="7.5" cy="6.4" r="1.6" fill="currentColor"/></svg>',
    note: '<svg width="13" height="17" viewBox="0 0 13 17"><path d="M4.4 3.2 12 .9v10.7a2.8 2.8 0 1 1-1.6-2.5V4.4L6 5.8v7.9a2.8 2.8 0 1 1-1.6-2.5z" fill="currentColor"/></svg>',
    back: '<svg width="21" height="13" viewBox="0 0 21 13"><path d="M10 1.2v10.6c0 .8-.9 1.2-1.5.8L.9 7.3a1 1 0 0 1 0-1.6L8.5.4c.6-.4 1.5 0 1.5.8zm10.5 0v10.6c0 .8-.9 1.2-1.5.8l-7.6-5.3a1 1 0 0 1 0-1.6L19 .4c.6-.4 1.5 0 1.5.8z" fill="currentColor"/></svg>',
    fwd: '<svg width="21" height="13" viewBox="0 0 21 13"><path d="M11 1.2v10.6c0 .8.9 1.2 1.5.8l7.6-5.3a1 1 0 0 0 0-1.6L12.5.4c-.6-.4-1.5 0-1.5.8zM.5 1.2v10.6c0 .8.9 1.2 1.5.8l7.6-5.3a1 1 0 0 0 0-1.6L2 .4C1.4 0 .5.4.5 1.2z" fill="currentColor"/></svg>',
    play: '<svg width="14" height="16" viewBox="0 0 14 16"><path d="M1 1.6v12.8c0 1 1 1.5 1.8 1l10.4-6.4a1.2 1.2 0 0 0 0-2L2.8.6C2 .1 1 .7 1 1.6z" fill="currentColor"/></svg>',
    pause: '<svg width="13" height="15" viewBox="0 0 13 15"><rect x=".5" y=".5" width="4.2" height="14" rx="1.2" fill="currentColor"/><rect x="8.3" y=".5" width="4.2" height="14" rx="1.2" fill="currentColor"/></svg>',
    heart: '<svg width="17" height="15" viewBox="0 0 24 21"><path d="M12 20s-9.5-5.6-11-12A5.7 5.7 0 0 1 12 4.4 5.7 5.7 0 0 1 23 8c-1.5 6.4-11 12-11 12z" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"/></svg>',
    heartFill: '<svg width="17" height="15" viewBox="0 0 24 21"><path d="M12 20s-9.5-5.6-11-12A5.7 5.7 0 0 1 12 4.4 5.7 5.7 0 0 1 23 8c-1.5 6.4-11 12-11 12z" fill="currentColor" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"/></svg>',
    signal: '<svg width="19" height="12" viewBox="0 0 19 12"><rect x="0" y="7.6" width="3.2" height="4.4" rx="1" fill="#fff"/><rect x="5.1" y="5.2" width="3.2" height="6.8" rx="1" fill="#fff"/><rect x="10.2" y="2.6" width="3.2" height="9.4" rx="1" fill="#fff"/><rect x="15.3" y="0" width="3.2" height="12" rx="1" fill="#fff"/></svg>',
    wifi: '<svg width="17" height="12" viewBox="0 0 17 12"><path d="M8.5 2.3c2.5 0 4.8 1 6.5 2.6.2.2.5.2.7 0l1.1-1.1c.2-.2.2-.5 0-.7A11.7 11.7 0 0 0 8.5 0 11.7 11.7 0 0 0 .2 3.1c-.2.2-.2.5 0 .7l1.1 1.1c.2.2.5.2.7 0a9.4 9.4 0 0 1 6.5-2.6zm0 3.7c1.5 0 2.9.6 3.9 1.5.2.2.5.2.7 0l1.1-1.1c.2-.2.2-.5 0-.7a8.1 8.1 0 0 0-11.4 0c-.2.2-.2.5 0 .7l1.1 1.1c.2.2.5.2.7 0 1-.9 2.4-1.5 3.9-1.5zm2.1 3.2c.2-.2.2-.5 0-.7a3.1 3.1 0 0 0-4.2 0c-.2.2-.2.5 0 .7l1.7 1.7c.2.2.5.2.7 0z" fill="#fff"/></svg>'
  };

  function batteryGlyph(level, color) {
    var bucket = level >= 88 ? 1 : level >= 63 ? 0.75 : level >= 38 ? 0.5 : level >= 13 ? 0.25 : 0;
    var w = 14.6 * bucket;
    return '<svg width="22" height="11" viewBox="0 0 22 11"><rect x=".6" y=".6" width="18.4" height="9.8" rx="3" fill="none" stroke="' + color + '" stroke-opacity=".55" stroke-width="1.2"/>' +
      (w > 0 ? '<rect x="2.5" y="2.5" width="' + w.toFixed(1) + '" height="6" rx="1.4" fill="' + color + '"/>' : '') +
      '<path d="M20.2 3.8v3.4c.8-.3 1.3-1 1.3-1.7s-.5-1.4-1.3-1.7z" fill="' + color + '" fill-opacity=".55"/></svg>';
  }
  function sbBattery(level) {
    var w = Math.max(2, 21.4 * level / 100);
    return '<svg width="28" height="13" viewBox="0 0 28 13"><rect x=".5" y=".5" width="24" height="12" rx="3.8" fill="none" stroke="#fff" stroke-opacity=".38"/><rect x="2" y="2" width="' + w.toFixed(1) + '" height="9" rx="2.4" fill="#fff"/><path d="M26 4.4v4.2c.9-.3 1.5-1.1 1.5-2.1S26.9 4.7 26 4.4z" fill="#fff" fill-opacity=".45"/></svg>';
  }
  function batteryTint(level) {
    return level >= 50 ? 'rgb(146,145,155)' : level >= 20 ? 'rgb(255,214,0)' : 'rgb(255,69,58)';
  }

  // ---------- formatting ----------
  function pad2(n) { return (n < 10 ? '0' : '') + n; }
  function fmtElapsed(s) {
    s = Math.max(0, Math.floor(s || 0));
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    return h > 0 ? h + ':' + pad2(m) + ':' + pad2(sec) : m + ':' + pad2(sec);
  }
  function fmtDistHero(m) {
    if (m == null || !isFinite(m)) return '-';
    return m >= 1000 ? (m / 1000).toFixed(2) : Math.round(m) + 'm';
  }
  function fmtPace(p) {
    if (!p || !isFinite(p) || p <= 0) return '-';
    var s = Math.floor(p);
    return Math.floor(s / 60) + ':' + pad2(s % 60);
  }
  function fmtSpeed(p, kmh) {
    if (p && isFinite(p) && p > 0) return (3600 / p).toFixed(1);
    if (kmh && isFinite(kmh)) return kmh.toFixed(1);
    return '-';
  }
  function fmtKm(km) {
    if (km < 1) return km.toFixed(1);
    return Math.abs(km % 1) < 1e-6 ? km.toFixed(0) : km.toFixed(1);
  }
  function el(tag, cls, html) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  }
  function setText(node, txt) { if (node.__t !== txt) { node.__t = txt; node.textContent = txt; } }
  function setHTML(node, html) { if (node.__h !== html) { node.__h = html; node.innerHTML = html; } }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  // ---------- chart maths (LiveRunChart.swift) ----------
  var X_STEPS = [1, 2, 5, 10, 15, 20, 30, 42, 50];
  function xMaxFor(km) { for (var i = 0; i < X_STEPS.length; i++) if (km * 1.1 < X_STEPS[i]) return X_STEPS[i]; return 50; }
  function xStride(max) { return max <= 1 ? 0.2 : max <= 2 ? 0.5 : max <= 5 ? 1 : max <= 10 ? 2 : max <= 20 ? 5 : 10; }
  function barWidth(max) { return max <= 1 ? 10 : max <= 2 ? 8 : max <= 5 ? 5 : max <= 10 ? 3.5 : max <= 20 ? 2.4 : 1.6; }
  function speedRange(samples, live) {
    var v = [];
    for (var i = 0; i < samples.length; i++) { var s = samples[i].speedKmh; if (s > 0 && s <= 28) v.push(s); }
    if (live > 0 && live <= 28) v.push(live);
    if (!v.length) return [6, 14];
    var lo = Math.min.apply(null, v), hi = Math.max.apply(null, v), p = Math.max(0.5, (hi - lo) * 0.15);
    return [Math.max(0, lo - p), hi + p];
  }
  function hrRange(samples, live) {
    var v = [];
    for (var i = 0; i < samples.length; i++) { var h = samples[i].hr; if (h >= 30 && h <= 220) v.push(h); }
    if (live >= 30 && live <= 220) v.push(live);
    if (v.length <= 2) {
      if (v.length) return [Math.max(30, Math.min.apply(null, v) - 6), Math.max.apply(null, v) + 6];
      return [100, 160];
    }
    v.sort(function (a, b) { return a - b; });
    var lo = v[Math.floor(v.length * 0.05)], hi = v[Math.min(v.length - 1, Math.floor(v.length * 0.95))];
    var p = Math.max(4, (hi - lo) * 0.18);
    return [Math.max(30, lo - p), hi + p];
  }
  function norm(v, r) { var s = r[1] - r[0]; if (s < 1e-4) return 0.5; return Math.min(1, Math.max(0, (v - r[0]) / s)); }
  function catmull(pts) {
    if (pts.length < 2) return '';
    var d = 'M' + pts[0][0].toFixed(1) + ' ' + pts[0][1].toFixed(1);
    for (var i = 0; i < pts.length - 1; i++) {
      var p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
      var c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
      var c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
      d += 'C' + c1x.toFixed(1) + ' ' + c1y.toFixed(1) + ' ' + c2x.toFixed(1) + ' ' + c2y.toFixed(1) + ' ' + p2[0].toFixed(1) + ' ' + p2[1].toFixed(1);
    }
    return d;
  }

  // ---------- build ----------
  function build(root, mapSrc) {
    var wrap = el('div', 'ph-wrap');
    var sc = el('div', 'ph-scale');
    wrap.appendChild(sc);

    ['ph-btn ph-left ph-btn-action', 'ph-btn ph-left ph-btn-volup', 'ph-btn ph-left ph-btn-voldn',
      'ph-btn ph-right ph-btn-side', 'ph-btn ph-right ph-btn-cam'].forEach(function (c) { sc.appendChild(el('div', c)); });

    var dev = el('div', 'ph-device');
    sc.appendChild(dev);
    [['ph-l', 'top:96px'], ['ph-l', 'top:806px'], ['ph-r', 'top:96px'], ['ph-r', 'top:806px'],
      ['ph-t', 'left:96px'], ['ph-b', 'right:96px']].forEach(function (a) {
      var x = el('div', 'ph-antenna ' + a[0]); x.setAttribute('style', a[1]); dev.appendChild(x);
    });
    var glass = el('div', 'ph-glass');
    dev.appendChild(glass);
    var scr = el('div', 'ph-screen');
    glass.appendChild(scr);

    scr.appendChild(el('div', 'ph-di'));
    var sb = el('div', 'ph-sb');
    sb.innerHTML = '<div class="ph-sb-time">7:42</div><div class="ph-sb-right">' + IC.signal + IC.wifi + '<span class="ph-sb-bat"></span></div>';
    scr.appendChild(sb);

    var app = el('div', 'ph-app ph-nomap ph-still');
    scr.appendChild(app);
    app.innerHTML =
      '<div class="ph-strip">' +
        '<span class="ph-strip-corral">IN THE CORRAL</span><span class="ph-strip-sp"></span>' +
        '<span class="ph-chip ph-chip-watch"></span><span class="ph-chip ph-chip-phone"></span>' +
        '<span class="ph-chip ph-chip-cam ph-hide"></span>' +
      '</div>' +
      '<div class="ph-corralwrap"><div class="ph-corralcard">' +
        '<div class="ph-corral-text">Session live. The race clock starts when you cross the timing mat.</div>' +
        '<div class="ph-gate">I CROSSED THE GATE</div>' +
      '</div></div>' +
      '<div class="ph-cockpit">' +
        '<div class="ph-heroes">' +
          '<div class="ph-hero ph-hero-t"><div class="ph-label">TIME</div><div class="ph-hero-v"><span>0:00</span></div></div>' +
          '<div class="ph-hero ph-hero-d"><div class="ph-label">DIST</div><div class="ph-hero-v"><span>0m</span></div></div>' +
        '</div>' +
        '<div class="ph-tiles">' +
          '<div class="ph-tile ph-tile-pace"><div class="ph-tl">PACE</div><div class="ph-tv">-</div></div>' +
          '<div class="ph-tile ph-tile-hr"><div class="ph-tl">HR</div><div class="ph-tv">-</div></div>' +
          '<div class="ph-tile ph-tile-kcal"><div class="ph-tl">KCAL</div><div class="ph-tv">-</div></div>' +
          '<div class="ph-tile ph-tile-kmh"><div class="ph-tl">KM/H</div><div class="ph-tv">-</div></div>' +
        '</div>' +
      '</div>' +
      '<div class="ph-mapwrap"><div class="ph-map">' +
        '<div class="ph-maplayer"><img alt="" draggable="false" decoding="async"></div>' +
        '<div class="ph-loc"><i class="ph-halo"></i><i class="ph-core"></i></div>' +
        '<div class="ph-seg"><span>Pace</span><span>HR</span></div>' +
      '</div></div>' +
      '<div class="ph-swap">' +
        '<div class="ph-chartzone">' +
          '<div class="ph-chart">' +
            '<div class="ph-chead">' +
              '<div class="ph-legend ph-legend-sp"><i></i><div><b>Speed</b><em>-</em></div></div>' +
              '<div class="ph-legend ph-legend-hr"><i></i><div><b>HR</b><em>-</em></div></div>' +
              '<div class="ph-cdist">0.00 km</div>' +
            '</div>' +
            '<div class="ph-plot"><svg></svg><div class="ph-fdot"><i class="ph-fpulse"></i><i class="ph-fcore"></i></div></div>' +
          '</div>' +
          '<div class="ph-media">' +
            '<div class="ph-art">' + IC.note + '</div>' +
            '<div class="ph-track"><b>Nothing playing</b><span>Open Spotify to control</span></div>' +
            '<div class="ph-tbtn">' + IC.back + '</div>' +
            '<div class="ph-tbtn ph-play">' + IC.play + '</div>' +
            '<div class="ph-tbtn">' + IC.fwd + '</div>' +
          '</div>' +
        '</div>' +
        '<div class="ph-coach">' +
          '<svg class="ph-coach-wm" viewBox="0 0 24 21"><path d="M12 20s-9.5-5.6-11-12A5.7 5.7 0 0 1 12 4.4 5.7 5.7 0 0 1 23 8c-1.5 6.4-11 12-11 12z" fill="currentColor"/></svg>' +
          '<div class="ph-coach-h"><span class="ph-coach-who">Ricky</span><span class="ph-coach-love"></span></div>' +
          '<div class="ph-coach-body"><div class="ph-kara"></div><div class="ph-quote"></div></div>' +
        '</div>' +
      '</div>' +
      '<div class="ph-end">End run</div>';

    // map layer: image + planned route + trail segments
    var layer = app.querySelector('.ph-maplayer');
    var img = layer.querySelector('img');
    img.src = mapSrc;
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 ' + IMG_W + ' ' + IMG_H);
    var planned = document.createElementNS(NS, 'polyline');
    planned.setAttribute('points', ROUTE.map(function (p) { return p[0] + ',' + p[1]; }).join(' '));
    planned.setAttribute('fill', 'none');
    planned.setAttribute('stroke', 'rgba(142,142,147,.5)');
    planned.setAttribute('stroke-width', (3 / MAP_SCALE).toFixed(2));
    planned.setAttribute('stroke-dasharray', (6 / MAP_SCALE) + ' ' + (6 / MAP_SCALE));
    svg.appendChild(planned);
    var segs = [];
    var sw = (5 / MAP_SCALE).toFixed(2);
    for (var k = 0; k < ROUTE.length - 1; k++) {
      // pace-hued like RunMapView (slow red .. fast green); this loop is mostly brisk, so lime/yellow-green
      var t = 0.62 + 0.26 * Math.sin(k * 0.37) * Math.cos(k * 0.11) + 0.12 * Math.sin(k * 1.3);
      t = Math.max(0.45, Math.min(1, t));
      var hue = 0.33 * t * 360 * 0.92 + 8;
      var ln = document.createElementNS(NS, 'line');
      ln.setAttribute('stroke', 'hsl(' + hue.toFixed(0) + ',82%,52%)');
      ln.setAttribute('stroke-width', sw);
      ln.setAttribute('stroke-linecap', 'round');
      ln.style.display = 'none';
      svg.appendChild(ln);
      segs.push(ln);
    }
    layer.appendChild(svg);

    root.appendChild(wrap);
    return { wrap: wrap, sc: sc, app: app, sb: sb, layer: layer, segs: segs };
  }

  function mount(root, opts) {
    opts = opts || {};
    var B = build(root, opts.mapSrc || 'london.webp');
    var app = B.app, q = function (s) { return app.querySelector(s); };
    var N = {
      sbTime: B.sb.querySelector('.ph-sb-time'), sbBat: B.sb.querySelector('.ph-sb-bat'),
      watch: q('.ph-chip-watch'), phone: q('.ph-chip-phone'), cam: q('.ph-chip-cam'),
      heroT: q('.ph-hero-t .ph-hero-v span'), heroD: q('.ph-hero-d .ph-hero-v span'),
      heroTBox: q('.ph-hero-t'), heroDBox: q('.ph-hero-d'),
      pace: q('.ph-tile-pace .ph-tv'), hr: q('.ph-tile-hr .ph-tv'), kcal: q('.ph-tile-kcal .ph-tv'), kmh: q('.ph-tile-kmh .ph-tv'),
      map: q('.ph-map'), spRange: q('.ph-legend-sp em'), hrRange: q('.ph-legend-hr em'), hrLegend: q('.ph-legend-hr'),
      cdist: q('.ph-cdist'), plot: q('.ph-plot'), psvg: q('.ph-plot svg'), fdot: q('.ph-fdot'),
      art: q('.ph-art'), title: q('.ph-track b'), artist: q('.ph-track span'), play: q('.ph-play'),
      coach: q('.ph-coach'), who: q('.ph-coach-who'), love: q('.ph-coach-love'), kara: q('.ph-kara'), quote: q('.ph-quote'), body: q('.ph-coach-body'),
      swap: q('.ph-swap')
    };

    // fluid scale
    var scale = 1;
    function fit() {
      var w = B.wrap.clientWidth || 440;
      scale = w / 440;
      B.sc.style.transform = 'scale(' + scale + ')';
    }
    var ro = new ResizeObserver(function () { fit(); chartDirty = true; });
    ro.observe(B.wrap);
    ro.observe(N.plot);
    fit();

    var visible = true;
    var io = 'IntersectionObserver' in window ? new IntersectionObserver(function (es) { visible = es[0].isIntersecting; }) : null;
    if (io) io.observe(B.wrap);

    var S = null;                 // latest state
    var chartDirty = true;
    var cam = null;               // smoothed map camera {x,y,f}
    var dispMax = null;           // animated chart x domain
    var heroLen = { t: -1, d: -1 };
    var liked = {};
    var coachId = null, coachStart = 0, coachDur = 3, coachWords = [], coachActive = -2, coachLineH = 29.8, coachDone = false, coachFitted = false;

    function fitHero(span, box, key, txt) {
      setText(span, txt);
      if (heroLen[key] === txt.length) return;
      heroLen[key] = txt.length;
      span.style.fontSize = '52px';
      var avail = box.clientWidth, w = span.offsetWidth;
      if (w > avail && avail > 0) span.style.fontSize = Math.max(52 * 0.55, 52 * avail / w * 0.98).toFixed(1) + 'px';
    }

    function chip(node, icon, level) {
      var c = batteryTint(level);
      node.style.color = c;
      setHTML(node, icon + batteryGlyph(level, c) + '<span>' + level + '%</span>');
    }

    function clockFor(st) {
      var mins = 7 * 60 + 30 + Math.floor((st.elapsedS || 0) / 60);
      var h = Math.floor(mins / 60) % 12 || 12;
      return h + ':' + pad2(mins % 60);
    }

    function onState(st) {
      if (!st) return;
      var prevMode = S && S.mode;
      S = st;
      var race = st.mode === 'race' && st.race;
      var corral = !!(race && st.race.phase === 'corral');
      var hasMap = st.mode !== 'indoor' && !!st.route && !corral;
      app.classList.toggle('ph-nomap', !hasMap);
      app.classList.toggle('ph-corral', corral);
      if (prevMode !== st.mode) heroLen = { t: -1, d: -1 };

      setText(N.sbTime, clockFor(st));
      var bt = st.batteries || {};
      setHTML(N.sbBat, sbBattery(bt.phone != null ? bt.phone : 80));
      if (bt.watch != null) chip(N.watch, IC.watch, bt.watch);
      if (bt.phone != null) chip(N.phone, IC.phone, bt.phone);
      var showCam = !!race && bt.camera != null;
      N.cam.classList.toggle('ph-hide', !showCam);
      if (showCam) {
        var cc = batteryTint(bt.camera);
        N.cam.style.color = cc;
        setHTML(N.cam, IC.camera + (st.race.recording ? '<i class="ph-chip-rec"></i>' : '') + batteryGlyph(bt.camera, cc) + '<span>' + bt.camera + '%</span>');
      }

      fitHero(N.heroT, N.heroTBox, 't', fmtElapsed(st.elapsedS));
      fitHero(N.heroD, N.heroDBox, 'd', fmtDistHero(st.distM));
      setText(N.pace, fmtPace(st.paceSecPerKm));
      setText(N.hr, st.hr > 0 ? String(Math.round(st.hr)) : '-');
      setText(N.kcal, st.kcal != null && isFinite(st.kcal) ? String(Math.floor(st.kcal)) : '-');
      setText(N.kmh, fmtSpeed(st.paceSecPerKm, st.speedKmh));

      var mu = st.music;
      if (mu && mu.title) {
        N.art.classList.add('ph-has');
        setText(N.title, mu.title);
        setText(N.artist, mu.artist || '');
        setHTML(N.play, mu.playing ? IC.pause : IC.play);
      } else {
        N.art.classList.remove('ph-has');
        setText(N.title, 'Nothing playing');
        setText(N.artist, 'Open Spotify to control');
        setHTML(N.play, IC.play);
      }

      updateCoach(st.coach);
      chartDirty = true;
    }

    // ---------- coach card ----------
    function updateCoach(c) {
      N.swap.classList.toggle('ph-coaching', !!c);
      if (!c) { coachId = null; return; }
      var isLiked = !!(c.liked || liked[c.id]);
      N.coach.classList.toggle('ph-liked', isLiked);
      setHTML(N.love, (isLiked ? IC.heartFill : IC.heart) + '<span>' + (isLiked ? 'Loved' : 'Tap anywhere to love') + '</span>');
      if (c.id === coachId) return;
      coachId = c.id;
      var home = c.voice === 'Home Base';
      N.coach.style.setProperty('--ph-cacc', home ? 'rgb(60,212,254)' : 'rgb(255,147,48)');
      N.coach.style.setProperty('--ph-cacc-s', home ? 'rgba(60,212,254,.3)' : 'rgba(255,147,48,.3)');
      setText(N.who, c.voice || 'Ricky');
      var words = String(c.text || '').split(/\s+/).filter(Boolean);
      N.kara.innerHTML = words.map(function (w) { return '<span>' + esc(w) + '</span>'; }).join('');
      coachWords = Array.prototype.slice.call(N.kara.children);
      N.quote.textContent = '“' + words.join(' ') + '”';
      coachStart = performance.now();
      coachDur = Math.max(2.2, words.length * 0.36);
      coachActive = -2;
      coachDone = false;
      coachFitted = false;
      N.coach.classList.remove('ph-coach-done');
      N.kara.style.transform = 'translateY(0)';
    }
    N.coach.addEventListener('click', function () {
      if (!S || !S.coach) return;
      liked[S.coach.id] = !liked[S.coach.id];
      updateCoach(S.coach);
    });

    function fitQuote() {
      var bh = N.body.clientHeight, lo = 12, hi = 28;
      N.quote.style.fontSize = hi + 'px';
      N.quote.style.lineHeight = '1.25';
      if (N.quote.scrollHeight <= bh) return;
      while (hi - lo > 0.5) {
        var mid = (lo + hi) / 2;
        N.quote.style.fontSize = mid + 'px';
        if (N.quote.scrollHeight <= bh) lo = mid; else hi = mid;
      }
      N.quote.style.fontSize = lo + 'px';
    }

    function tickCoach(now) {
      if (!coachId || !coachWords.length) return;
      var p = (now - coachStart) / 1000 / coachDur;
      var active = p >= 1 ? coachWords.length : Math.min(coachWords.length - 1, Math.floor(p * coachWords.length));
      if (active !== coachActive) {
        coachActive = active;
        for (var i = 0; i < coachWords.length; i++) {
          coachWords[i].className = i < active ? 'ph-read' : i === active ? 'ph-now' : '';
        }
        var cur = coachWords[Math.min(active, coachWords.length - 1)];
        var line = Math.round(cur.offsetTop / coachLineH);
        var viewH = N.body.clientHeight, contentH = N.kara.offsetHeight;
        var off = 0;
        if (contentH > viewH) {
          var centred = viewH / 2 - (line + 0.5) * coachLineH;
          off = Math.max(viewH - contentH, Math.min(0, centred));
        }
        N.kara.style.transform = 'translateY(' + off.toFixed(1) + 'px)';
      }
      if (!coachDone && p > 1.15) {
        coachDone = true;
        if (!coachFitted) { fitQuote(); coachFitted = true; }
        N.coach.classList.add('ph-coach-done');
      }
    }

    // ---------- map ----------
    var lastSegI = -1;
    function tickMap(dt) {
      if (!S || !S.route) return;
      var r = S.route;
      var tx = r.xFrac * IMG_W, ty = r.yFrac * IMG_H, tf = r.trailFrac || 0;
      if (!cam || Math.hypot(tx - cam.x, ty - cam.y) > 260 || Math.abs(tf - cam.f) > 0.08) {
        cam = { x: tx, y: ty, f: tf };
      } else {
        var k = 1 - Math.exp(-dt * 4.5);
        cam.x += (tx - cam.x) * k; cam.y += (ty - cam.y) * k; cam.f += (tf - cam.f) * k;
      }
      var mw = N.map.clientWidth || 362, mh = 190;
      var ox = mw / 2 - cam.x * MAP_SCALE, oy = mh / 2 - cam.y * MAP_SCALE;
      B.layer.style.transform = 'translate3d(' + ox.toFixed(2) + 'px,' + oy.toFixed(2) + 'px,0)';

      var end = routeAt(cam.f);
      // trail ends exactly under the location dot
      var ex = cam.x, ey = cam.y;
      for (var i = 0; i < B.segs.length; i++) {
        var ln = B.segs[i];
        if (i < end.i) {
          if (i > lastSegI || lastSegI < 0 || ln.__full !== 1) {
            ln.setAttribute('x1', ROUTE[i][0]); ln.setAttribute('y1', ROUTE[i][1]);
            ln.setAttribute('x2', ROUTE[i + 1][0]); ln.setAttribute('y2', ROUTE[i + 1][1]);
            ln.style.display = ''; ln.__full = 1;
          }
        } else if (i === end.i) {
          ln.setAttribute('x1', ROUTE[i][0]); ln.setAttribute('y1', ROUTE[i][1]);
          ln.setAttribute('x2', ex.toFixed(1)); ln.setAttribute('y2', ey.toFixed(1));
          ln.style.display = ''; ln.__full = 0;
        } else if (ln.style.display !== 'none') {
          ln.style.display = 'none'; ln.__full = 0;
        }
      }
      lastSegI = end.i;
    }

    // ---------- chart ----------
    function drawChart(dt) {
      if (!S) return;
      var samples = S.chart || [];
      var nowKm = (S.distM || 0) / 1000;
      var liveKmh = S.paceSecPerKm > 0 ? 3600 / S.paceSecPerKm : (S.speedKmh || 0);
      var target = xMaxFor(nowKm);
      if (dispMax == null || Math.abs(dispMax - target) > target * 2 || dispMax / target > 3) dispMax = target;
      var animating = Math.abs(dispMax - target) > 0.001;
      if (animating) dispMax += (target - dispMax) * (1 - Math.exp(-dt * 5));
      else dispMax = target;
      if (!chartDirty && !animating) return;
      chartDirty = false;

      var hasHR = samples.some(function (s) { return s.hr > 0; });
      var sr = speedRange(samples, liveKmh), hr = hrRange(samples, S.hr);
      setText(N.spRange, samples.length ? sr[0].toFixed(1) + '-' + sr[1].toFixed(1) + ' km/h' : '-');
      setText(N.hrRange, hasHR ? Math.floor(hr[0]) + '-' + Math.floor(hr[1]) + ' bpm' : '-');
      N.hrLegend.style.display = hasHR ? '' : 'none';
      setText(N.cdist, nowKm.toFixed(2) + ' km');

      var W = N.plot.clientWidth, H = N.plot.clientHeight;
      if (W < 10 || H < 30) return;
      var bot = H - 18, top = 0, x0 = 20, x1 = W - (hasHR ? 24 : 4);
      var X = function (km) { return x0 + km / dispMax * (x1 - x0); };
      var Y = function (t) { return bot - t * (bot - top); };
      var o = [];
      var ticks = [0, 0.25, 0.5, 0.75, 1];
      ticks.forEach(function (t) {
        var y = Y(t).toFixed(1);
        o.push('<line x1="' + x0 + '" x2="' + x1 + '" y1="' + y + '" y2="' + y + '" stroke="rgba(255,255,255,.07)" stroke-width="1"/>');
        var sv = sr[0] + t * (sr[1] - sr[0]);
        o.push('<text x="' + (x0 - 3) + '" y="' + y + '" dy=".35em" text-anchor="end" fill="rgba(89,217,255,.8)">' + (sv >= 10 ? sv.toFixed(0) : sv.toFixed(1)) + '</text>');
        if (hasHR) o.push('<text x="' + (x1 + 4) + '" y="' + y + '" dy=".35em" fill="rgba(255,89,140,.8)">' + Math.floor(hr[0] + t * (hr[1] - hr[0])) + '</text>');
      });
      var step = xStride(target);
      for (var v = 0; v <= target + 1e-6; v += step) {
        var gx = X(v);
        if (gx > x1 + 0.5) break;
        o.push('<line x1="' + gx.toFixed(1) + '" x2="' + gx.toFixed(1) + '" y1="0" y2="' + H + '" stroke="rgba(255,255,255,.13)" stroke-dasharray="2 2.5" stroke-width="1"/>');
        if (v < target - 1e-6) o.push('<text x="' + (gx + 4).toFixed(1) + '" y="' + (bot + 15) + '" fill="rgba(255,255,255,.55)">' + fmtKm(v) + '</text>');
      }
      var bw = barWidth(target);
      o.push('<g fill="rgba(89,217,255,.40)">');
      for (var i = 0; i < samples.length; i++) {
        var s = samples[i];
        if (!(s.speedKmh > 0 && s.speedKmh <= 28)) continue;
        var bx = X(s.dKm), by = Y(norm(s.speedKmh, sr));
        if (bx > x1 + bw) continue;
        o.push('<rect x="' + (bx - bw / 2).toFixed(1) + '" y="' + by.toFixed(1) + '" width="' + bw + '" height="' + Math.max(0, bot - by).toFixed(1) + '" rx="1.5"/>');
      }
      o.push('</g>');
      if (hasHR) {
        var pts = [];
        for (i = 0; i < samples.length; i++) if (samples[i].hr >= 30 && samples[i].hr <= 220) pts.push([X(samples[i].dKm), Y(norm(samples[i].hr, hr))]);
        o.push('<path d="' + catmull(pts) + '" fill="none" stroke="rgb(255,89,140)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>');
      }
      var nx = X(nowKm);
      o.push('<line x1="' + nx.toFixed(1) + '" x2="' + nx.toFixed(1) + '" y1="0" y2="' + (bot + 6) + '" stroke="rgba(255,255,255,.35)" stroke-dasharray="3 4" stroke-width="1"/>');
      N.psvg.setAttribute('width', W);
      N.psvg.setAttribute('height', H);
      N.psvg.innerHTML = o.join('');
      var dy = liveKmh > 0 ? Y(norm(liveKmh, sr)) : Y(0.5);
      N.fdot.style.transform = 'translate(' + nx.toFixed(1) + 'px,' + dy.toFixed(1) + 'px)';
    }

    // ---------- loop ----------
    var raf = 0, last = performance.now();
    function frame(now) {
      raf = requestAnimationFrame(frame);
      var dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      if (!visible) return;
      tickMap(dt);
      drawChart(dt);
      tickCoach(now);
    }
    raf = requestAnimationFrame(frame);
    // first layout lands without animating from the empty shell
    setTimeout(function () { app.classList.remove('ph-still'); }, 120);

    var unsub = null;
    function attach() {
      if (window.AARC_SIM && window.AARC_SIM.subscribe) {
        unsub = window.AARC_SIM.subscribe(onState);
        return true;
      }
      return false;
    }
    if (!attach()) {
      var tries = 0, iv = setInterval(function () { if (attach() || ++tries > 100) clearInterval(iv); }, 50);
    }

    return {
      el: B.wrap,
      destroy: function () {
        cancelAnimationFrame(raf);
        if (unsub) unsub();
        ro.disconnect();
        if (io) io.disconnect();
        B.wrap.remove();
      }
    };
  }

  window.AARCPhone = { mount: mount, route: ROUTE, routeAt: routeAt, routeLength: ROUTE_LEN };
})();
