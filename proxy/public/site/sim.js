/* AARC homepage run simulator. Implements the AARC_SIM contract (see CONTRACT.md).
   Plain script, no modules, no dependencies. Load before phone.js / watch.js. */
(function () {
  'use strict';

  // Hyde Park loop on london.jpg (2400x1840): x,y pairs in 1/10000 of the image.
  var RAW = [7767,2789,7758,2817,7735,2918,7723,2950,7683,3007,7644,3029,7589,3039,7435,3035,6302,3071,5331,3111,5337,3193,5343,3275,5105,3357,5105,3357,4841,3450,4712,3486,4585,3513,4501,3526,4411,3530,4338,3494,4273,3558,4249,3573,4164,3584,3932,3625,3895,3619,3875,3601,3850,3615,3790,3630,3709,3677,3623,3708,3469,3792,3469,3792,3408,3825,3331,3829,3188,3818,3169,3823,3123,3858,3080,3932,3044,3972,3038,3969,3032,3951,3020,3953,3009,3955,3010,3964,3019,4057,3044,4150,3202,4562,3223,4595,3248,4617,3237,4646,3231,4677,3218,4684,3159,4735,3127,4774,3054,4864,3028,5022,3009,5192,2996,5247,2941,5347,2820,5514,2790,5553,2701,5642,2681,5670,2659,5729,2622,5959,2532,6742,2532,6742,2528,6775,2601,6813,2788,6911,2808,6914,3004,6870,3092,6848,3157,6954,3269,6854,3291,6824,3316,6834,3353,6835,3474,6839,3542,6785,3716,6679,4271,6354,4436,6262,4675,6164,4675,6164,4738,6144,4776,6143,4794,6134,5188,5988,5275,6120,5506,6470,5565,6481,5979,6533,6051,6753,6123,6972,6229,7221,6229,7221,6263,7300,6256,7072,6250,6844,6330,6750,6386,6679,6424,6604,6440,6556,6556,6081,6609,5899,6873,5255,7016,4905,7081,4862,7328,4698,7328,4698,7811,3593,7822,3591,7832,3594,7818,3501,7809,3388,7797,3370,7803,3361,7853,3283,7829,3260,7814,3232,7824,3165,7843,3093,7897,2887,7892,2883,7884,2877,7825,2842,7763,2807,7767,2789];
  var IMG_W = 2400, IMG_H = 1840;
  var LOOP_M = 4880; // measured from the route's lat/lon

  var PTS = [];
  for (var i = 0; i < RAW.length; i += 2) PTS.push([RAW[i] / 10000, RAW[i + 1] / 10000]);
  var CUM = [0];
  for (i = 1; i < PTS.length; i++) {
    var dx = (PTS[i][0] - PTS[i - 1][0]) * IMG_W, dy = (PTS[i][1] - PTS[i - 1][1]) * IMG_H;
    CUM.push(CUM[i - 1] + Math.sqrt(dx * dx + dy * dy));
  }
  var PIX_LEN = CUM[CUM.length - 1];

  function routeAt(distM, offsetM) {
    var m = ((distM + offsetM) % LOOP_M + LOOP_M) % LOOP_M;
    var target = (m / LOOP_M) * PIX_LEN;
    var lo = 0, hi = CUM.length - 1;
    while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (CUM[mid] <= target) lo = mid; else hi = mid; }
    var seg = CUM[hi] - CUM[lo] || 1, t = (target - CUM[lo]) / seg;
    var a = PTS[lo], b = PTS[hi];
    // heading: 0 = up (north on the image), clockwise, in degrees
    var hx = (b[0] - a[0]) * IMG_W, hy = (b[1] - a[1]) * IMG_H;
    var heading = (Math.atan2(hx, -hy) * 180 / Math.PI + 360) % 360;
    return {
      xFrac: a[0] + (b[0] - a[0]) * t,
      yFrac: a[1] + (b[1] - a[1]) * t,
      headingDeg: Math.round(heading),
      trailFrac: m / LOOP_M
    };
  }

  // Seeded noise so the numbers wobble like a body, not like Math.random.
  var seed = (Date.now() % 2147483646) + 1;
  function rnd() { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }
  function gauss() { return (rnd() + rnd() + rnd() - 1.5) / 1.5; }
  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function fmtPace(s) { s = Math.round(s); return Math.floor(s / 60) + ':' + ('0' + (s % 60)).slice(-2); }
  function fmtKm(m) { return (m / 1000).toFixed(1); }

  var REDUCED = false;
  try { REDUCED = window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) {}

  var WINDOW_S = 14;
  var ORDER = ['indoor', 'outdoor', 'race'];

  // Per-mode physiology. accel = run-seconds per real second.
  var MODES = {
    indoor: {
      startS: 23 * 60 + 6, startM: 4210, pace: 330, paceWob: 3, hrBase: 151, hrPerSec: 0.9,
      drift: 0.02, kcalPerKm: 68, accel: 12, routeOffset: null,
      batteries: { watch: 82, phone: 64, camera: null },
      music: [{ title: 'Belt Drive', artist: 'The Incline Society' }, { title: 'Fluorescent Gym Hymn', artist: 'Low Ceiling' }]
    },
    outdoor: {
      startS: 18 * 60 + 40, startM: 3190, pace: 350, paceWob: 10, hrBase: 147, hrPerSec: 1.0,
      drift: 0.015, kcalPerKm: 70, accel: 18, routeOffset: 1400,
      batteries: { watch: 77, phone: 58, camera: null },
      music: [{ title: 'Serpentine', artist: 'Marble Arch Choir' }, { title: 'Park Lane Money', artist: 'Kensington Static' }]
    },
    race: {
      startS: 3 * 3600 + 5 * 60 + 2, startM: 31040, pace: 420, paceWob: 14, hrBase: 152, hrPerSec: 1.1,
      drift: 0.05, kcalPerKm: 74, accel: 18, routeOffset: 2600,
      batteries: { watch: 41, phone: 37, camera: 58 },
      music: [{ title: 'Kilometre Thirty One', artist: 'Glycogen Debt' }, { title: 'Hold The Line', artist: 'Pacer Balloons' }]
    }
  };
  var AID = [{ km: 32.5, what: 'Gel + salt' }, { km: 35, what: 'Water' }, { km: 37.5, what: 'Gel' }, { km: 40, what: 'Water + salt' }];

  // Coach lines. {pace} {hr} {km} {split} {title} are filled from live numbers.
  var LINES = {
    indoor: [
      ['Ricky', 'Twenty three minutes running at a wall. Very brave.'],
      ['Ricky', 'The belt is doing half the work and you are still sweating like it is a job interview.'],
      ['Ricky', '{pace} on a treadmill. The treadmill is impressed. Nobody else is.'],
      ['Ricky', 'One percent incline. Everest has been informed. It is not worried.'],
      ['Ricky', 'You have been staring at the same fire exit for {km} km. Make it look like a choice.'],
      ['Home Base', 'Belt reads 2% long against the watch. Trust the watch, Ricky has been told.']
    ],
    outdoor: [
      ['Ricky', 'Serpentine on your left. The swans are overtaking.'],
      ['Ricky', 'Speakers\' Corner ahead. Nobody there talks more rubbish than your arm swing.'],
      ['Ricky', 'Lovely morning in Hyde Park. Shame about the gait.'],
      ['Ricky', 'That is the Long Water. Do not get ideas, you cannot swim either.'],
      ['Ricky', 'Park Lane. Most expensive road on the board, cheapest kilometre you have run.'],
      ['Home Base', '12 degrees, wind from the west. Headwind on Bayswater Road, it is behind you on Park Lane.']
    ],
    race: [
      ['Home Base', 'Aid station in 400 m: gel now, salt at 32.5.'],
      ['Ricky', 'Kilometre 31. This is where the marathon starts and your excuses end.'],
      ['Home Base', 'HR {hr} and falling, legs are the limiter, not the engine.'],
      ['Ricky', '{pace} a kilometre. Still technically running. The lawyers have checked.'],
      ['Home Base', 'Got your voice note. Yes, the 4:45 pacer is behind you. Stay ahead of the balloons.'],
      ['Ricky', 'The wall is up ahead. I have told it you are coming. It laughed.'],
      ['Home Base', 'Signal gone. Race pack is on the phone, cues keep coming.'],
      ['Home Base', 'Camera at 18%. Swap at the next aid station, spare is in the left pocket.']
    ],
    paceDrop: [
      ['Ricky', 'You just slowed to {pace}. Was there a sale on?'],
      ['Ricky', '{pace}. I have seen faster queues at the post office.'],
      ['Ricky', 'Pace is sliding. Your legs have filed a complaint. Complaint noted, rejected.']
    ],
    hrSpike: [
      ['Ricky', 'Heart rate {hr}. Your watch has started drafting a eulogy.'],
      ['Ricky', '{hr} bpm on the flat. Bold. Stupid, but bold.']
    ],
    split: [
      ['Ricky', 'Kilometre {km} in {split}. Nobody clap, it will go to his head.'],
      ['Ricky', 'That split was {split}. Almost respectable. Do not let it go to your head.']
    ],
    music: [
      ['Ricky', '{title} is 172 bpm. You are at 164. Commit to the bit.']
    ]
  };
  var CORRAL_LINE = ['Home Base', 'Gate in 40 m. The clock starts on the mat, not before.'];

  var listeners = [];
  var state = null;
  var run = null;       // internal per-window run state
  var lineIdx = { indoor: 0, outdoor: 0, race: 0, paceDrop: 0, hrSpike: 0, split: 0, music: 0 };
  var coachId = 0;
  var modeIdx = 0;
  var windowT = 0;      // real seconds into the current showcase window
  
  function buildHistory(cfg, distM) {
    // Synthetic 100 m buckets up to distM, keep the last 60.
    var chart = [], n = Math.floor(distM / 100), first = 0;
    var p = cfg.pace, h = cfg.hrBase - 12;
    for (var k = first; k < n; k++) {
      var frac = k / Math.max(1, n);
      p = cfg.pace + Math.sin(k / 3.1) * cfg.paceWob * 0.8 + gauss() * cfg.paceWob * 0.5 + (cfg === MODES.race ? frac * 25 : 0);
      h = cfg.hrBase - 6 + frac * 8 + gauss() * 2.5 + (cfg === MODES.race ? 4 : 0);
      chart.push({ dKm: Math.round(k) / 10, speedKmh: +(3600 / p).toFixed(2), hr: Math.round(h) });
    }
    return chart;
  }

  function enterMode(mode) {
    var cfg = MODES[mode];
    windowT = 0;
    var track = cfg.music[Math.floor(rnd() * cfg.music.length)];
    run = {
      mode: mode, cfg: cfg,
      t: cfg.startS + Math.floor(rnd() * 20), d: cfg.startM + Math.floor(rnd() * 40),
      pace: cfg.pace, paceTarget: cfg.pace, hr: cfg.hrBase, kcalBase: 0,
      bucketM: 0, bucketSp: 0, bucketHr: 0, bucketN: 0,
      paceHist: [], lastKm: 0, lastKmT: 0, coachUntil: 0, nextCoachAt: mode === 'race' ? 0.3 : 3.5,
      track: track, trackLen: 190 + Math.floor(rnd() * 60), trackPos: 30 + rnd() * 60,
      batteries: { watch: cfg.batteries.watch, phone: cfg.batteries.phone, camera: cfg.batteries.camera },
      chart: null, coach: null, corral: mode === 'race', spike: 0
    };
    run.kcalBase = Math.round(run.d / 1000 * cfg.kcalPerKm);
    run.lastKm = Math.floor(run.d / 1000);
    run.lastKmT = run.t - (run.d % 1000) / 1000 * cfg.pace;
    run.bucketM = Math.floor(run.d / 100) * 100;
    run.chart = buildHistory(cfg, run.bucketM);
    run.hr = run.chart.length ? run.chart[run.chart.length - 1].hr : cfg.hrBase;
  }

  function fill(text) {
    return text
      .replace('{pace}', fmtPace(run.pace))
      .replace('{hr}', String(Math.round(run.hr)))
      .replace('{km}', run.mode === 'race' ? String(run.lastKm) : fmtKm(run.d))
      .replace('{split}', run.lastSplit ? fmtPace(run.lastSplit) : fmtPace(run.pace))
      .replace('{title}', run.track.title);
  }

  function pick(pool) {
    var arr = LINES[pool], i = lineIdx[pool] % arr.length;
    lineIdx[pool] = i + 1;
    return arr[i];
  }

  function chooseLine() {
    var hist = run.paceHist;
    var slowed = hist.length > 20 && run.pace - hist[hist.length - 20] > run.cfg.paceWob * 0.9;
    if (run.justSplit) { run.justSplit = false; return pick('split'); }
    if (run.spike > 0 && run.mode !== 'race') return pick('hrSpike');
    if (slowed && run.mode !== 'race') return pick('paceDrop');
    if (run.mode === 'indoor' && rnd() < 0.15) return pick('music');
    return pick(run.mode);
  }

  function step(dtReal) {
    var cfg = run.cfg;
    windowT += dtReal;
    var accel = REDUCED ? Math.max(3, cfg.accel / 4) : cfg.accel;

    if (run.corral && windowT >= 2.5) {
      run.corral = false;
      run.coach = null; run.coachUntil = 0; run.nextCoachAt = windowT + 0.6;
    }

    if (!run.corral) {
      var dt = dtReal * accel;
      // pace: slow sinusoid + mean-reverting random walk; race slowly fades
      run.paceTarget += gauss() * cfg.paceWob * 0.08 + (cfg.pace + Math.sin(run.t / 47) * cfg.paceWob * 0.7 - run.paceTarget) * 0.03;
      if (run.mode === 'race') run.paceTarget += dt * 0.01;
      run.pace += (run.paceTarget - run.pace) * 0.25;
      run.pace = clamp(run.pace, cfg.pace - cfg.paceWob * 2.2, cfg.pace + cfg.paceWob * 2.6);
      run.paceHist.push(run.pace); if (run.paceHist.length > 80) run.paceHist.shift();

      // occasional surge: HR spike that decays
      if (run.mode !== 'race' && run.spike <= 0 && rnd() < 0.0025) run.spike = 9 + rnd() * 6;
      if (run.spike > 0) run.spike -= dtReal * 1.2;

      // HR follows effort (faster pace -> higher HR) with lag, plus cardiac drift over time
      var effort = (cfg.pace - run.pace) * 0.45;
      var drift = (run.t - cfg.startS) * cfg.drift / 60;
      var hrTarget = cfg.hrBase + effort + drift + Math.max(0, run.spike) + gauss() * 0.8;
      if (run.mode === 'race') hrTarget -= (run.t - cfg.startS) * 0.012; // the race: HR falling, legs gone
      run.hr += (hrTarget - run.hr) * clamp(dtReal * cfg.hrPerSec, 0, 1);

      var vMs = 1000 / run.pace;
      run.t += dt;
      run.d += vMs * dt;

      // 100 m chart buckets
      run.bucketSp += 3.6 * vMs; run.bucketHr += run.hr; run.bucketN++;
      if (run.d - run.bucketM >= 100) {
        run.bucketM += 100;
        run.chart.push({ dKm: Math.round(run.bucketM / 100) / 10 - 0.1, speedKmh: +(run.bucketSp / run.bucketN).toFixed(2), hr: Math.round(run.bucketHr / run.bucketN) });
        
        run.bucketSp = run.bucketHr = run.bucketN = 0;
      }
      var km = Math.floor(run.d / 1000);
      if (km > run.lastKm) { run.lastSplit = run.t - run.lastKmT; run.lastKmT = run.t; run.lastKm = km; run.justSplit = true; }

      run.trackPos += dtReal * (REDUCED ? 1 : 3);
      if (run.trackPos > run.trackLen) {
        run.trackPos = 0;
        var list = cfg.music; run.track = list[(list.indexOf(run.track) + 1) % list.length];
      }
      if (run.batteries.camera != null && rnd() < 0.01) run.batteries.camera = Math.max(12, run.batteries.camera - 1);
    }

    // coach lines: ~5 s on, then a gap
    if (run.coach && windowT >= run.coachUntil) {
      run.coach = null;
      run.nextCoachAt = windowT + (REDUCED ? 6 : 4.5);
    }
    if (!run.coach && windowT >= run.nextCoachAt) {
      var line = run.corral ? CORRAL_LINE : chooseLine();
      run.coach = { id: ++coachId, voice: line[0], text: fill(line[1]), liked: line[0] === 'Ricky' && coachId % 3 === 0 };
      run.coachUntil = windowT + (run.corral ? 2.2 : 5);
    }

    if (!REDUCED && windowT >= WINDOW_S) {
      modeIdx = (modeIdx + 1) % ORDER.length;
      enterMode(ORDER[modeIdx]);
    }
  }

  function snapshot() {
    var racing = run.mode === 'race';
    var corral = racing && run.corral;
    var dist = corral ? 0 : run.d;
    var aid = null;
    if (racing) {
      for (var a = 0; a < AID.length; a++) if (AID[a].km * 1000 > run.d) { aid = AID[a]; break; }
      aid = aid || AID[AID.length - 1];
    }
    return {
      mode: run.mode,
      modeProgress: REDUCED ? 0 : clamp(windowT / WINDOW_S, 0, 1),
      elapsedS: corral ? 0 : Math.floor(run.t),
      distM: Math.round(dist),
      paceSecPerKm: corral ? 0 : Math.round(run.pace),
      hr: corral ? 96 : Math.round(run.hr),
      kcal: corral ? 0 : Math.round(run.kcalBase + (run.d - run.cfg.startM) / 1000 * run.cfg.kcalPerKm),
      speedKmh: corral ? 0 : +(3600 / run.pace).toFixed(1),
      route: run.cfg.routeOffset == null ? null : routeAt(corral ? 0 : run.d, run.cfg.routeOffset),
      chart: corral ? [] : run.chart.slice(),
      coach: run.coach,
      music: { title: run.track.title, artist: run.track.artist, playing: !corral, progress: clamp(run.trackPos / run.trackLen, 0, 1) },
      batteries: { watch: run.batteries.watch, phone: run.batteries.phone, camera: run.batteries.camera },
      race: racing ? { phase: corral ? 'corral' : 'racing', recording: true, nextAid: { km: aid.km, what: aid.what } } : null,
      units: 'km'
    };
  }

  function emit() {
    state = snapshot();
    api.state = state;
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](state); } catch (e) { if (window.console) console.error(e); }
    }
  }

  var api = {
    state: null,
    modes: ORDER.slice(),
    windowS: WINDOW_S,
    reducedMotion: REDUCED,
    subscribe: function (fn) {
      listeners.push(fn);
      try { fn(state); } catch (e) { if (window.console) console.error(e); }
      return function () { var i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); };
    },
    setMode: function (mode) {
      var i = ORDER.indexOf(mode);
      if (i < 0) return;
      modeIdx = i;
      enterMode(mode);
      emit();
    },
    // Helpers for the page and device mockups.
    formatPace: fmtPace,
    formatClock: function (s) {
      s = Math.max(0, Math.floor(s));
      var h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, ss = s % 60;
      return (h ? h + ':' + ('0' + m).slice(-2) : String(m)) + ':' + ('0' + ss).slice(-2);
    },
    routePoints: PTS
  };

  enterMode(ORDER[0]);
  state = snapshot();
  api.state = state;
  window.AARC_SIM = api;
  // Shared route so mockups need not fetch london-route.json (fails on file://).
  if (!window.AARC_ROUTE) window.AARC_ROUTE = { w: IMG_W, h: IMG_H, loopM: LOOP_M, route: PTS };

  var TICK_MS = 100, last = Date.now();
  setInterval(function () {
    var now = Date.now(), dt = (now - last) / 1000;
    last = now;
    if (document.hidden) return;
    step(Math.min(dt, 0.25));
    emit();
  }, TICK_MS);
})();
