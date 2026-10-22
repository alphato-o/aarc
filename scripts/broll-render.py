#!/usr/bin/env python3
"""Render a captured run as the Control Room B-roll video.

    scripts/broll-render.py <captureDir> [--out file.mp4] [--start S --end S]
                            [--fps 30] [--size 1920x1080] [--rate 10]
                            [--encoder auto|videotoolbox|x264] [--labels]
                            [--music DIR | --no-music]

Needs Python 3 with Pillow (pip install pillow) and ffmpeg/ffprobe on PATH
(or in /opt/homebrew/bin).

Reads a capture written by scripts/broll-capture.py (format aarc-broll/1) and
writes an H.264 + AAC MP4 exactly as long as the run (manifest startedAt to
endedAt), or the --start/--end window in run seconds for previews. Video time
zero is the run start (or --start), so the B-roll lines up with the A-roll on
the voice lines, which are audible in both.

Frame layout: the left 60% is the agent's Claude Code terminal during the run
(the capture's `terminal` lane: prompts, replies typed out, tool calls with
their commands, results, harness notifications, a thinking spinner), scrolling
as it grew. The right 40% is the AARC view: race clock and Beijing time,
distance, pace and HR, the map (no text on the tiles) with the trail and a
moving dot, and under it the AARC message feed: coach lines, his talk-backs as
text, Control Room messages and race events, the one being spoken highlighted
in full.

Audio: every voice line at the moment it played. His talk-backs are left out
(the camera has them). With a music folder (--music, default <captureDir>/music)
a bed fills the gaps: tracks in file-name order, changing where his real music
changed (`music.track` events), fading on pauses, ducked 15 dB under every voice
line. Title, artist and licence come from CREDITS.txt in that folder and the
attribution is printed at the end.

Frames are drawn at an internal rate (--rate, default 10 per second) and
piped raw to ffmpeg, which repeats them up to --fps. Map tiles come from the
proxy (/maptile, AutoNavi, GCJ-02) and are cached in <captureDir>/tiles/; a
tile that cannot be fetched is drawn as a dark grid instead.
"""
import argparse
import bisect
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

TILE_URL = "https://api.aarun.club/maptile?x={x}&y={y}&z={z}"
BEIJING = timezone(timedelta(hours=8))

BG = (10, 13, 19)
PANEL = (16, 20, 28)
CARD = (22, 27, 37)
CARD_HOT = (32, 40, 55)
RULE = (38, 45, 58)
TEXT = (234, 238, 244)
MUTED = (124, 135, 153)
DIM = (82, 92, 108)
TRAIL = (255, 92, 56)
GHOST = (255, 255, 255)
TERM = (138, 214, 150)

SPEAKERS = {
    "ricky": ("RICKY", (255, 178, 54)),
    "jessica": ("JESSICA", (255, 104, 168)),
    "home": ("HOME BASE", (72, 206, 230)),
    "phone": ("PHONE VOICE", (168, 178, 194)),
}
RUNNER = ("RUNNER", (124, 226, 128))
CONTROL = ("CONTROL ROOM", (72, 206, 230))
RACE = ("RACE", (240, 240, 240))

FONT_DIR = Path("/System/Library/Fonts")
SF = FONT_DIR / "SFNS.ttf"
SF_MONO = FONT_DIR / "SFNSMono.ttf"
CJK = FONT_DIR / "Hiragino Sans GB.ttc"
CJK_RE = re.compile(r"[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef\u3000-\u303f]")
TOKEN_RE = re.compile(r"[\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef\u3000-\u303f]|[^\s\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef\u3000-\u303f]+|\s+")


def tool(name):
    found = shutil.which(name)
    if found:
        return found
    alt = f"/opt/homebrew/bin/{name}"
    if os.path.exists(alt):
        return alt
    sys.exit(f"{name} not found")


FFMPEG = tool("ffmpeg")
FFPROBE = tool("ffprobe")


# --- text ------------------------------------------------------------------

def clean_speech(text):
    text = re.sub(r"\[[^\]]*\]", " ", text or "")
    text = re.sub(r"\s*(--|\u2014|\u2013)\s*", ", ", text)
    text = "".join(c for c in text if ord(c) <= 0xFFFF)
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"^[,\s]+", "", text)


def plain(text):
    text = re.sub(r"\s*(\u2014|\u2013)\s*", ", ", text or "")
    text = "".join(c for c in text if ord(c) <= 0xFFFF)
    return re.sub(r"\s+", " ", text).strip()


class Face:
    """A Latin font with a CJK fallback, drawn run by run on a shared baseline."""

    def __init__(self, size, weight="Regular", mono=False):
        path = SF_MONO if mono else SF
        try:
            self.main = ImageFont.truetype(str(path), size)
            try:
                self.main.set_variation_by_name(weight)
            except Exception:
                pass
        except OSError:
            self.main = ImageFont.truetype(str(CJK), size, index=0)
        bold = weight in ("Semibold", "Bold", "Heavy", "Black")
        try:
            self.cjk = ImageFont.truetype(str(CJK), size, index=2 if bold else 0)
        except OSError:
            self.cjk = self.main
        self.size = size

    def runs(self, text):
        out, cur, cur_cjk = [], "", None
        for ch in text:
            is_cjk = bool(CJK_RE.match(ch))
            if cur and is_cjk != cur_cjk:
                out.append((cur, cur_cjk))
                cur = ""
            cur += ch
            cur_cjk = is_cjk
        if cur:
            out.append((cur, cur_cjk))
        return out

    def length(self, text):
        return sum((self.cjk if c else self.main).getlength(r) for r, c in self.runs(text))

    def draw(self, draw, x, baseline, text, fill):
        for run, is_cjk in self.runs(text):
            font = self.cjk if is_cjk else self.main
            draw.text((x, baseline), run, font=font, fill=fill, anchor="ls")
            x += font.getlength(run)
        return x

    def wrap(self, text, width, max_lines=None):
        lines, cur = [], ""
        for tok in TOKEN_RE.findall(text):
            if tok.isspace():
                if cur:
                    cur += " "
                continue
            trial = cur + tok
            if self.length(trial) <= width or not cur:
                while self.length(trial) > width and len(trial) > 1:
                    cut = len(trial)
                    while cut > 1 and self.length(trial[:cut]) > width:
                        cut -= 1
                    lines.append(trial[:cut])
                    trial = trial[cut:]
                cur = trial
            else:
                lines.append(cur.rstrip())
                cur = tok
        if cur.strip():
            lines.append(cur.rstrip())
        if max_lines and len(lines) > max_lines:
            lines = lines[:max_lines]
            lines[-1] = self.fit(lines[-1] + "...", width)
        return lines

    def fit(self, text, width):
        if self.length(text) <= width:
            return text
        while text and self.length(text + "...") > width:
            text = text[:-1]
        return text.rstrip() + "..."


class MonoFace:
    """Monospace text with per-glyph fallback: SF Mono, Menlo, Apple Symbols, Hiragino."""

    CHAIN = [(FONT_DIR / "SFNSMono.ttf", 0), (FONT_DIR / "Menlo.ttc", 0),
             (FONT_DIR / "Apple Symbols.ttf", 0), (CJK, 0)]

    def __init__(self, size, weight="Regular"):
        self.fonts = []
        for path, idx in self.CHAIN:
            try:
                f = ImageFont.truetype(str(path), size, index=idx)
            except OSError:
                continue
            if path.name == "SFNSMono.ttf":
                try:
                    f.set_variation_by_name(weight)
                except Exception:
                    pass
            if path == CJK and weight in ("Semibold", "Bold"):
                try:
                    f = ImageFont.truetype(str(path), size, index=2)
                except OSError:
                    pass
            self.fonts.append(f)
        self._notdef = [bytes(f.getmask("\ue000")) for f in self.fonts]
        self._pick = {}
        self.size = size
        self.adv = self.fonts[0].getlength("M")

    def font_for(self, ch):
        i = self._pick.get(ch)
        if i is None:
            i = 0
            if ord(ch) > 0x7e:
                for n, f in enumerate(self.fonts):
                    if bytes(f.getmask(ch)) != self._notdef[n]:
                        i = n
                        break
            self._pick[ch] = i
        return i

    def runs(self, text):
        out, cur, cur_i = [], "", None
        for ch in text:
            i = self.font_for(ch)
            if cur and i != cur_i:
                out.append((cur, cur_i))
                cur = ""
            cur += ch
            cur_i = i
        if cur:
            out.append((cur, cur_i))
        return out

    def length(self, text):
        if text.isascii():
            return self.adv * len(text)
        return sum(self.adv * len(r) if "\u23bf" in r and r.count("\u23bf") == len(r) else self.fonts[i].getlength(r)
                   for r, i in self.runs(text))

    def draw(self, draw, x, baseline, text, fill):
        for run, i in self.runs(text):
            if "\u23bf" in run:
                # The result elbow: no mono font has it, so draw it on the cell grid.
                for part in re.split("(\u23bf)", run):
                    if part == "\u23bf":
                        s, a = self.size, self.adv
                        w = max(1, round(s / 14))
                        draw.line([(x + a * 0.3, baseline - s * 0.78), (x + a * 0.3, baseline - s * 0.28),
                                   (x + a * 1.0, baseline - s * 0.28)], fill=fill, width=w)
                        x += a
                    elif part:
                        draw.text((x, baseline), part, font=self.fonts[i], fill=fill, anchor="ls")
                        x += self.fonts[i].getlength(part)
                continue
            draw.text((x, baseline), run, font=self.fonts[i], fill=fill, anchor="ls")
            x += self.fonts[i].getlength(run)
        return x

    def wrap(self, text, width):
        """Hard-wrap at word boundaries by pixel width, keeping explicit newlines."""
        out = []
        for para in text.split("\n"):
            para = para.replace("\t", "    ").rstrip()
            if not para:
                out.append("")
                continue
            cur = ""
            for tok in re.findall(r"\s+|[^\s]+", para):
                trial = cur + tok
                if self.length(trial) <= width:
                    cur = trial
                    continue
                if cur.strip():
                    out.append(cur.rstrip())
                    cur = "" if tok.isspace() else tok
                else:
                    cur = tok.lstrip() if not cur else trial
                while self.length(cur) > width:
                    cut = max(1, int(width / self.adv))
                    while cut > 1 and self.length(cur[:cut]) > width:
                        cut -= 1
                    out.append(cur[:cut])
                    cur = cur[cut:]
            if cur.strip() or not out:
                out.append(cur.rstrip())
        return out

    def fit(self, text, width):
        if self.length(text) <= width:
            return text
        while text and self.length(text + "\u2026") > width:
            text = text[:-1]
        return text + "\u2026"


# --- geo -------------------------------------------------------------------

_A, _EE = 6378245.0, 0.00669342162296594323


def _t_lat(x, y):
    r = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    r += (20 * math.sin(6 * x * math.pi) + 20 * math.sin(2 * x * math.pi)) * 2 / 3
    r += (20 * math.sin(y * math.pi) + 40 * math.sin(y / 3 * math.pi)) * 2 / 3
    r += (160 * math.sin(y / 12 * math.pi) + 320 * math.sin(y * math.pi / 30)) * 2 / 3
    return r


def _t_lon(x, y):
    r = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    r += (20 * math.sin(6 * x * math.pi) + 20 * math.sin(2 * x * math.pi)) * 2 / 3
    r += (20 * math.sin(x * math.pi) + 40 * math.sin(x / 3 * math.pi)) * 2 / 3
    r += (150 * math.sin(x / 12 * math.pi) + 300 * math.sin(x / 30 * math.pi)) * 2 / 3
    return r


def wgs2gcj(lon, lat):
    if not (72.004 <= lon <= 137.8347 and 0.8293 <= lat <= 55.8271):
        return lon, lat
    d_lat, d_lon = _t_lat(lon - 105, lat - 35), _t_lon(lon - 105, lat - 35)
    rl = lat / 180 * math.pi
    m = 1 - _EE * math.sin(rl) ** 2
    sm = math.sqrt(m)
    d_lat = (d_lat * 180) / ((_A * (1 - _EE)) / (m * sm) * math.pi)
    d_lon = (d_lon * 180) / (_A / sm * math.cos(rl) * math.pi)
    return lon + d_lon, lat + d_lat


def world(lon, lat, z):
    n = 256 * 2 ** z
    lat = max(-85.0, min(85.0, lat))
    r = math.radians(lat)
    return (lon + 180) / 360 * n, (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n


def fetch_tile(cache, x, y, z, labels):
    path = cache / str(z) / str(x) / f"{y}{'' if labels else '-n'}.png"
    if path.exists() and path.stat().st_size > 0:
        try:
            return Image.open(path).convert("RGB")
        except OSError:
            path.unlink()
    url = TILE_URL.format(x=x, y=y, z=z) + ("" if labels else "&nolabels=1")
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "aarc-broll-render"})
            with urllib.request.urlopen(req, timeout=8) as r:
                data = r.read()
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            return Image.open(path).convert("RGB")
        except Exception:
            time.sleep(0.5 * (attempt + 1))
    return None


def night(tile):
    """Light AutoNavi style turned into a dark map: invert lightness, keep hue."""
    inv = Image.eval(tile, lambda v: 255 - v)
    h, s, v = inv.convert("HSV").split()
    h = h.point(lambda p: (p + 128) % 256)
    s = s.point(lambda p: int(p * 0.35))
    v = v.point(lambda p: int(16 + p * 0.9))
    return Image.merge("HSV", (h, s, v)).convert("RGB")


def grid(w, h, step):
    # Same tone as an empty night tile, so a missing tile reads as plain ground.
    land = night(Image.new("RGB", (1, 1), (238, 236, 231))).getpixel((0, 0))
    img = Image.new("RGB", (w, h), land)
    d = ImageDraw.Draw(img)
    line = tuple(min(255, c + 9) for c in land)
    for x in range(0, w, step):
        d.line([(x, 0), (x, h)], fill=line, width=1)
    for y in range(0, h, step):
        d.line([(0, y), (w, y)], fill=line, width=1)
    return img


# --- capture ---------------------------------------------------------------

def ms_of(iso):
    return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)


def load(capture):
    manifest = json.loads((capture / "manifest.json").read_text())
    if manifest.get("format") != "aarc-broll/1":
        sys.exit(f"unknown capture format {manifest.get('format')}")
    recs = []
    with (capture / "timeline.jsonl").open() as fh:
        for line in fh:
            line = line.strip()
            if line:
                recs.append(json.loads(line))
    recs.sort(key=lambda r: r["ms"])
    return manifest, recs


class Series:
    """Last-known and linearly interpolated values of one field over time."""

    def __init__(self, recs, field):
        pts = [(r["ms"], r[field]) for r in recs if r.get(field) is not None]
        self.ms = [p[0] for p in pts]
        self.v = [p[1] for p in pts]

    def last(self, ms):
        i = bisect.bisect_right(self.ms, ms) - 1
        return self.v[i] if i >= 0 else None

    def lerp(self, ms):
        i = bisect.bisect_right(self.ms, ms) - 1
        if i < 0:
            return None
        if i + 1 >= len(self.ms):
            return self.v[i]
        a, b = self.ms[i], self.ms[i + 1]
        f = (ms - a) / (b - a) if b > a else 0
        return self.v[i] + (self.v[i + 1] - self.v[i]) * f


# --- renderer --------------------------------------------------------------

TERM_BG = (24, 24, 27)
TERM_BAND = (48, 49, 56)
TERM_HEAD = (36, 37, 42)
T_TEXT = (228, 228, 231)
T_DIM = (138, 138, 148)
T_FAINT = (100, 100, 110)
T_GREEN = (86, 196, 120)
T_RED = (232, 100, 100)
T_CORAL = (215, 119, 87)
T_RESULT = (172, 172, 182)
SPIN = "\u00b7\u2722\u2733\u2736\u273b\u2736\u2733\u2722"


def strip_md(text):
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"^#+\s*", "", text, flags=re.M)
    return plain_keep_lines(text)


def plain_keep_lines(text):
    text = re.sub(r"[ \t]*(\u2014|\u2013)[ \t]*", ", ", text or "")
    return "".join(c for c in text if ord(c) <= 0xFFFF)


class Renderer:
    def __init__(self, capture, manifest, recs, W, H, labels, rate, music=()):
        self.capture, self.W, self.H, self.rate = capture, W, H, rate
        self.music = list(music)
        k = self.k = H / 1080
        self.start_ms = ms_of(manifest["startedAt"])
        self.gate_ms = ms_of(manifest["gateAt"]) if manifest.get("gateAt") else None
        self.run_date = datetime.fromtimestamp(self.start_ms / 1000, BEIJING).strftime("%-d %b %Y").upper()

        # Left: the agent's terminal. Right: the AARC view, stacked.
        self.term_w = round(W * 0.6)
        self.col_x = self.term_w
        self.col_w = W - self.term_w
        self.pad = round(26 * k)
        self.stats_h = round(236 * k)
        self.map_w = self.col_w
        self.map_h = max(round(H * 0.5), round(540 * k))
        self.map_y = self.stats_h
        self.feed_y = self.map_y + self.map_h
        self.feed_h = H - self.feed_y

        self.f_label = Face(round(14 * k), "Semibold")
        self.f_clock = Face(round(76 * k), "Bold")
        self.f_wall = Face(round(34 * k), "Medium")
        self.f_num = Face(round(42 * k), "Semibold")
        self.f_unit = Face(round(18 * k), "Medium")
        self.f_head = Face(round(14 * k), "Bold")
        self.f_time = Face(round(13 * k), "Regular", mono=True)
        self.f_card = Face(round(19 * k), "Regular")
        try:
            self.f_note = ImageFont.truetype(str(FONT_DIR / "Apple Symbols.ttf"), round(22 * k))
        except OSError:
            self.f_note = ImageFont.load_default()
        self.f_chip = Face(round(16 * k), "Semibold")
        self.f_chip_small = Face(round(14 * k), "Regular")
        self.f_km = Face(round(13 * k), "Bold")
        self.f_title = Face(round(15 * k), "Medium")

        self.metrics = [r for r in recs if r["lane"] == "metrics"]
        self.dist = Series(self.metrics, "distanceM")
        self.pace = Series(self.metrics, "paceS")
        self.hr = Series(self.metrics + [r for r in recs if r["lane"] == "pos"], "hr")

        self._cache = {}
        self._setup_map(recs, labels)
        self._setup_feed(recs)
        self._setup_terminal(recs)
        self._setup_chrome()

    # map
    def _setup_map(self, recs, labels):
        k, W, H = self.k, self.map_w, self.map_h
        fixes = []
        for r in recs:
            if r["lane"] == "pos" and r.get("lat") is not None and r.get("lon") is not None:
                if abs(r["lat"]) < 1e-6 and abs(r["lon"]) < 1e-6:
                    continue
                fixes.append((r["ms"], *wgs2gcj(r["lon"], r["lat"])))
        self.fixes = fixes
        pad = 70 * k
        if len(fixes) >= 2:
            w0 = [world(lo, la, 0) for _, lo, la in fixes]
            xs, ys = [p[0] for p in w0], [p[1] for p in w0]
            span_x, span_y = max(max(xs) - min(xs), 1e-9), max(max(ys) - min(ys), 1e-9)
            zf = min(math.log2((W - 2 * pad) / span_x), math.log2((H - 2 * pad - 60 * k) / span_y))
            cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
        elif fixes:
            zf, (cx, cy) = 16.0, world(fixes[0][1], fixes[0][2], 0)
        else:
            zf, cx, cy = None, 0, 0

        base = grid(W, H, round(64 * k))
        self.project = lambda lon, lat: (W / 2, H / 2)
        self.tiles_ok = self.tiles_total = 0
        if zf is not None:
            zf = max(3.0, min(19.0, zf))
            zt = min(19, math.ceil(zf - 1e-9))
            s = 2 ** (zf - zt)
            ox = cx * 2 ** zt - W / s / 2
            oy = cy * 2 ** zt - (H / s) / 2 + 30 * k / s
            self.project = lambda lon, lat, zt=zt, s=s, ox=ox, oy=oy: (
                (world(lon, lat, zt)[0] - ox) * s, (world(lon, lat, zt)[1] - oy) * s)
            bw, bh = math.ceil(W / s), math.ceil(H / s)
            tx0, ty0 = int(ox // 256), int(oy // 256)
            tx1, ty1 = int((ox + bw) // 256), int((oy + bh) // 256)
            coords = [(x, y) for x in range(tx0, tx1 + 1) for y in range(ty0, ty1 + 1)]
            cache = self.capture / "tiles"
            with ThreadPoolExecutor(4) as pool:
                got = list(pool.map(lambda c: fetch_tile(cache, c[0], c[1], zt, labels), coords))
            # AutoNavi drops tiles under load now and then; one calm pass picks most of them up.
            got = [g if g is not None else fetch_tile(cache, x, y, zt, labels) for (x, y), g in zip(coords, got)]
            self.tiles_total = len(coords)
            self.tiles_ok = sum(1 for g in got if g is not None)
            if self.tiles_ok:
                big = grid(bw, bh, round(64 * k / s))
                for (x, y), img in zip(coords, got):
                    if img is not None:
                        big.paste(night(img.resize((256, 256))), (round(x * 256 - ox), round(y * 256 - oy)))
                base = big.resize((W, H), Image.LANCZOS)
            self.zoom = zf

        # Vignette so the trail and the chip read over busy tiles.
        shade = Image.new("L", (W, H), 0)
        sd = ImageDraw.Draw(shade)
        for i in range(40):
            a = int(120 * (1 - i / 40) ** 2)
            sd.rectangle([i * 3 * k, i * 3 * k, W - i * 3 * k, H - i * 3 * k], outline=a, width=max(1, round(3 * k)))
        base.paste(BG, (0, 0, W, H), shade)

        self.pts = [self.project(lo, la) for _, lo, la in fixes]
        self.fix_ms = [f[0] for f in fixes]
        self.trail_w = max(3, round(6 * k))

        # Ghost of the whole route, faint, so the viewer sees the shape ahead.
        if len(self.pts) >= 2:
            ghost = Image.new("RGBA", (W * 2, H * 2), (0, 0, 0, 0))
            gd = ImageDraw.Draw(ghost)
            gd.line([(x * 2, y * 2) for x, y in self.pts], fill=GHOST + (60,), width=self.trail_w * 2 - 2, joint="curve")
            ghost = ghost.reduce(2)
            base.paste(ghost.convert("RGB"), (0, 0), ghost.split()[3])
        ad = ImageDraw.Draw(base)
        if self.tiles_ok:
            txt = "Map \u00a9 AutoNavi"
            self.f_chip_small.draw(ad, W - self.f_chip_small.length(txt) - 14 * k, H - 14 * k, txt, (110, 118, 132))
        elif not fixes:
            txt = "NO GPS IN THIS CAPTURE"
            self.f_chip.draw(ad, (W - self.f_chip.length(txt)) / 2, H / 2, txt, MUTED)
        self.map_base = base
        self.trail = Image.new("RGBA", (W * 2, H * 2), (0, 0, 0, 0))
        self.trail_draw = ImageDraw.Draw(self.trail)
        self.markers = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        self.committed = 0
        self.km_done = 0
        self.map_now = base.copy()

        # Kilometre crossings from the distance series.
        self.km_ms = []
        prev_ms = prev_d = None
        for ms, d in zip(self.dist.ms, self.dist.v):
            if prev_d is not None:
                while math.floor(d / 1000) > math.floor(prev_d / 1000) and len(self.km_ms) < math.floor(d / 1000):
                    km = len(self.km_ms) + 1
                    f = (km * 1000 - prev_d) / (d - prev_d) if d > prev_d else 1
                    self.km_ms.append(prev_ms + (ms - prev_ms) * f)
            prev_ms, prev_d = ms, d

        r = round(13 * k)
        dot = Image.new("RGBA", (r * 8, r * 8), (0, 0, 0, 0))
        dd = ImageDraw.Draw(dot)
        c = r * 4
        for i in range(12, 0, -1):
            rr = r * 2 * (1 + i / 6)
            dd.ellipse([c - rr, c - rr, c + rr, c + rr], fill=TRAIL + (int(10 * (12 - i) / 12) + 2,))
        dd.ellipse([c - r * 2, c - r * 2, c + r * 2, c + r * 2], fill=(255, 255, 255, 255))
        dd.ellipse([c - r * 1.35, c - r * 1.35, c + r * 1.35, c + r * 1.35], fill=TRAIL + (255,))
        self.dot = dot.reduce(2)

    def _pos_at(self, ms):
        i = bisect.bisect_right(self.fix_ms, ms) - 1
        if i < 0:
            return None, -1
        if i + 1 >= len(self.pts):
            return self.pts[i], i
        a, b = self.fix_ms[i], self.fix_ms[i + 1]
        f = (ms - a) / (b - a) if b > a else 0
        (x0, y0), (x1, y1) = self.pts[i], self.pts[i + 1]
        return (x0 + (x1 - x0) * f, y0 + (y1 - y0) * f), i

    def _map_frame(self, ms):
        pos, i = self._pos_at(ms)
        changed = False
        while self.committed < i:
            a, b = self.pts[self.committed], self.pts[self.committed + 1]
            self.trail_draw.line([(a[0] * 2, a[1] * 2), (b[0] * 2, b[1] * 2)], fill=TRAIL + (255,), width=self.trail_w * 2)
            rr = self.trail_w
            self.trail_draw.ellipse([b[0] * 2 - rr, b[1] * 2 - rr, b[0] * 2 + rr, b[1] * 2 + rr], fill=TRAIL + (255,))
            self.committed += 1
            changed = True
        while self.km_done < len(self.km_ms) and self.km_ms[self.km_done] <= ms:
            p, _ = self._pos_at(self.km_ms[self.km_done])
            self.km_done += 1
            if p:
                self._km_marker(p, self.km_done)
                changed = True
        if changed:
            img = self.map_base.copy()
            t = self.trail.reduce(2)
            img.paste(t.convert("RGB"), (0, 0), t.split()[3])
            img.paste(self.markers.convert("RGB"), (0, 0), self.markers.split()[3])
            self.map_now = img
        img = self.map_now.copy()
        if pos is not None:
            if i >= 0 and self.committed == i:
                a = self.pts[i]
                ImageDraw.Draw(img).line([a, pos], fill=TRAIL, width=self.trail_w)
            d = self.dot
            img.paste(d, (round(pos[0] - d.width / 2), round(pos[1] - d.height / 2)), d)
        return img

    def _km_marker(self, p, km):
        k = self.k
        md = ImageDraw.Draw(self.markers)
        r = 13 * k
        md.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=(12, 15, 22, 235), outline=TRAIL + (255,), width=max(2, round(2 * k)))
        s = str(km)
        self.f_km.draw(md, p[0] - self.f_km.length(s) / 2, p[1] + 5 * k, s, TEXT)

    # terminal
    def _setup_terminal(self, recs):
        k = self.k
        self.mono = MonoFace(round(17 * k))
        self.mono_b = MonoFace(round(17 * k), "Bold")
        self.lh = round(25 * k)
        self.tx = round(22 * k)
        self.head_h = round(42 * k)
        self.input_h = round(92 * k)
        self.view_y = self.head_h + round(10 * k)
        self.view_h = self.H - self.view_y - self.input_h
        inner = self.term_w - 2 * self.tx
        two = self.mono.length("  ")
        four = self.mono.length("    ")
        five = self.mono.length("  \u23bf  ")

        terms = [r for r in recs if r["lane"] == "terminal"]
        if not terms:
            # Captures made before the terminal lane: fall back to the short console lane.
            for r in recs:
                if r["lane"] == "console" and r.get("text"):
                    if r.get("kind") == "tool":
                        name, _, desc = r["text"].partition(": ")
                        terms.append({"ms": r["ms"], "kind": "tool", "name": name, "description": desc, "text": ""})
                    else:
                        terms.append({"ms": r["ms"], "kind": "assistant", "text": r["text"]})
        self.thinks = sorted((r["ms"], r["ms"] + (r.get("durationS") or 1) * 1000)
                             for r in terms if r.get("kind") == "thinking")
        self.think_ms = [t[0] for t in self.thinks]

        # Every line of the session, in order. A line is (segments, indent_px, band, chars),
        # where chars > 0 marks a typed (assistant) line that reveals over time.
        lines, entries = [], []
        prev_kind = None
        last_end = 0
        for r in sorted((r for r in terms if r.get("kind") != "thinking"), key=lambda r: r["ms"]):
            kind = r.get("kind")
            text = r.get("text") or ""
            block = []
            if kind == "user":
                body = self.mono.wrap(plain_keep_lines(text), inner - two)
                for n, l in enumerate(body):
                    block.append(([("> " if n == 0 else "  ", T_DIM), (l, T_TEXT)], 0, TERM_BAND, 0))
            elif kind == "assistant":
                body = self.mono.wrap(strip_md(text), inner - two)
                for n, l in enumerate(body[:40]):
                    block.append(([("\u25cf " if n == 0 else "  ", T_TEXT), (l, T_TEXT)], 0, None, max(1, len(l))))
            elif kind == "tool":
                name = r.get("name") or "Tool"
                desc = plain(r.get("description") or "")
                head = self.mono.fit(f"{name}({desc})" if desc else name, inner - two)
                nm = head[:len(name)]
                block.append(([("\u25cf ", T_GREEN), (nm, T_TEXT), (head[len(nm):], T_DIM)], 0, None, 0))
                body = self.mono.wrap(plain_keep_lines(text), inner - four) if text else []
                for l in body[:6]:
                    block.append(([(l, T_FAINT)], four, None, 0))
                if len(body) > 6:
                    block.append(([(f"\u2026 +{len(body) - 6} lines", T_FAINT)], four, None, 0))
            elif kind == "result":
                col = T_RED if r.get("isError") else T_RESULT
                raw = [l for l in plain_keep_lines(text).split("\n")]
                while raw and not raw[-1].strip():
                    raw.pop()
                total = max(r.get("lines") or 0, len(raw))
                shown = raw[:4] or ["(No content)"]
                for n, l in enumerate(shown):
                    pre = "  \u23bf  " if n == 0 else "     "
                    block.append(([(pre, T_FAINT), (self.mono.fit(l.replace("\t", "  "), inner - five), col)], 0, None, 0))
                if total > len(shown):
                    block.append(([("     ", T_FAINT), (f"\u2026 +{total - len(shown)} lines", T_FAINT)], 0, None, 0))
            elif kind == "harness":
                t = plain(text)
                t = t if t.startswith("[") else f"[{t}]"
                body = self.mono.wrap(t, inner - two)
                for l in body[:4]:
                    block.append(([("  ", T_FAINT), (l, T_FAINT)], 0, None, 0))
            else:
                continue
            if not block:
                continue
            gap = kind in ("user", "assistant", "tool") or (kind == "harness" and prev_kind not in ("harness", None))
            if gap and lines:
                block.insert(0, ([], 0, None, 0))
            typed = sum(l[3] for l in block)
            rate = max(70.0, typed / 2.6) if typed else 0
            start = max(r["ms"], last_end)
            dur = (typed / rate * 1000) if typed else 0
            entries.append({"ms": start, "first": len(lines), "count": len(block), "rate": rate})
            lines.extend(block)
            last_end = start + dur
            prev_kind = kind
        self.tlines = lines
        self.entries = entries
        self.entry_ms = [e["ms"] for e in entries]
        self.scroll = None
        self._line_cache = {}
        self._pane_key = None
        self._pane = None

    def _revealed(self, ms):
        """(full lines shown, index of a partly typed line or -1, chars shown on it)."""
        i = bisect.bisect_right(self.entry_ms, ms) - 1
        if i < 0:
            return 0, -1, 0
        e = self.entries[i]
        if not e["rate"]:
            return e["first"] + e["count"], -1, 0
        budget = (ms - e["ms"]) / 1000 * e["rate"]
        n = e["first"]
        for j in range(e["first"], e["first"] + e["count"]):
            c = self.tlines[j][3]
            if c == 0 or budget >= c:
                budget -= c
                n += 1
                continue
            return n, j, int(budget)
        return n, -1, 0

    def _line_img(self, j, chars=None):
        key = (j, chars)
        img = self._line_cache.get(key)
        if img is not None:
            return img
        segs, indent, band, _ = self.tlines[j]
        img = Image.new("RGB", (self.term_w, self.lh), band or TERM_BG)
        d = ImageDraw.Draw(img)
        x = self.tx + indent
        base = round(self.lh * 0.74)
        left = chars
        for n, (text, col) in enumerate(segs):
            if chars is not None and n == len(segs) - 1:
                text = text[:left]
            face = self.mono_b if (col == T_TEXT and n == 1 and segs[0][1] == T_GREEN) else self.mono
            x = face.draw(d, x, base, text, col)
        if chars is not None:
            d.rectangle([x + 1, round(3 * self.k), x + round(9 * self.k), self.lh - round(4 * self.k)], fill=(200, 200, 205))
        if len(self._line_cache) > 6000:
            self._line_cache.clear()
        self._line_cache[key] = img
        return img

    def _thinking(self, ms):
        i = bisect.bisect_right(self.think_ms, ms) - 1
        while i >= 0 and self.thinks[i][0] > ms - 120000:
            if self.thinks[i][1] > ms:
                return self.thinks[i][0]
            i -= 1
        return None

    def _terminal(self, ms):
        k = self.k
        n, partial, chars = self._revealed(ms)
        think = self._thinking(ms)
        rows = n + (1 if partial >= 0 else 0) + (2 if think is not None else 0)
        target = max(0.0, rows * self.lh - self.view_h + round(8 * k))
        if self.scroll is None:
            self.scroll = target
        else:
            self.scroll += (target - self.scroll) * (1 - math.exp(-(1 / self.rate) / 0.12))
            if abs(target - self.scroll) < 0.5:
                self.scroll = target
        spin = None
        if think is not None:
            el = (ms - think) / 1000
            spin = (SPIN[int(el * 8) % len(SPIN)], int(el))
        sc = round(self.scroll)
        key = (n, partial, chars, sc, spin)
        if key == self._pane_key:
            return self._pane
        pane = Image.new("RGB", (self.term_w, self.view_h), TERM_BG)
        first = max(0, sc // self.lh)
        last_row = min(rows, (sc + self.view_h) // self.lh + 1)
        for row in range(first, last_row):
            y = row * self.lh - sc
            if row < n:
                pane.paste(self._line_img(row), (0, y))
            elif row == n and partial >= 0:
                pane.paste(self._line_img(partial, chars), (0, y))
            elif spin is not None and row == rows - 1:
                d = ImageDraw.Draw(pane)
                text = f"{spin[0]} Thinking\u2026 ({spin[1]}s \u00b7 esc to interrupt)"
                self.mono.draw(d, self.tx, y + round(self.lh * 0.74), text, T_CORAL)
        self._pane_key, self._pane = key, pane
        return pane

    def _term_chrome(self, ms):
        """Title bar and the input box; only the clock changes, once a second."""
        k = self.k
        wall = datetime.fromtimestamp(ms / 1000, BEIJING).strftime("%H:%M:%S")
        key = ("tchrome", wall)
        hit = self._cache.get(key)
        if hit:
            return hit
        img = Image.new("RGB", (self.term_w, self.H), TERM_BG)
        d = ImageDraw.Draw(img)
        d.rectangle([0, 0, self.term_w, self.head_h], fill=TERM_HEAD)
        d.line([(0, self.head_h), (self.term_w, self.head_h)], fill=(56, 57, 64), width=1)
        r = round(6 * k)
        for n, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            cx, cy = round(24 * k) + n * round(20 * k), self.head_h // 2
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)
        title = "claude \u00b7 ~/Dev/ccplayground/aarc \u00b7 Opus 5.5"
        base = self.head_h // 2 + round(5 * k)
        self.f_title.draw(d, (self.term_w - self.f_title.length(title)) / 2, base, title, (196, 196, 204))
        clock = f"Beijing {wall}"
        self.mono.draw(d, self.term_w - round(20 * k) - self.mono.length(clock), base, clock, (196, 196, 204))
        y0 = self.H - self.input_h + round(10 * k)
        y1 = y0 + round(46 * k)
        d.rounded_rectangle([self.tx - round(6 * k), y0, self.term_w - self.tx + round(6 * k), y1],
                            radius=round(8 * k), outline=(86, 87, 96), width=max(1, round(1.5 * k)))
        self.mono.draw(d, self.tx + round(8 * k), y0 + round(30 * k), ">", T_DIM)
        self.mono.draw(d, self.tx + round(8 * k), y1 + round(24 * k),
                       "\u25b8\u25b8 bypass permissions on \u00b7 live run watcher armed", T_FAINT)
        if len(self._cache) > 600:
            self._cache.clear()
        self._cache[key] = img
        return img

    # AARC message feed, under the map
    def _setup_feed(self, recs):
        k = self.k
        talk_texts = {plain(r["text"])[:60] for r in recs if r["lane"] == "talkback" and r.get("text")}
        items, screen_by_text = [], {}
        for r in recs:
            lane = r["lane"]
            if lane == "talkback" and r.get("text"):
                dur = r.get("durationS") or min(30.0, max(3.0, len(r["text"]) / 15))
                items.append({"ms": r["ms"], "end": r["ms"] + dur * 1000, "label": RUNNER[0] + "  \u00b7  TALK-BACK",
                              "color": RUNNER[1], "text": plain(r["text"])})
            elif lane == "screen" and r.get("text"):
                txt = plain(r["text"])
                if r.get("role") == "user":
                    if txt[:60] in talk_texts:
                        continue
                    label, color = RUNNER
                else:
                    label, color = CONTROL
                items.append({"ms": r["ms"], "end": r["ms"], "label": label, "color": color, "text": txt})
                screen_by_text[clean_speech(txt)[:60]] = len(items) - 1
            elif lane == "voice" and r.get("text"):
                txt = clean_speech(r["text"])
                if not txt:
                    continue
                dur = r.get("durationS") or min(20.0, max(2.0, len(txt) / 15))
                prior = screen_by_text.get(txt[:60])
                if prior is not None and items[prior]["ms"] <= r["ms"]:
                    # Control Room text spoken aloud: light up its card instead of repeating it.
                    items[prior].setdefault("plays", []).append((r["ms"], r["ms"] + dur * 1000))
                    continue
                label, color = SPEAKERS.get(r.get("speaker"), (str(r.get("speaker", "VOICE")).upper(), MUTED))
                items.append({"ms": r["ms"], "end": r["ms"] + dur * 1000, "label": label, "color": color,
                              "text": txt, "voice": True})
            elif lane == "event" and r.get("detail"):
                typ = str(r.get("type", ""))
                if typ.startswith("race."):
                    items.append({"ms": r["ms"], "end": r["ms"], "label": RACE[0], "color": RACE[1],
                                  "text": plain(r["detail"]).capitalize()})
                elif typ in ("camera.say", "camera.link", "camera.gate"):
                    items.append({"ms": r["ms"], "end": r["ms"], "label": "CAMERA", "color": (150, 160, 255),
                                  "text": plain(r["detail"]).capitalize()})
        for n, km_ms in enumerate(self.km_ms):
            items.append({"ms": km_ms, "end": km_ms, "label": RACE[0], "color": RACE[1],
                          "text": f"Kilometre {n + 1}"})
        for it in items:
            plays = it.get("plays") or []
            if it["end"] > it["ms"]:
                plays.append((it["ms"], it["end"]))
            it["plays"] = sorted(plays)
        self.items = sorted(items, key=lambda it: it["ms"])
        self.item_ms = [it["ms"] for it in self.items]
        self.plays = sorted((a, b, i) for i, it in enumerate(self.items) for a, b in it["plays"])
        self.play_ms = [p[0] for p in self.plays]

        inner = self.col_w - 2 * self.pad - round(44 * k)
        self.card_lh = round(26 * k)
        self.card_head = round(46 * k)
        self.card_pad = round(16 * k)
        self.max_hot = max(1, (self.feed_h - self.card_head - self.card_pad - round(24 * k)) // self.card_lh)
        for it in self.items:
            full = self.f_card.wrap(it["text"], inner)
            it["full"] = full
            it["short"] = self.f_card.wrap(it["text"], inner, max_lines=3)
            it["clock"] = datetime.fromtimestamp(it["ms"] / 1000, BEIJING).strftime("%H:%M:%S")

    def _playing(self, ms):
        i = bisect.bisect_right(self.play_ms, ms) - 1
        while i >= 0 and self.plays[i][0] > ms - 120000:
            a, b, idx = self.plays[i]
            if b > ms:
                return idx, a, b
            i -= 1
        return None, None, None

    def _card_h(self, nlines):
        return self.card_head + nlines * self.card_lh + self.card_pad - round(8 * self.k)

    def _feed(self, ms):
        last = bisect.bisect_right(self.item_ms, ms) - 1
        hot, a, b = self._playing(ms)
        k, w, h = self.k, self.col_w, self.feed_h
        gap = round(10 * k)
        avail = h - round(12 * k)
        squeeze, hot_max, page = False, self.max_hot, 0
        if hot is not None and hot <= last:
            # The card being spoken must show whole: newer cards shrink to one line if needed.
            newer = range(hot + 1, last + 1)
            used = sum(self._card_h(len(self.items[j]["short"])) + gap for j in newer)
            if used + self._card_h(min(len(self.items[hot]["full"]), self.max_hot)) > avail:
                squeeze = True
                used = sum(self._card_h(1) + gap for j in newer)
            hot_max = max(1, min(self.max_hot, (avail - used - self._card_h(0)) // self.card_lh))
            full = self.items[hot]["full"]
            pages = max(1, math.ceil(len(full) / hot_max))
            if pages > 1:
                page = min(pages - 1, int((ms - a) / max(1, b - a) * pages))
        key = ("feed", last, hot, page, squeeze, hot_max)
        if key in self._cache:
            return self._cache[key]
        img = Image.new("RGB", (w, h), PANEL)
        d = ImageDraw.Draw(img)
        x0, x1 = self.pad, w - self.pad
        y = h - round(12 * k)
        i = last
        while i >= 0 and y > 0:
            it = self.items[i]
            is_hot = i == hot
            if is_hot:
                lines = it["full"][page * hot_max:(page + 1) * hot_max]
            elif squeeze and hot is not None and i > hot:
                lines = [self.f_card.fit(" ".join(it["short"]), self.col_w - 2 * self.pad - round(44 * k))]
            else:
                lines = it["short"]
            ch = self._card_h(len(lines))
            top = y - ch
            d.rounded_rectangle([x0, top, x1, y], radius=round(10 * k), fill=CARD_HOT if is_hot else CARD)
            d.rounded_rectangle([x0, top, x0 + round(5 * k), y], radius=round(3 * k), fill=it["color"])
            tx = x0 + round(20 * k)
            hx = self.f_head.draw(d, tx, top + round(28 * k), it["label"], it["color"])
            if is_hot:
                cx, cy = hx + round(12 * k), top + round(23 * k)
                s = round(6 * k)
                d.polygon([(cx, cy - s), (cx, cy + s), (cx + s * 1.6, cy)], fill=it["color"])
            self.f_time.draw(d, x1 - round(14 * k) - self.f_time.length(it["clock"]), top + round(28 * k), it["clock"], DIM)
            by = top + self.card_head + round(8 * k)
            body = TEXT if (is_hot or not it.get("voice")) else (200, 206, 218)
            for line in lines:
                self.f_card.draw(d, tx, by, line, body)
                by += self.card_lh
            y = top - gap
            i -= 1
        fade = Image.linear_gradient("L").resize((w, round(22 * k))).transpose(Image.FLIP_TOP_BOTTOM)
        img.paste(PANEL, (0, 0, w, fade.height), fade)
        if len(self._cache) > 600:
            self._cache.clear()
        self._cache[key] = img
        return img

    # stats + chrome
    def _setup_chrome(self):
        k = self.k
        img = Image.new("RGB", (self.W, self.H), PANEL)
        d = ImageDraw.Draw(img)
        d.line([(self.col_x, 0), (self.col_x, self.H)], fill=RULE, width=max(1, round(2 * k)))
        self.chrome = img

    def _stats(self, ms):
        k = self.k
        if self.gate_ms is not None:
            el = (ms - self.gate_ms) / 1000
            label = "RACE CLOCK" if el >= 0 else "TO THE GATE"
        else:
            el = (ms - self.start_ms) / 1000
            label = "RUN CLOCK"
        sign = "-" if el < 0 else ""
        e = int(abs(el)) if el >= 0 else int(math.ceil(abs(el)))
        clock = f"{sign}{e // 3600}:{e % 3600 // 60:02d}:{e % 60:02d}"
        wall = datetime.fromtimestamp(ms / 1000, BEIJING).strftime("%H:%M:%S")
        dm = self.dist.lerp(ms)
        dist = f"{dm / 1000:.2f}" if dm is not None else "0.00"
        p = self.pace.last(ms)
        pace = f"{int(p) // 60}:{int(p) % 60:02d}" if p and 120 <= p <= 1200 else "--:--"
        hr = self.hr.last(ms)
        hr = f"{int(round(hr))}" if hr else "--"
        key = ("stats", label, clock, wall, dist, pace, hr)
        if key in self._cache:
            return self._cache[key]
        w, h = self.col_w, self.stats_h
        img = Image.new("RGB", (w, h), PANEL)
        d = ImageDraw.Draw(img)
        x0, x1 = self.pad, w - self.pad
        self.f_label.draw(d, x0, round(36 * k), label, MUTED)
        self.f_clock.draw(d, x0 - round(3 * k), round(110 * k), clock, TEXT)
        self.f_label.draw(d, x1 - self.f_label.length("BEIJING"), round(36 * k), "BEIJING", MUTED)
        self.f_wall.draw(d, x1 - self.f_wall.length(wall), round(84 * k), wall, (196, 204, 216))
        d.line([(x0, round(134 * k)), (x1, round(134 * k))], fill=RULE, width=max(1, round(2 * k)))
        cols = [("DISTANCE", dist, "km"), ("PACE", pace, "/km"), ("HEART RATE", hr, "bpm")]
        cw = (x1 - x0) / 3
        for n, (lab, val, unit) in enumerate(cols):
            cx = x0 + n * cw
            self.f_label.draw(d, cx, round(166 * k), lab, MUTED)
            vx = self.f_num.draw(d, cx, round(214 * k), val, TEXT if n != 2 else (255, 120, 120))
            self.f_unit.draw(d, vx + round(6 * k), round(214 * k), unit, MUTED)
        self._cache[key] = img
        return img

    def _chip(self, ms):
        key = ("chip",)
        if key in self._cache:
            return self._cache[key]
        k = self.k
        title = "AARC  \u00b7  " + self.run_date
        w = round(self.f_chip.length(title) + 54 * k)
        h = round(44 * k)
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=round(10 * k), fill=(8, 11, 16, 215), outline=RULE + (255,))
        d.ellipse([round(18 * k), round(17 * k), round(27 * k), round(26 * k)], fill=TRAIL + (255,))
        self.f_chip.draw(d, round(36 * k), round(28 * k), title, TEXT)
        self._cache[key] = img
        return img

    def _music_chip(self, ms):
        t = (ms - self.start_ms) / 1000
        seg = None
        for s in self.music:
            if s["t0"] <= t < s["t1"] - s["fade_out"] * 0.5:
                seg = s
        if seg is None:
            return None
        key = ("music", seg["title"], seg["artist"])
        if key in self._cache:
            return self._cache[key]
        k = self.k
        text = f"{seg['title']}  \u00b7  {seg['artist']}"
        w = round(self.f_chip_small.length(text) + 58 * k)
        h = round(36 * k)
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=round(18 * k), fill=(8, 11, 16, 220), outline=RULE + (255,))
        d.text((round(16 * k), round(25 * k)), "\u266a", font=self.f_note, fill=(255, 178, 54), anchor="ls")
        self.f_chip_small.draw(d, round(40 * k), round(24 * k), text, (214, 220, 230))
        self._cache[key] = img
        return img

    def frame(self, ms):
        img = self.chrome.copy()
        img.paste(self._term_chrome(ms), (0, 0))
        img.paste(self._terminal(ms), (0, self.view_y))
        m = self._map_frame(ms)
        chip = self._chip(ms)
        m.paste(chip, (round(16 * self.k), round(16 * self.k)), chip)
        mc = self._music_chip(ms)
        if mc is not None:
            m.paste(mc, (round(16 * self.k), self.map_h - mc.height - round(14 * self.k)), mc)
        x = self.col_x + 1
        img.paste(self._stats(ms), (x, 0))
        img.paste(m, (x, self.map_y))
        img.paste(self._feed(ms), (x, self.feed_y))
        return img


# --- audio -----------------------------------------------------------------

AFMT = "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo"
AUDIO_EXT = (".mp3", ".m4a", ".wav", ".aac", ".flac", ".ogg")


def ff_mix(items, dest, dur, level=0):
    """Mix [(input args, filter chain)] into one WAV of exactly `dur` seconds, 40 inputs at a time."""
    tail = f"apad=whole_dur={dur:.3f},atrim=0:{dur:.3f}"
    if not items:
        subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                        "-t", f"{dur:.3f}", "-c:a", "pcm_s16le", str(dest)], check=True)
        return dest
    parts = []
    for b in range(0, len(items), 40):
        batch = items[b:b + 40]
        args, chains, labels = [FFMPEG, "-y", "-loglevel", "error"], [], []
        for n, (inp, chain) in enumerate(batch):
            args += inp
            chains.append(f"[{n}:a]{chain}[a{n}]")
            labels.append(f"[a{n}]")
        mix = (f"{labels[0]}{tail}[out]" if len(batch) == 1 else
               f"{''.join(labels)}amix=inputs={len(batch)}:normalize=0:duration=longest:dropout_transition=0,{tail}[out]")
        part = dest.with_name(f"{dest.stem}-L{level}-{b // 40}.wav")  # per level: a pass must not overwrite its inputs
        args += ["-filter_complex", ";".join(chains) + ";" + mix, "-map", "[out]", "-ar", "48000",
                 "-c:a", "pcm_s16le", str(part)]
        subprocess.run(args, check=True)
        parts.append(part)
    if len(parts) == 1:
        parts[0].rename(dest)
        return dest
    return ff_mix([(["-i", str(p)], AFMT) for p in parts], dest, dur, level + 1)


def voice_lines(recs, capture):
    """Voice lines as heard: (start ms, path or None, seconds). His talk-backs stay out: the camera has them."""
    out = []
    for r in recs:
        if r["lane"] != "voice":
            continue
        p = capture / r["audio"] if r.get("audio") else None
        if p is not None and not p.exists():
            p = None
        dur = r.get("durationS") or (min(20.0, max(2.0, len(clean_speech(r.get("text") or "")) / 15)))
        out.append((r["ms"], p, dur))
    return out


def load_playlist(music_dir):
    """Tracks in file-name order; title, artist and licence from CREDITS.txt blocks when present."""
    files = sorted(p for p in music_dir.iterdir() if p.suffix.lower() in AUDIO_EXT and not p.name.startswith("."))
    meta, cur = {}, None
    credits = music_dir / "CREDITS.txt"
    if credits.exists():
        for line in credits.read_text().splitlines():
            if line and not line[0].isspace() and line.strip().lower().endswith(AUDIO_EXT):
                cur = meta.setdefault(line.strip(), {})
            elif cur is not None and ":" in line and line[:1].isspace():
                key, _, val = line.strip().partition(":")
                cur[key.strip().lower()] = val.strip()
    tracks = []
    for p in files:
        m = meta.get(p.name, {})
        r = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(p)],
                           capture_output=True, text=True)
        try:
            length = float(r.stdout.strip())
        except ValueError:
            continue
        tracks.append({"path": p, "length": length, "title": m.get("title") or p.stem,
                       "artist": m.get("artist") or "", "attribution": m.get("attribution") or "",
                       "gain": track_gain(p, music_dir)})
    return tracks


def track_gain(path, music_dir, target=-27.0):
    """dB that brings a track's mean level to the bed level; measured once, cached beside it."""
    cache = music_dir / ".levels.json"
    try:
        levels = json.loads(cache.read_text())
    except (OSError, ValueError):
        levels = {}
    key = f"{path.name}:{path.stat().st_size}"
    if key not in levels:
        r = subprocess.run([FFMPEG, "-hide_banner", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
                           capture_output=True, text=True)
        m = re.search(r"mean_volume: (-?[\d.]+) dB", r.stderr)
        levels[key] = float(m.group(1)) if m else target
        try:
            cache.write_text(json.dumps(levels, indent=1))
        except OSError:
            pass
    return target - levels[key]


def music_schedule(recs, start_ms, end_ms, tracks):
    """Bed segments in run seconds. Songs change where his real music changed; pauses fade out."""
    if not tracks:
        return []
    run_end = (end_ms - start_ms) / 1000
    events = [((r["ms"] - start_ms) / 1000, r.get("detail") or "") for r in recs
              if r["lane"] == "event" and r.get("type") == "music.track"]
    segs, open_seg, nxt, paused_at = [], None, 0, None

    def close(t, fade):
        nonlocal open_seg
        if open_seg:
            open_seg["t1"] = max(open_seg["t0"] + 0.5, t + fade)
            open_seg["fade_out"] = fade
            segs.append(open_seg)
            open_seg = None

    def start(t, idx, src, fade):
        nonlocal open_seg
        tr = tracks[idx]
        open_seg = {"idx": idx, "t0": t, "src": src % tr["length"], "fade_in": fade, "fade_out": 2.0,
                    "title": tr["title"], "artist": tr["artist"]}

    if not events:
        t, idx = 0.0, 0
        while t < run_end:
            start(t, idx, 0.0, 2.0 if t else 0.5)
            t2 = t + tracks[idx]["length"] - 2.0
            close(min(t2, run_end), 2.0)
            t, idx = t2, (idx + 1) % len(tracks)
        segs[-1]["t1"] = run_end
        return segs

    for t, detail in sorted(events):
        d = detail.strip().lower()
        if d.startswith("nothing playing"):
            if open_seg:
                paused_at = open_seg["src"] + (t - open_seg["t0"])
                close(t, 2.5)
        elif d.startswith("resumed"):
            if open_seg is None and segs:
                start(t, segs[-1]["idx"], paused_at or 0.0, 1.5)
        else:
            close(t, 2.0)
            start(t, nxt, 0.0, 2.0)
            nxt = (nxt + 1) % len(tracks)
            paused_at = None
    if open_seg:
        open_seg["t1"] = run_end
        open_seg["fade_out"] = min(2.0, max(0.1, run_end - open_seg["t0"]))
        segs.append(open_seg)
    return segs


def duck_envelope(voices, v0_ms, dur, path, depth=-15.0, attack=0.3, release=0.8, rate=100):
    """Gain curve for the bed: down `depth` dB under every voice line, eased in and out."""
    n = int(math.ceil(dur * rate)) + 1
    db = [0.0] * n
    for ms, _, length in voices:
        a = (ms - v0_ms) / 1000
        b = a + length
        if b + release < 0 or a - attack > dur:
            continue
        for i in range(max(0, int((a - attack) * rate)), min(n, int((b + release) * rate) + 1)):
            t = i / rate
            if t < a:
                g = depth * (1 - (a - t) / attack)
            elif t <= b:
                g = depth
            else:
                g = depth * (1 - (t - b) / release)
            if g < db[i]:
                db[i] = g
    import array
    arr = array.array("f", (10 ** (g / 20) for g in db))
    path.write_bytes(arr.tobytes())
    return path


def mix_audio(capture, recs, v0_ms, dur, workdir, start_ms, tracks, segs):
    voices = voice_lines(recs, capture)
    items = []
    for ms, p, length in voices:
        off = (ms - v0_ms) / 1000
        if p is None or off + length <= 0 or off >= dur:
            continue
        chain = (f"atrim=start={-off:.3f},asetpts=PTS-STARTPTS,{AFMT}" if off < 0
                 else f"{AFMT},adelay=delays={int(round(off * 1000))}:all=1")
        items.append((["-i", str(p)], chain))
    voice_wav = ff_mix(items, workdir / "voice.wav", dur)
    if not segs:
        return voice_wav, len(items)

    t0w = (v0_ms - start_ms) / 1000
    bed = []
    for s in segs:
        a, b = s["t0"] - t0w, s["t1"] - t0w
        if b <= 0 or a >= dur:
            continue
        src, fin = s["src"], s["fade_in"]
        if a < 0:
            src, fin, a = src - a, 0.0, 0.0
        length = min(b, dur) - a
        if length <= 0.05:
            continue
        tr = tracks[s["idx"]]
        src %= tr["length"]
        fout = s["fade_out"] if b <= dur else 0.0
        chain = f"atrim=start={src:.3f}:duration={length:.3f},asetpts=PTS-STARTPTS,{AFMT},volume={tr['gain']:.2f}dB"
        if fin > 0:
            chain += f",afade=t=in:d={fin:.2f}"
        if fout > 0:
            chain += f",afade=t=out:st={max(0.0, length - fout):.3f}:d={min(fout, length):.2f}"
        chain += f",adelay=delays={int(round(a * 1000))}:all=1"
        bed.append((["-stream_loop", "-1", "-i", str(tr["path"])], chain))
    bed_wav = ff_mix(bed, workdir / "bed.wav", dur)
    env = duck_envelope([v for v in voices], v0_ms, dur, workdir / "duck.f32")
    out = workdir / "mix.wav"
    graph = (f"[2:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[e];"
             f"[1:a]aformat=sample_fmts=fltp:channel_layouts=stereo[b];[b][e]amultiply[bd];"
             f"[0:a]aformat=sample_fmts=fltp:channel_layouts=stereo[v];"
             f"[v][bd]amix=inputs=2:normalize=0:duration=first,atrim=0:{dur:.3f}[out]")
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", str(voice_wav), "-i", str(bed_wav),
                    "-f", "f32le", "-ar", "100", "-ac", "1", "-i", str(env),
                    "-filter_complex", graph, "-map", "[out]", "-c:a", "pcm_s16le", str(out)], check=True)
    return out, len(items)


# --- main ------------------------------------------------------------------

def encoder_args(choice):
    # libx264 is the default: most output frames are repeats, which x264 codes as
    # near-free skips, so it beats VideoToolbox about 3x in speed and 10x in size.
    encoders = subprocess.run([FFMPEG, "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    if choice == "videotoolbox" or (choice == "auto" and "libx264" not in encoders):
        return ["-c:v", "h264_videotoolbox", "-b:v", "12M", "-maxrate", "16M", "-bufsize", "24M",
                "-profile:v", "high", "-allow_sw", "1"]
    return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-tune", "stillimage",
            "-profile:v", "high", "-g", "150"]


def main():
    ap = argparse.ArgumentParser(description="Render a broll-capture directory as the Control Room B-roll MP4.")
    ap.add_argument("capture")
    ap.add_argument("--out")
    ap.add_argument("--start", type=float, help="window start, seconds since run start")
    ap.add_argument("--end", type=float, help="window end, seconds since run start")
    ap.add_argument("--fps", type=float, default=30)
    ap.add_argument("--size", default="1920x1080")
    ap.add_argument("--rate", type=float, default=10, help="frames drawn per second of video (ffmpeg repeats them)")
    ap.add_argument("--encoder", default="auto", choices=["auto", "videotoolbox", "x264"])
    ap.add_argument("--labels", action="store_true", help="map tiles with (Chinese) street labels")
    ap.add_argument("--music", help="music bed folder (default <captureDir>/music when it exists)")
    ap.add_argument("--no-music", action="store_true", help="voices only, no music bed")
    args = ap.parse_args()

    capture = Path(args.capture).expanduser().resolve()
    manifest, recs = load(capture)
    W, H = (int(v) for v in args.size.lower().split("x"))
    W -= W % 2
    H -= H % 2
    start_ms, end_ms = ms_of(manifest["startedAt"]), ms_of(manifest["endedAt"])
    run_dur = (end_ms - start_ms) / 1000
    t0 = max(0.0, args.start or 0.0)
    t1 = min(run_dur, args.end) if args.end is not None else run_dur
    if t1 <= t0:
        sys.exit(f"empty window {t0}..{t1} (run is {run_dur:.1f}s)")
    dur = t1 - t0
    v0_ms = start_ms + t0 * 1000
    out = Path(args.out).expanduser() if args.out else capture / (
        "broll.mp4" if args.start is None and args.end is None else f"broll-{int(t0)}-{int(t1)}.mp4")
    out.parent.mkdir(parents=True, exist_ok=True)

    wall0 = time.time()
    tracks, segs = [], []
    music_dir = Path(args.music).expanduser() if args.music else capture / "music"
    if not args.no_music and music_dir.is_dir():
        tracks = load_playlist(music_dir)
        segs = music_schedule(recs, start_ms, end_ms, tracks)
        print(f"music: {len(tracks)} tracks, {len(segs)} bed segments from {music_dir}", file=sys.stderr)
    r = Renderer(capture, manifest, recs, W, H, args.labels, args.rate, segs)
    print(f"map: {len(r.fixes)} fixes, tiles {r.tiles_ok}/{r.tiles_total}"
          + (f", zoom {r.zoom:.2f}" if r.tiles_total else ""), file=sys.stderr)

    with tempfile.TemporaryDirectory(prefix="broll-") as tmp:
        audio, nclips = mix_audio(capture, recs, v0_ms, dur, Path(tmp), start_ms, tracks, segs)
        print(f"audio: {nclips} voice lines" + (" over the music bed" if segs else "")
              + f" ({time.time() - wall0:.1f}s)", file=sys.stderr)

        nframes = max(1, math.ceil(dur * args.rate))
        cmd = [FFMPEG, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
               "-framerate", f"{args.rate}", "-i", "pipe:0", "-i", str(audio),
               "-map", "0:v", "-map", "1:a", "-r", f"{args.fps}"] + encoder_args(args.encoder) + [
               "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-t", f"{dur:.3f}",
               "-movflags", "+faststart", str(out)]
        enc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        render_wall = time.time()
        try:
            for n in range(nframes):
                ms = v0_ms + n * 1000 / args.rate
                enc.stdin.write(r.frame(ms).tobytes())
                if n and n % max(1, int(args.rate * 60)) == 0:
                    el = time.time() - render_wall
                    print(f"\r{n / args.rate / 60:.0f}/{dur / 60:.0f} min  {n / args.rate / el:.1f}x",
                          end="", file=sys.stderr, flush=True)
            enc.stdin.close()
        except BrokenPipeError:
            pass
        if enc.wait() != 0:
            sys.exit("ffmpeg failed")
    el = time.time() - wall0
    print(f"\n{out}: {dur:.1f}s of video in {el:.1f}s ({dur / el:.1f}x realtime)", file=sys.stderr)
    used = sorted({s["idx"] for s in segs if s["t1"] > t0 and s["t0"] < t1})
    if used:
        print("Music:", file=sys.stderr)
        for i in used:
            tr = tracks[i]
            print("  " + (tr["attribution"] or f'"{tr["title"]}" {tr["artist"]}'), file=sys.stderr)


if __name__ == "__main__":
    main()
