#!/usr/bin/env python3
"""Render a captured run as the Control Room B-roll video.

    scripts/broll-render.py <captureDir> [--out file.mp4] [--start S --end S]
                            [--fps 30] [--size 1920x1080] [--rate 2]
                            [--encoder auto|videotoolbox|x264] [--labels]

Needs Python 3 with Pillow (pip install pillow) and ffmpeg/ffprobe on PATH
(or in /opt/homebrew/bin).

Reads a capture written by scripts/broll-capture.py (format aarc-broll/1) and
writes an H.264 + AAC MP4 exactly as long as the run (manifest startedAt to
endedAt), or the --start/--end window in run seconds for previews. Video time
zero is the run start (or --start), so the B-roll lines up with the A-roll on
the voice lines, which are audible in both.

Frame layout: map with the route trail and a moving dot on the left, race
clock and live numbers top right, the Control Room feed and terminal below
them, and a subtitle band for whatever is being spoken. The audio track is
every voice line and talk-back clip mixed at the moment it played.

Frames are drawn at a low internal rate (--rate, default 2 per second) and
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

class Renderer:
    def __init__(self, capture, manifest, recs, W, H, labels):
        self.capture, self.W, self.H = capture, W, H
        k = self.k = H / 1080
        self.start_ms = ms_of(manifest["startedAt"])
        self.gate_ms = ms_of(manifest["gateAt"]) if manifest.get("gateAt") else None
        self.run_date = datetime.fromtimestamp(self.start_ms / 1000, BEIJING).strftime("%-d %b %Y").upper()

        self.sub_h = round(150 * k)
        self.map_w = round(W * 0.6)
        self.map_h = H - self.sub_h
        self.col_x = self.map_w
        self.col_w = W - self.map_w
        self.pad = round(28 * k)
        self.stats_h = round(262 * k)
        self.term_h = round(176 * k)
        self.feed_y = self.stats_h
        self.feed_h = self.map_h - self.stats_h - self.term_h

        self.f_label = Face(round(15 * k), "Semibold")
        self.f_clock = Face(round(84 * k), "Bold")
        self.f_wall = Face(round(40 * k), "Medium")
        self.f_num = Face(round(46 * k), "Semibold")
        self.f_unit = Face(round(20 * k), "Medium")
        self.f_head = Face(round(15 * k), "Bold")
        self.f_time = Face(round(14 * k), "Regular", mono=True)
        self.f_body = Face(round(21 * k), "Regular")
        self.f_term = Face(round(14 * k), "Regular", mono=True)
        self.f_sub = Face(round(36 * k), "Medium")
        self.f_sub_lab = Face(round(17 * k), "Bold")
        self.f_chip = Face(round(17 * k), "Semibold")
        self.f_chip_small = Face(round(15 * k), "Regular")
        self.f_km = Face(round(13 * k), "Bold")

        self.metrics = [r for r in recs if r["lane"] == "metrics"]
        self.dist = Series(self.metrics, "distanceM")
        self.pace = Series(self.metrics, "paceS")
        self.hr = Series(self.metrics + [r for r in recs if r["lane"] == "pos"], "hr")
        places = [r for r in recs if r["lane"] == "event" and r.get("type") == "place.context" and r.get("detail")]
        self.place_ms = [r["ms"] for r in places]
        self.place_v = [r["detail"] for r in places]

        self._setup_map(recs, labels)
        self._setup_feed(recs)
        self._setup_console(recs)
        self._setup_subs(recs)
        self._setup_chrome()
        self._cache = {}

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

    # feed
    def _setup_feed(self, recs):
        k = self.k
        talk_texts = {plain(r["text"])[:60] for r in recs if r["lane"] == "talkback" and r.get("text")}
        items = []
        screen_by_text = {}
        for r in recs:
            lane = r["lane"]
            if lane == "talkback" and r.get("text"):
                items.append({"ms": r["ms"], "label": RUNNER[0] + "  \u00b7  TALK-BACK", "color": RUNNER[1], "text": plain(r["text"])})
                r["_feed"] = len(items) - 1
            elif lane == "screen" and r.get("text"):
                txt = plain(r["text"])
                if r.get("role") == "user":
                    if txt[:60] in talk_texts:
                        continue
                    label, color = RUNNER
                else:
                    label, color = CONTROL
                items.append({"ms": r["ms"], "label": label, "color": color, "text": txt})
                screen_by_text[clean_speech(txt)[:60]] = len(items) - 1
            elif lane == "voice" and r.get("text"):
                txt = clean_speech(r["text"])
                if not txt:
                    continue
                prior = screen_by_text.get(txt[:60])
                if prior is not None and items[prior]["ms"] <= r["ms"]:
                    r["_feed"] = prior
                    continue
                label, color = SPEAKERS.get(r.get("speaker"), (str(r.get("speaker", "VOICE")).upper(), MUTED))
                items.append({"ms": r["ms"], "label": label, "color": color, "text": txt, "voice": True})
                r["_feed"] = len(items) - 1
            elif lane == "event" and str(r.get("type", "")).startswith("race.") and r.get("detail"):
                items.append({"ms": r["ms"], "label": RACE[0], "color": RACE[1], "text": plain(r["detail"]).capitalize()})
        inner = self.col_w - 2 * self.pad - round(46 * k)
        for it in items:
            it["lines"] = self.f_body.wrap(it["text"], inner, max_lines=5)
            it["h"] = round(52 * k) + len(it["lines"]) * round(28 * k)
            it["clock"] = datetime.fromtimestamp(it["ms"] / 1000, BEIJING).strftime("%H:%M:%S")
        order = sorted(range(len(items)), key=lambda i: items[i]["ms"])
        remap = {old: new for new, old in enumerate(order)}
        self.items = [items[i] for i in order]
        for r in recs:
            if "_feed" in r:
                r["_feed"] = remap[r["_feed"]]
        self.item_ms = [it["ms"] for it in self.items]

    def _feed(self, ms, playing):
        last = bisect.bisect_right(self.item_ms, ms) - 1
        key = ("feed", last, playing)
        if key in self._cache:
            return self._cache[key]
        k, w, h = self.k, self.col_w, self.feed_h
        img = Image.new("RGB", (w, h), PANEL)
        d = ImageDraw.Draw(img)
        y = h - round(16 * k)
        gap = round(12 * k)
        x0, x1 = self.pad, w - self.pad
        i = last
        while i >= 0 and y > 0:
            it = self.items[i]
            top = y - it["h"]
            hot = i == playing
            d.rounded_rectangle([x0, top, x1, y], radius=round(10 * k), fill=CARD_HOT if hot else CARD)
            d.rounded_rectangle([x0, top, x0 + round(5 * k), y], radius=round(3 * k), fill=it["color"])
            tx = x0 + round(22 * k)
            hx = self.f_head.draw(d, tx, top + round(30 * k), it["label"], it["color"])
            if hot:
                cx, cy = hx + round(14 * k), top + round(25 * k)
                s = round(6 * k)
                d.polygon([(cx, cy - s), (cx, cy + s), (cx + s * 1.6, cy)], fill=it["color"])
            self.f_time.draw(d, x1 - round(16 * k) - self.f_time.length(it["clock"]), top + round(30 * k), it["clock"], DIM)
            by = top + round(30 * k) + round(30 * k)
            for line in it["lines"]:
                self.f_body.draw(d, tx, by, line, TEXT if (hot or not it.get("voice")) else (205, 211, 222))
                by += round(28 * k)
            y = top - gap
            i -= 1
        fade = Image.linear_gradient("L").resize((w, round(110 * k))).transpose(Image.FLIP_TOP_BOTTOM)
        img.paste(PANEL, (0, 0, w, fade.height), fade)
        if len(self._cache) > 400:
            self._cache.clear()
        self._cache[key] = img
        return img

    # console
    def _setup_console(self, recs):
        self.console = []
        for r in recs:
            if r["lane"] == "console" and r.get("text"):
                first = plain(r["text"].strip().splitlines()[0])
                self.console.append((r["ms"], r.get("kind"), first))
        self.console_ms = [c[0] for c in self.console]

    def _terminal(self, ms):
        last = bisect.bisect_right(self.console_ms, ms) - 1
        key = ("term", last)
        if key in self._cache:
            return self._cache[key]
        k, w, h = self.k, self.col_w, self.term_h
        img = Image.new("RGB", (w, h), PANEL)
        d = ImageDraw.Draw(img)
        x0, x1 = self.pad, w - self.pad
        d.rounded_rectangle([x0, round(6 * k), x1, h - round(18 * k)], radius=round(10 * k), fill=(8, 11, 16), outline=RULE)
        self.f_label.draw(d, x0 + round(18 * k), round(32 * k), "CONTROL ROOM TERMINAL", DIM)
        lh = round(22 * k)
        rows = (h - round(70 * k)) // lh
        lines = self.console[max(0, last - rows + 1): last + 1] if last >= 0 else []
        y = round(32 * k) + round(30 * k)
        width = x1 - x0 - round(36 * k)
        for _, kind, text in lines:
            pre, col = ("$ ", TERM) if kind == "tool" else ("  ", (196, 202, 212))
            self.f_term.draw(d, x0 + round(18 * k), y, self.f_term.fit(pre + text, width), col)
            y += lh
        self._cache[key] = img
        return img

    # subtitles
    def _setup_subs(self, recs):
        subs = []
        for r in recs:
            if r["lane"] == "voice" and r.get("text"):
                txt = clean_speech(r["text"])
                label, color = SPEAKERS.get(r.get("speaker"), (str(r.get("speaker", "VOICE")).upper(), MUTED))
            elif r["lane"] == "talkback" and r.get("text"):
                txt = plain(r["text"])
                label, color = RUNNER[0] + "  \u00b7  TALK-BACK", RUNNER[1]
            else:
                continue
            if not txt:
                continue
            dur = r.get("durationS") or min(20.0, max(2.0, len(txt) / 15))
            subs.append({"ms": r["ms"], "end": r["ms"] + dur * 1000, "label": label, "color": color,
                         "text": txt, "feed": r.get("_feed")})
        self.subs = subs
        width = self.W - 2 * round(60 * self.k)
        for s in subs:
            lines = self.f_sub.wrap(s["text"], width)
            s["pages"] = [lines[i:i + 2] for i in range(0, len(lines), 2)] or [[""]]
            chars = [sum(len(l) for l in p) for p in s["pages"]]
            total = sum(chars) or 1
            acc, s["cuts"] = 0, []
            for c in chars:
                acc += c
                s["cuts"].append(acc / total)
        self.sub_ms = [s["ms"] for s in subs]

    def _active_sub(self, ms):
        i = bisect.bisect_right(self.sub_ms, ms) - 1
        while i >= 0 and self.subs[i]["ms"] > ms - 60000:
            if self.subs[i]["end"] > ms:
                return i
            i -= 1
        return None

    def _subtitle(self, ms, si):
        if si is None:
            page = 0
        else:
            s = self.subs[si]
            prog = (ms - s["ms"]) / max(1, s["end"] - s["ms"])
            page = next((n for n, c in enumerate(s["cuts"]) if prog < c), len(s["cuts"]) - 1)
        key = ("sub", si, page)
        if key in self._cache:
            return self._cache[key]
        k, w, h = self.k, self.W, self.sub_h
        img = Image.new("RGB", (w, h), (6, 8, 12))
        d = ImageDraw.Draw(img)
        d.line([(0, 0), (w, 0)], fill=RULE, width=max(1, round(2 * k)))
        x = round(60 * k)
        if si is not None:
            s = self.subs[si]
            d.rectangle([x - round(22 * k), round(26 * k), x - round(16 * k), h - round(24 * k)], fill=s["color"])
            self.f_sub_lab.draw(d, x, round(42 * k), s["label"], s["color"])
            y = round(42 * k) + round(46 * k)
            for line in s["pages"][page]:
                self.f_sub.draw(d, x, y, line, TEXT)
                y += round(44 * k)
        self._cache[key] = img
        return img

    # stats + chrome
    def _setup_chrome(self):
        k = self.k
        img = Image.new("RGB", (self.W, self.H), PANEL)
        d = ImageDraw.Draw(img)
        d.line([(self.col_x, 0), (self.col_x, self.map_h)], fill=RULE, width=max(1, round(2 * k)))
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
        self.f_label.draw(d, x0, round(40 * k), label, MUTED)
        self.f_clock.draw(d, x0 - round(3 * k), round(122 * k), clock, TEXT)
        self.f_label.draw(d, x1 - self.f_label.length("BEIJING"), round(40 * k), "BEIJING", MUTED)
        self.f_wall.draw(d, x1 - self.f_wall.length(wall), round(92 * k), wall, (196, 204, 216))
        d.line([(x0, round(150 * k)), (x1, round(150 * k))], fill=RULE, width=max(1, round(2 * k)))
        cols = [("DISTANCE", dist, "km"), ("PACE", pace, "/km"), ("HEART RATE", hr, "bpm")]
        cw = (x1 - x0) / 3
        for n, (lab, val, unit) in enumerate(cols):
            cx = x0 + n * cw
            self.f_label.draw(d, cx, round(184 * k), lab, MUTED)
            vx = self.f_num.draw(d, cx, round(238 * k), val, TEXT if n != 2 else (255, 120, 120))
            self.f_unit.draw(d, vx + round(6 * k), round(238 * k), unit, MUTED)
        self._cache[key] = img
        return img

    def _chip(self, ms):
        i = bisect.bisect_right(self.place_ms, ms) - 1
        place = self.place_v[i] if i >= 0 else ""
        key = ("chip", place)
        if key in self._cache:
            return self._cache[key]
        k = self.k
        title = "AARC  \u00b7  CONTROL ROOM"
        sub = "  \u00b7  ".join(x for x in (place, self.run_date) if x)
        w = round(max(self.f_chip.length(title), self.f_chip_small.length(sub)) + 48 * k)
        h = round(78 * k)
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=round(12 * k), fill=(8, 11, 16, 215), outline=RULE + (255,))
        d.ellipse([round(20 * k), round(22 * k), round(30 * k), round(32 * k)], fill=TRAIL + (255,))
        self.f_chip.draw(d, round(40 * k), round(33 * k), title, TEXT)
        self.f_chip_small.draw(d, round(20 * k), round(60 * k), sub, MUTED)
        self._cache[key] = img
        return img

    def frame(self, ms):
        img = self.chrome.copy()
        m = self._map_frame(ms)
        chip = self._chip(ms)
        m.paste(chip, (round(24 * self.k), round(24 * self.k)), chip)
        img.paste(m, (0, 0))
        img.paste(self._stats(ms), (self.col_x + 1, 0))
        si = self._active_sub(ms)
        playing = self.subs[si]["feed"] if si is not None else None
        img.paste(self._feed(ms, playing), (self.col_x + 1, self.feed_y))
        img.paste(self._terminal(ms), (self.col_x + 1, self.feed_y + self.feed_h))
        img.paste(self._subtitle(ms, si), (0, self.map_h))
        return img


# --- audio -----------------------------------------------------------------

def mix_audio(capture, recs, v0_ms, dur, workdir):
    clips = []
    for r in recs:
        if r["lane"] in ("voice", "talkback") and r.get("audio"):
            p = capture / r["audio"]
            if not p.exists():
                continue
            length = r.get("durationS") or 60
            off = (r["ms"] - v0_ms) / 1000
            if off + length <= 0 or off >= dur:
                continue
            clips.append((p, off))
    out = workdir / "mix.wav"
    fmt = "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo"
    if not clips:
        subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                        "anullsrc=r=48000:cl=stereo", "-t", f"{dur:.3f}", "-c:a", "pcm_s16le", str(out)], check=True)
        return out, 0

    def mix(inputs, dest):
        args, chains, labels = [FFMPEG, "-y", "-loglevel", "error"], [], []
        for n, (path, off) in enumerate(inputs):
            args += ["-i", str(path)]
            if off < 0:
                chain = f"[{n}:a]atrim=start={-off:.3f},asetpts=PTS-STARTPTS,{fmt}"
            else:
                chain = f"[{n}:a]{fmt},adelay=delays={int(round(off * 1000))}:all=1"
            chains.append(chain + f"[a{n}]")
            labels.append(f"[a{n}]")
        tail = f"apad=whole_dur={dur:.3f},atrim=0:{dur:.3f}"
        if len(inputs) == 1:
            graph = ";".join(chains) + f";{labels[0]}{tail}[out]"
        else:
            graph = ";".join(chains) + f";{''.join(labels)}amix=inputs={len(inputs)}:normalize=0:duration=longest:dropout_transition=0,{tail}[out]"
        args += ["-filter_complex", graph, "-map", "[out]", "-ar", "48000", "-c:a", "pcm_s16le", str(dest)]
        subprocess.run(args, check=True)

    batch = 40
    parts = []
    for i in range(0, len(clips), batch):
        dest = workdir / f"mix{i // batch}.wav"
        mix(clips[i:i + batch], dest)
        parts.append(dest)
    if len(parts) == 1:
        parts[0].rename(out)
    else:
        mix([(p, 0) for p in parts], out)
    return out, len(clips)


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
    ap.add_argument("--rate", type=float, default=2, help="frames drawn per second of video (ffmpeg repeats them)")
    ap.add_argument("--encoder", default="auto", choices=["auto", "videotoolbox", "x264"])
    ap.add_argument("--labels", action="store_true", help="map tiles with (Chinese) street labels")
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
    r = Renderer(capture, manifest, recs, W, H, args.labels)
    print(f"map: {len(r.fixes)} fixes, tiles {r.tiles_ok}/{r.tiles_total}"
          + (f", zoom {r.zoom:.2f}" if r.tiles_total else ""), file=sys.stderr)

    with tempfile.TemporaryDirectory(prefix="broll-") as tmp:
        audio, nclips = mix_audio(capture, recs, v0_ms, dur, Path(tmp))
        print(f"audio: {nclips} clips mixed ({time.time() - wall0:.1f}s)", file=sys.stderr)

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


if __name__ == "__main__":
    main()
