/* AARC homepage: Apple Watch mockup with a live replica of the AARC watch run screen.
   Usage: AARCWatch.mount(el, { sim, mapSrc, route, routeSrc, mapPage, fade })
   Mirrors ios/AARCWatch/Features/Run: WatchMetricsView (time + 2x2 quads), WatchCoachPage
   (overlay), WatchRouteMap (outdoor map), WatchActiveRunView controls (race corral gate). */
(function () {
  'use strict';

  var HEART = 'M12 21.2c-.3 0-.6-.1-.8-.3C6.6 17.1 2.5 13.6 2.5 9.1 2.5 6 4.8 3.7 7.7 3.7c1.8 0 3.3.9 4.3 2.4 1-1.5 2.5-2.4 4.3-2.4 2.9 0 5.2 2.3 5.2 5.4 0 4.5-4.1 8-8.7 11.8-.2.2-.5.3-.8.3z';
  var REDUCED = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

  function el(tag, cls, html) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  }
  function setText(node, s) { if (node.textContent !== s) node.textContent = s; }
  function pad2(n) { return (n < 10 ? '0' : '') + n; }
  function fmtElapsed(s) {
    var t = Math.max(0, Math.floor(s || 0)), h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60;
    return h > 0 ? h + ':' + pad2(m) + ':' + pad2(sec) : m + ':' + pad2(sec);
  }
  function fmtPace(s) {
    if (!s || !isFinite(s) || s <= 0 || s > 1800) return '-';
    var t = Math.round(s);
    return Math.floor(t / 60) + "'" + pad2(t % 60) + '"';
  }
  function hsv(h, s, v) {
    var i = Math.floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s), r, g, b;
    switch (((i % 6) + 6) % 6) {
      case 0: r = v; g = t; b = p; break; case 1: r = q; g = v; b = p; break;
      case 2: r = p; g = v; b = t; break; case 3: r = p; g = q; b = v; break;
      case 4: r = t; g = p; b = v; break; default: r = v; g = p; b = q;
    }
    return 'rgb(' + Math.round(r * 255) + ',' + Math.round(g * 255) + ',' + Math.round(b * 255) + ')';
  }
  function clockNow() {
    var d = new Date(), h = d.getHours() % 12;
    return (h === 0 ? 12 : h) + ':' + pad2(d.getMinutes());
  }
  function excerpt(text, max) {
    text = String(text || '').replace(/\s+/g, ' ').trim();
    if (text.length <= max) return text;
    var cut = text.slice(0, max), sp = cut.lastIndexOf(' ');
    return cut.slice(0, sp > max * 0.6 ? sp : max).replace(/[,.;:!?]+$/, '') + '…';
  }

  /* Articulated runner badge, ported from RunnerBadge in WatchActiveRunView.swift. */
  function Runner(svg) {
    var NS = 'http://www.w3.org/2000/svg', far = [], near = [], i;
    var col = '#5cd980';
    function mk(op) {
      var p = document.createElementNS(NS, 'path');
      p.setAttribute('stroke', col); p.setAttribute('stroke-width', '3.1');
      p.setAttribute('stroke-linecap', 'round'); p.setAttribute('stroke-linejoin', 'round');
      p.setAttribute('fill', 'none'); if (op) p.setAttribute('opacity', op);
      svg.appendChild(p); return p;
    }
    for (i = 0; i < 2; i++) far.push(mk('0.5'));
    var torso = mk(null);
    var head = document.createElementNS(NS, 'circle'); head.setAttribute('fill', col); head.setAttribute('r', '3');
    svg.appendChild(head);
    for (i = 0; i < 2; i++) near.push(mk(null));
    this.phase = 1.1; this.speed = 2.8;
    this.draw = function () {
      var p = this.phase, bounce = -Math.abs(Math.sin(p)) * 2, lean = 0.30 + Math.min(0.14, this.speed * 0.02);
      var hip = [34 * 0.46, 34 * 0.56 + bounce];
      function pt(o, len, a) { return [o[0] + len * Math.sin(a), o[1] + len * Math.cos(a)]; }
      function d2(a, b, c) { return 'M' + a[0].toFixed(2) + ' ' + a[1].toFixed(2) + 'L' + b[0].toFixed(2) + ' ' + b[1].toFixed(2) + 'L' + c[0].toFixed(2) + ' ' + c[1].toFixed(2); }
      var shoulder = [hip[0] + Math.sin(lean) * 9.5, hip[1] - Math.cos(lean) * 9.5];
      var hd = [shoulder[0] + Math.sin(lean) * 4.5, shoulder[1] - Math.cos(lean) * 4.5];
      function leg(lp) {
        var ta = lean * 0.35 + 0.95 * Math.sin(lp), knee = pt(hip, 7.2, ta);
        var flex = 0.22 + 1.05 * Math.max(0, -Math.sin(lp)) + 0.35 * Math.max(0, -Math.cos(lp));
        return d2(hip, knee, pt(knee, 6.8, ta - flex));
      }
      function arm(ap) {
        var sa = lean * 0.5 + 0.72 * Math.sin(ap), elbow = pt(shoulder, 5.2, sa);
        return d2(shoulder, elbow, pt(elbow, 5.0, sa + 1.25 + 0.25 * Math.sin(ap)));
      }
      far[0].setAttribute('d', leg(p + Math.PI));
      far[1].setAttribute('d', arm(p));
      torso.setAttribute('d', 'M' + hip[0].toFixed(2) + ' ' + hip[1].toFixed(2) + 'L' + shoulder[0].toFixed(2) + ' ' + shoulder[1].toFixed(2));
      head.setAttribute('cx', hd[0].toFixed(2)); head.setAttribute('cy', hd[1].toFixed(2));
      near[0].setAttribute('d', leg(p));
      near[1].setAttribute('d', arm(p + Math.PI));
    };
    this.advance = function (dt, targetSpeed) {
      var ease = Math.min(1, dt / 0.7);
      this.speed += (targetSpeed - this.speed) * ease;
      var cadence = Math.min(195, Math.max(150, 152 + this.speed * 12));
      var hz = Math.min(1.9, Math.max(0.8, cadence / 120));
      this.phase = (this.phase + 2 * Math.PI * hz * dt) % (2 * Math.PI);
    };
  }

  // Sport band, from Filip Vitas's pure-CSS Apple Watch (codepen.io/FilipVitas/pen/BaLrzaN, MIT).
  var BAND_PATH = 'M543.6 595.3a545 545 0 01-73.5 6c-22.8-.2-58.1-3.2-64.5-5-5.9-1.8-5.8-.9-16.2-5.4 6.3 4.4 9.4 7.8 12.3 13.8 4.4 9 5.7 16 7 38.2 1 16 1.3 17.3 3.7 19.7 6 5.8 28.7 9.4 60.1 9.4 30.8 0 53.3-3.4 60-9.1 2.4-2.1 2.8-3.9 3.6-15.8 1.2-18.5 1.6-22.6 2.8-28.6a82 82 0 012-7.5c3-9.2 6.8-14.6 14.1-19.7-4 1.8-7.3 2.5-11.4 4zm8-3';
  function band(pos) {
    var top = pos === 'top';
    var g = 'wt-g' + pos;
    var tf = 'gradientTransform="matrix(165.562 0 0 -81.141 389.4 672)" gradientUnits="userSpaceOnUse"';
    return '<svg class="wt-band wt-band-' + pos + '" viewBox="389.4 590.9 165.6 81.1">' +
      '<linearGradient id="' + g + 'a" x1=".5" y1="1" x2=".5" y2="0" ' + tf + '>' +
        '<stop offset="0%" stop-color="' + (top ? '#3c3b39' : '#636260') + '"/>' +
        '<stop offset="100%" stop-color="' + (top ? '#61605e' : '#3b3a38') + '"/></linearGradient>' +
      '<linearGradient id="' + g + 'b" x1=".9" y1=".5" x2=".1" y2=".5" ' + tf + '>' +
        '<stop offset="0%" stop-color="#444"/><stop offset="48%" stop-opacity="0" stop-color="#4e4d4b"/>' +
        '<stop offset="100%" stop-color="#444"/></linearGradient>' +
      '<path d="' + BAND_PATH + '" fill="url(#' + g + 'a)"/>' +
      '<path d="' + BAND_PATH + '" fill="url(#' + g + 'b)" style="mix-blend-mode:darken"/></svg>';
  }

  function build() {
    var root = el('div', 'wt');
    root.setAttribute('role', 'img');
    root.setAttribute('aria-label', 'Apple Watch running the AARC workout screen');
    root.innerHTML =
      '<div class="wt-hw">' +
      band('top') + band('bot') +
      '<div class="wt-case">' +
        '<div class="wt-fs-top"></div><div class="wt-fs-bot"></div>' +
        '<div class="wt-crown"></div><div class="wt-button"></div>' +
        '<div class="wt-glass"></div>' +
        '<div class="wt-display">' +
        '<div class="wt-screen" aria-hidden="true">' +
          '<section class="wt-page wt-ctl">' +
            '<div class="wt-gate"><b>CROSSED THE GATE</b><small>tap when you pass the timing mat</small></div>' +
            '<div class="wt-corral">IN CORRAL · <span>0:00</span></div>' +
            '<div class="wt-end"><i></i>End</div>' +
          '</section>' +
          '<section class="wt-page wt-metrics">' +
            '<div class="wt-head"><div class="wt-badge"><svg viewBox="0 0 34 34"></svg></div>' +
              '<span class="wt-rec"><i></i>REC</span><span class="wt-time">0:00</span></div>' +
            '<div class="wt-hair"></div>' +
            '<div class="wt-grid">' +
              '<div class="wt-q"><div class="wt-vrow"><span class="wt-v" data-k="dist">0</span></div><span class="wt-l" data-k="unit">M</span></div>' +
              '<div class="wt-q"><div class="wt-vrow"><span class="wt-v wt-pace" data-k="pace">-</span></div><span class="wt-l">PACE</span></div>' +
              '<div class="wt-q"><div class="wt-vrow"><span class="wt-v" data-k="hr">-</span><svg class="wt-heart" viewBox="0 0 24 24"><path d="' + HEART + '"/></svg></div><span class="wt-l">BPM</span></div>' +
              '<div class="wt-q"><div class="wt-vrow"><span class="wt-v" data-k="kcal">0</span></div><span class="wt-l">CAL</span></div>' +
            '</div>' +
          '</section>' +
          '<section class="wt-page wt-map">' +
            '<div class="wt-maplayer"><img alt="" decoding="async"><svg viewBox="0 0 2400 1840" preserveAspectRatio="none"></svg></div>' +
            '<div class="wt-me"></div><div class="wt-cap">0.00 km</div><div class="wt-legal">Legal</div>' +
          '</section>' +
          '<div class="wt-coach">' +
            '<div class="wt-who"><i></i><b>RICKY</b><span class="wt-ago">0s</span>' +
              '<svg class="wt-x" viewBox="0 0 20 20"><circle cx="10" cy="10" r="10" fill="rgba(235,235,245,.22)"/><path d="M6.6 6.6l6.8 6.8M13.4 6.6l-6.8 6.8" stroke="rgba(235,235,245,.75)" stroke-width="2" stroke-linecap="round"/></svg></div>' +
            '<div class="wt-line"><p></p></div>' +
            '<div class="wt-like"><svg viewBox="0 0 24 24"><path d="' + HEART + '"/></svg><span>tap</span></div>' +
          '</div>' +
          '<div class="wt-clock">10:09</div>' +
        '</div>' +
      '</div></div></div>';
    return root;
  }

  function mount(host, opts) {
    opts = opts || {};
    var sim = opts.sim || window.AARC_SIM;
    var root = build();
    if (opts.fade !== false) root.classList.add('wt-fade');
    host.appendChild(root);

    var q = function (s) { return root.querySelector(s); };
    var hw = q('.wt-hw');
    // The hardware is drawn in the pen's pixels (264 x 440); scale it to the slot.
    var fitHw = function () {
      var w = root.clientWidth;
      if (w) hw.style.transform = 'translateX(-50%) scale(' + (w / 290) + ')';
    };
    fitHw();
    var screen = q('.wt-screen');
    var pages = { ctl: q('.wt-ctl'), metrics: q('.wt-metrics'), map: q('.wt-map') };
    var order = ['ctl', 'metrics', 'map'];
    var time = q('.wt-time'), dist = q('[data-k=dist]'), unit = q('[data-k=unit]'), pace = q('[data-k=pace]');
    var hr = q('[data-k=hr]'), kcal = q('[data-k=kcal]'), hrQuad = hr.parentNode;
    var clock = q('.wt-clock'), gate = q('.wt-gate'), corralClock = q('.wt-corral span');
    var coach = q('.wt-coach'), who = q('.wt-who'), whoName = q('.wt-who b'), ago = q('.wt-ago');
    var lineBox = q('.wt-line'), lineP = q('.wt-line p'), likeLbl = q('.wt-like span');
    var layer = q('.wt-maplayer'), mapImg = q('.wt-maplayer img'), trailSvg = q('.wt-maplayer svg'), cap = q('.wt-cap');
    var runner = new Runner(q('.wt-badge svg'));
    runner.draw();

    mapImg.src = opts.mapSrc || 'london.jpg';

    /* Route points: [xFrac, yFrac, ...]. From opts.route, window.AARC_ROUTE, or fetched JSON. */
    var route = null, trail = [], drawnK = -1, tipSeg = null;
    function takeRoute(r) { if (r && r.length > 1) { route = r; drawnK = -1; trailSvg.innerHTML = ''; } }
    takeRoute(opts.route || (window.AARC_ROUTE && (window.AARC_ROUTE.route || window.AARC_ROUTE)));
    if (!route && typeof fetch === 'function') {
      fetch(opts.routeSrc || 'london-route.json').then(function (r) { return r.json(); })
        .then(function (j) { takeRoute(j.route || j); }).catch(function () {});
    }
    function segColor(i, n) {
      // pace-hued like WatchRouteMap: slow red to fast green; a deterministic speed profile per vertex
      var v = 0.5 + 0.32 * Math.sin(i * 0.19) + 0.18 * Math.sin(i * 0.61 + 1.3);
      return hsv(0.33 * Math.max(0, Math.min(1, v)), 0.85, 0.95);
    }
    function seg(a, b, color) {
      var l = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      l.setAttribute('x1', a[0] * 2400); l.setAttribute('y1', a[1] * 1840);
      l.setAttribute('x2', b[0] * 2400); l.setAttribute('y2', b[1] * 1840);
      l.setAttribute('stroke', color); l.setAttribute('stroke-width', '11.5'); l.setAttribute('stroke-linecap', 'round');
      trailSvg.appendChild(l); return l;
    }
    function drawTrail(r) {
      var pos = [r.xFrac, r.yFrac];
      if (route) {
        var n = route.length, k = Math.max(0, Math.min(n - 1, Math.floor((r.trailFrac || 0) * (n - 1))));
        if (k !== drawnK) {
          if (k < drawnK) { trailSvg.innerHTML = ''; drawnK = -1; }
          if (tipSeg) { tipSeg.remove(); tipSeg = null; }
          for (var i = Math.max(1, drawnK + 1); i <= k; i++) seg(route[i - 1], route[i], segColor(i, n));
          drawnK = k;
        }
        if (!tipSeg) tipSeg = seg(route[k], pos, segColor(k + 1, n));
        tipSeg.setAttribute('x2', pos[0] * 2400); tipSeg.setAttribute('y2', pos[1] * 1840);
      } else {
        var last = trail[trail.length - 1];
        if (!last || Math.hypot(last[0] - pos[0], last[1] - pos[1]) > 0.002) {
          if (last) seg(last, pos, segColor(trail.length, 200));
          trail.push(pos);
        }
      }
    }

    var cur = null, lastPage = null, prevPhase = null, pressUntil = 0, corralStart = 0;
    var coachId = null, coachSeen = 0, lastHr = 0, raf = 0, visible = true, lastT = 0, speedMps = 2.8;

    function showPage(name) {
      if (name === lastPage) return;
      var first = lastPage === null, idx = order.indexOf(name);
      order.forEach(function (k, i) {
        var p = pages[k], off = i - idx;
        if (first) p.style.transition = 'none';
        p.style.transform = 'translateX(' + (off * 100) + '%)';
        p.style.opacity = off === 0 ? '1' : '0';
        if (first) { void p.offsetWidth; p.style.transition = ''; }
      });
      lastPage = name;
    }

    function fitLine() {
      var size = 19;
      lineP.style.fontSize = 'calc(var(--pt) * ' + size + ')';
      while (size > 10 && lineP.scrollHeight > lineBox.clientHeight + 1) {
        size -= 0.5;
        lineP.style.fontSize = 'calc(var(--pt) * ' + size + ')';
      }
    }

    function render(s) {
      cur = s;
      var now = Date.now(), race = s.race, mode = s.mode;
      root.classList.toggle('wt-race', mode === 'race' && !!race);
      root.classList.toggle('wt-indoor', mode === 'indoor');

      setText(clock, clockNow());
      setText(time, fmtElapsed(s.elapsedS));
      var m = s.distM || 0, big = m >= 1000;
      var dv = big ? (m / 1000).toFixed(2) : String(Math.round(m));
      setText(dist, dv);
      dist.classList.toggle('wt-sm', dv.length > 4);
      setText(unit, big ? 'KM' : 'M');
      setText(pace, fmtPace(s.paceSecPerKm));
      var h = s.hr > 0 ? String(Math.round(s.hr)) : '-';
      if (h !== hr.textContent) {
        setText(hr, h);
        if (!REDUCED && lastHr && Math.round(s.hr) > lastHr) {
          hrQuad.classList.remove('wt-beat'); void hrQuad.offsetWidth; hrQuad.classList.add('wt-beat');
        }
        lastHr = Math.round(s.hr || 0);
      }
      setText(kcal, String(Math.round(s.kcal || 0)));
      speedMps = s.paceSecPerKm > 0 ? 1000 / s.paceSecPerKm : (s.speedKmh || 0) / 3.6;

      // Page choice: corral -> controls (gate), outdoor mid-window -> map, else metrics.
      var phase = race ? race.phase : null;
      if (phase === 'corral' && prevPhase !== 'corral') corralStart = now - 412000;
      if (prevPhase === 'corral' && phase === 'racing') pressUntil = now + 650;
      prevPhase = phase;
      gate.classList.toggle('wt-press', now < pressUntil && now > pressUntil - 450);
      if (phase === 'corral') setText(corralClock, fmtElapsed((now - corralStart) / 1000));

      var page = 'metrics';
      if (phase === 'corral' || now < pressUntil) page = 'ctl';
      else if (mode === 'outdoor' && s.route && opts.mapPage !== false &&
               s.modeProgress > 0.5 && s.modeProgress < 0.74) page = 'map';
      showPage(page);

      if (s.route && (mode === 'outdoor' || page === 'map')) {
        layer.style.setProperty('--mx', s.route.xFrac);
        layer.style.setProperty('--my', s.route.yFrac);
        drawTrail(s.route);
        setText(cap, (m / 1000).toFixed(2) + ' km');
      }

      // Coach overlay
      var c = s.coach;
      if (c && c.text) {
        if (c.id !== coachId) {
          coachId = c.id; coachSeen = now;
          var hb = /home/i.test(c.voice || '');
          setText(whoName, hb ? 'HOME BASE' : 'RICKY');
          who.style.color = hb ? 'var(--wt-homebase)' : 'var(--wt-ricky)';
          setText(lineP, '“' + excerpt(c.text, opts.maxChars || 120) + '”');
          coach.classList.add('wt-on');
          fitLine();
        }
        coach.classList.toggle('wt-liked', !!c.liked);
        setText(likeLbl, c.liked ? 'liked' : 'tap');
        var a = Math.floor((now - coachSeen) / 1000);
        setText(ago, a < 60 ? a + 's' : Math.floor(a / 60) + 'm');
      } else if (coachId !== null) {
        coachId = null;
        coach.classList.remove('wt-on');
      }
    }

    function frame(t) {
      raf = 0;
      if (!visible) return;
      var dt = lastT ? (t - lastT) / 1000 : 0;
      lastT = t;
      if (dt > 0 && dt < 0.5 && !(cur && cur.race && cur.race.phase === 'corral')) {
        runner.advance(dt, speedMps);
        runner.draw();
      }
      raf = requestAnimationFrame(frame);
    }
    function startAnim() { if (!REDUCED && !raf) { lastT = 0; raf = requestAnimationFrame(frame); } }

    var io = null;
    if (typeof IntersectionObserver === 'function') {
      io = new IntersectionObserver(function (es) {
        visible = es[es.length - 1].isIntersecting;
        if (visible) startAnim();
      });
      io.observe(root);
    }
    startAnim();

    var ro = null;
    if (typeof ResizeObserver === 'function') {
      ro = new ResizeObserver(function () { fitHw(); if (coachId !== null) fitLine(); });
      ro.observe(root);
    }

    var unsub = null;
    if (sim && typeof sim.subscribe === 'function') unsub = sim.subscribe(render);
    else if (sim && sim.state) render(sim.state);

    return {
      root: root,
      render: render,
      destroy: function () {
        if (unsub) unsub();
        if (raf) cancelAnimationFrame(raf);
        if (io) io.disconnect();
        if (ro) ro.disconnect();
        root.remove();
      }
    };
  }

  window.AARCWatch = { mount: mount };
})();
