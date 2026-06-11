/// Login page for GET /dash when there is no valid session cookie.
/// Self-contained: inline CSS, inline JS, zero CDN deps.
///
/// The server replaces __AUTH_CODE__ with a freshly minted code before
/// serving. The page renders a QR encoding aarc://dash-auth?code=CODE
/// (compact pure-JS QR encoder below: byte mode, ECC level L, versions
/// 1-5 = single Reed-Solomon block, which covers payloads up to 106
/// bytes — ours is ~42). As a belt-and-braces fallback the code is also
/// shown as text plus a tappable aarc:// link, so even if a QR reader
/// balks the phone path still works.
///
/// NOTE for editors: the embedded JS deliberately avoids backticks and
/// "${" so it can live inside this TS template literal unescaped.
export const LOGIN_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>AARC dash — sign in</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #0e1116; color: #c9d1d9;
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
  }
  .card {
    background: #161b22; border: 1px solid #21262d; border-radius: 12px;
    padding: 32px 36px; max-width: 380px; width: 92%; text-align: center;
  }
  h1 { font-size: 18px; font-weight: 600; color: #e6edf3; margin-bottom: 4px; }
  .sub { color: #8b949e; font-size: 13px; margin-bottom: 20px; }
  #qr {
    background: #fff; border-radius: 8px; padding: 12px;
    width: 232px; height: 232px; margin: 0 auto 18px;
  }
  #qr svg { display: block; width: 100%; height: 100%; }
  .code {
    font: 600 16px/1 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    letter-spacing: 2px; color: #e6edf3; background: #0e1116;
    border: 1px solid #21262d; border-radius: 6px;
    padding: 10px 12px; margin-bottom: 14px; user-select: all; word-break: break-all;
  }
  a.applink {
    display: block; background: #238636; color: #fff; text-decoration: none;
    font-weight: 600; font-size: 15px; border-radius: 8px;
    padding: 12px 16px; margin-bottom: 16px;
  }
  a.applink:active { background: #2ea043; }
  #status { font-size: 13px; color: #8b949e; min-height: 20px; }
  #status.ok { color: #3fb950; }
  #status.err { color: #f85149; }
  .dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%;
    background: #d29922; margin-right: 6px; animation: pulse 1.6s infinite; }
  @keyframes pulse { 0%,100% { opacity: .35; } 50% { opacity: 1; } }
</style>
</head>
<body>
<div class="card">
  <h1>AARC dashboard</h1>
  <p class="sub">Scan with the iPhone camera, or open this page on the phone and tap the button.</p>
  <div id="qr"></div>
  <div class="code" id="codeText"></div>
  <a class="applink" id="applink" href="#">Approve in AARC app</a>
  <p id="status"><span class="dot"></span>Waiting for approval&hellip;</p>
</div>
<script>
"use strict";

// ---------------------------------------------------------------------------
// Compact QR encoder. Byte mode, ECC level L, versions 1-5 only (each is a
// single RS block, so no codeword interleaving). Returns a boolean matrix
// (array of rows) or null if the text doesn't fit.
// ---------------------------------------------------------------------------
function qrMake(text) {
  var i, k, v;
  // UTF-8 encode
  var bytes = [];
  for (i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i);
    if (c < 0x80) bytes.push(c);
    else if (c < 0x800) bytes.push(0xC0 | (c >> 6), 0x80 | (c & 63));
    else bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  var DATA_CW = [0, 19, 34, 55, 80, 108]; // data codewords, level L, v1..v5
  var EC_CW = [0, 7, 10, 15, 20, 26];     // ecc codewords, level L, v1..v5
  var ver = 0;
  for (v = 1; v <= 5; v++) { if (bytes.length <= DATA_CW[v] - 2) { ver = v; break; } }
  if (!ver) return null;
  var size = 17 + 4 * ver;
  var nData = DATA_CW[ver], nEc = EC_CW[ver];

  // --- bit stream: mode 0100, 8-bit count, data, terminator, pads ---
  var bits = [];
  function put(val, len) { for (var b = len - 1; b >= 0; b--) bits.push((val >> b) & 1); }
  put(4, 4);
  put(bytes.length, 8);
  for (i = 0; i < bytes.length; i++) put(bytes[i], 8);
  var cap = nData * 8;
  for (k = 0; k < 4 && bits.length < cap; k++) bits.push(0);
  while (bits.length % 8 !== 0) bits.push(0);
  var padToggle = true;
  while (bits.length < cap) { put(padToggle ? 0xEC : 0x11, 8); padToggle = !padToggle; }
  var data = [];
  for (i = 0; i < cap; i += 8) {
    var byte = 0;
    for (k = 0; k < 8; k++) byte = (byte << 1) | bits[i + k];
    data.push(byte);
  }

  // --- Reed-Solomon over GF(256), reducing polynomial 0x11D ---
  var EXP = new Array(510), LOG = new Array(256);
  var x = 1;
  for (i = 0; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 0x100) x ^= 0x11D; }
  for (i = 255; i < 510; i++) EXP[i] = EXP[i - 255];
  function gmul(a, b) { return (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]]; }
  // generator polynomial: product of (x - alpha^i), i = 0..nEc-1.
  // gen[0] is the leading coefficient (always 1).
  var gen = [1];
  for (i = 0; i < nEc; i++) {
    var ng = new Array(gen.length + 1);
    for (k = 0; k < ng.length; k++) ng[k] = 0;
    for (k = 0; k < gen.length; k++) {
      ng[k] ^= gen[k];
      ng[k + 1] ^= gmul(gen[k], EXP[i]);
    }
    gen = ng;
  }
  // synthetic division: remainder of data(x) * x^nEc by gen(x)
  var ec = new Array(nEc);
  for (k = 0; k < nEc; k++) ec[k] = 0;
  for (i = 0; i < data.length; i++) {
    var factor = data[i] ^ ec[0];
    ec.shift(); ec.push(0);
    if (factor !== 0) for (k = 0; k < nEc; k++) ec[k] ^= gmul(gen[k + 1], factor);
  }
  var cw = data.concat(ec); // single block: no interleaving

  // --- matrix ---
  var M = [], F = []; // module dark?, is function module?
  for (i = 0; i < size; i++) {
    M.push(new Array(size)); F.push(new Array(size));
    for (k = 0; k < size; k++) { M[i][k] = false; F[i][k] = false; }
  }
  function set(r, c, dark) { M[r][c] = dark; F[r][c] = true; }
  function finder(r0, c0) {
    for (var dr = -1; dr <= 7; dr++) for (var dc = -1; dc <= 7; dc++) {
      var rr = r0 + dr, cc = c0 + dc;
      if (rr < 0 || rr >= size || cc < 0 || cc >= size) continue;
      var d = Math.max(Math.abs(dr - 3), Math.abs(dc - 3));
      set(rr, cc, d !== 2 && d !== 4);
    }
  }
  finder(0, 0); finder(0, size - 7); finder(size - 7, 0);
  for (i = 0; i < size; i++) {
    if (!F[6][i]) set(6, i, i % 2 === 0);
    if (!F[i][6]) set(i, 6, i % 2 === 0);
  }
  if (ver >= 2) { // single alignment pattern for v2-v5
    var p = size - 7;
    for (var ar = -2; ar <= 2; ar++) for (var ac = -2; ac <= 2; ac++)
      set(p + ar, p + ac, Math.max(Math.abs(ar), Math.abs(ac)) !== 1);
  }

  // format bits: 15-bit BCH of (ecLevelBits<<3 | mask), level L = 0b01
  function fmtBits(mask) {
    var d = (1 << 3) | mask;
    var r = d << 10;
    for (var b = 14; b >= 10; b--) if ((r >> b) & 1) r ^= 0x537 << (b - 10);
    return ((d << 10) | (r & 0x3FF)) ^ 0x5412;
  }
  function drawFormat(mask) {
    var fb = fmtBits(mask);
    function bit(n) { return ((fb >> n) & 1) === 1; }
    var n;
    for (n = 0; n <= 5; n++) set(n, 8, bit(n));
    set(7, 8, bit(6)); set(8, 8, bit(7)); set(8, 7, bit(8));
    for (n = 9; n < 15; n++) set(8, 14 - n, bit(n));
    for (n = 0; n < 8; n++) set(8, size - 1 - n, bit(n));
    for (n = 8; n < 15; n++) set(size - 15 + n, 8, bit(n));
    set(size - 8, 8, true); // dark module
  }
  drawFormat(0); // reserve format areas before data placement

  // zigzag codeword placement
  var bi = 0, total = cw.length * 8;
  for (var right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (var vert = 0; vert < size; vert++) {
      for (var j = 0; j < 2; j++) {
        var col = right - j;
        var upward = ((right + 1) & 2) === 0;
        var row = upward ? size - 1 - vert : vert;
        if (!F[row][col] && bi < total) {
          M[row][col] = ((cw[bi >> 3] >> (7 - (bi & 7))) & 1) === 1;
          bi++;
        }
      }
    }
  }

  // masking: try all 8, keep lowest penalty (rules 1, 2, 4)
  function maskAt(m, r, c) {
    switch (m) {
      case 0: return (r + c) % 2 === 0;
      case 1: return r % 2 === 0;
      case 2: return c % 3 === 0;
      case 3: return (r + c) % 3 === 0;
      case 4: return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
      case 5: return (r * c) % 2 + (r * c) % 3 === 0;
      case 6: return ((r * c) % 2 + (r * c) % 3) % 2 === 0;
      default: return ((r + c) % 2 + (r * c) % 3) % 2 === 0;
    }
  }
  function applyMask(m) {
    for (var r = 0; r < size; r++) for (var c = 0; c < size; c++)
      if (!F[r][c] && maskAt(m, r, c)) M[r][c] = !M[r][c];
  }
  function penalty() {
    var score = 0, r, c, run, prev, dark = 0;
    for (r = 0; r < size; r++) { // rule 1, rows
      run = 0; prev = null;
      for (c = 0; c < size; c++) {
        if (M[r][c] === prev) { run++; if (run === 5) score += 3; else if (run > 5) score++; }
        else { prev = M[r][c]; run = 1; }
        if (M[r][c]) dark++;
      }
    }
    for (c = 0; c < size; c++) { // rule 1, columns
      run = 0; prev = null;
      for (r = 0; r < size; r++) {
        if (M[r][c] === prev) { run++; if (run === 5) score += 3; else if (run > 5) score++; }
        else { prev = M[r][c]; run = 1; }
      }
    }
    for (r = 0; r < size - 1; r++) for (c = 0; c < size - 1; c++) // rule 2
      if (M[r][c] === M[r][c + 1] && M[r][c] === M[r + 1][c] && M[r][c] === M[r + 1][c + 1]) score += 3;
    score += Math.floor(Math.abs(dark * 100 / (size * size) - 50) / 5) * 10; // rule 4
    return score;
  }
  var best = 0, bestScore = Infinity;
  for (var m = 0; m < 8; m++) {
    applyMask(m); drawFormat(m);
    var s = penalty();
    if (s < bestScore) { bestScore = s; best = m; }
    applyMask(m); // un-apply (XOR is involutive)
  }
  applyMask(best); drawFormat(best);
  return M;
}

function qrToSvg(matrix) {
  var n = matrix.length, d = "";
  for (var r = 0; r < n; r++) for (var c = 0; c < n; c++)
    if (matrix[r][c]) d += "M" + c + " " + r + "h1v1h-1z";
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 ' + (n + 4) + " " + (n + 4) +
    '" shape-rendering="crispEdges"><path d="' + d + '" fill="#000"/></svg>';
}

// ---------------------------------------------------------------------------
// Page wiring
// ---------------------------------------------------------------------------
var CODE = "__AUTH_CODE__";
var URI = "aarc://dash-auth?code=" + CODE;

document.getElementById("codeText").textContent = CODE;
document.getElementById("applink").setAttribute("href", URI);
var matrix = qrMake(URI);
if (matrix) {
  document.getElementById("qr").innerHTML = qrToSvg(matrix);
} else {
  document.getElementById("qr").style.display = "none";
}

var statusEl = document.getElementById("status");
var stopped = false;

function poll() {
  if (stopped) return;
  fetch("/dash/auth/poll", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: CODE })
  }).then(function (res) { return res.json(); }).then(function (body) {
    if (body && body.status === "approved") {
      stopped = true;
      statusEl.className = "ok";
      statusEl.textContent = "Approved — loading dashboard…";
      setTimeout(function () { location.reload(); }, 400);
    } else if (body && (body.status === "unknown" || body.status === "expired")) {
      stopped = true;
      statusEl.className = "err";
      statusEl.innerHTML = 'Code expired. <a href="/dash" style="color:#58a6ff">Get a new one</a>.';
    } else {
      setTimeout(poll, 2000);
    }
  }).catch(function () {
    setTimeout(poll, 4000); // transient network error: back off a little
  });
}
setTimeout(poll, 2000);
</script>
</body>
</html>
`;
