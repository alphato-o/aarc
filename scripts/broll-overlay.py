#!/usr/bin/env python3
"""Render the vitals and map overlay for the camera A-roll, with an alpha channel.

    scripts/broll-overlay.py <captureDir> --clip CLIP.MP4 --at T [--out file.mov]
    scripts/broll-overlay.py <captureDir> --start S --end S [--out file.mov]
                             [--size WxH] [--fps F] [--rate 10] [--no-map] [--no-stats]
                             [--map-corner tr|tl|br|bl]

Same capture and the same look as broll-render.py: a race clock, Beijing time,
distance, pace and heart rate card in the lower left and a rounded map card
(trail, km markers, moving dot) in a corner, on a transparent frame. The output
is a .mov with alpha (QuickTime Animation, 10 fps by default; Premiere holds each
frame), so it goes on the track above the A-roll clip at the same start.

--clip takes size and duration from the clip (ffprobe) and --at is
the run time, in seconds since the run started, of that clip's first frame, so
one overlay per clip comes out exactly as long as the clip. --start/--end is a
window in run seconds instead. The official result in the manifest wins over the
watch: distance is scaled to the certified course and the clock stops at the
chip time.
"""
import argparse
import importlib.util
import json
import math
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw

_spec = importlib.util.spec_from_file_location("broll_render", Path(__file__).with_name("broll-render.py"))
br = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(br)


class Overlay(br.Renderer):
    """Only the stats card and the map card, drawn over transparency."""

    def __init__(self, capture, manifest, recs, W, H, rate, show_map, show_stats, corner):
        self.capture, self.W, self.H, self.rate = capture, W, H, rate
        self.music = []
        k = self.k = H / 1080
        self.start_ms = br.ms_of(manifest["startedAt"])
        self.gate_ms = br.ms_of(manifest["gateAt"]) if manifest.get("gateAt") else None
        self.run_date = datetime.fromtimestamp(self.start_ms / 1000, br.BEIJING).strftime("%-d %b %Y").upper()
        self.show_map, self.show_stats, self.corner = show_map, show_stats, corner
        self.margin = round(48 * k)

        self.f_label = br.Face(round(15 * k), "Semibold")
        self.f_clock = br.Face(round(64 * k), "Bold")
        self.f_wall = br.Face(round(24 * k), "Medium")
        self.f_num = br.Face(round(44 * k), "Semibold")
        self.f_unit = br.Face(round(18 * k), "Medium")
        self.f_chip = br.Face(round(16 * k), "Semibold")
        self.f_chip_small = br.Face(round(13 * k), "Regular")
        self.f_km = br.Face(round(12 * k), "Bold")

        self._setup_series(manifest, recs)
        self._cache = {}
        self.map_w, self.map_h = round(520 * k), round(400 * k)
        self.fixes, self.tiles_ok, self.tiles_total = [], 0, 0
        if show_map:
            self._setup_map(recs, labels=False)
            self.map_mask = Image.new("L", (self.map_w, self.map_h), 0)
            ImageDraw.Draw(self.map_mask).rounded_rectangle(
                [0, 0, self.map_w - 1, self.map_h - 1], radius=round(18 * k), fill=236)

    def _card(self, ms):
        k = self.k
        label, clock, wall, dist, pace, hr = self._readout(ms)
        key = ("card", label, clock, wall, dist, pace, hr)
        hit = self._cache.get(key)
        if hit is not None:
            return hit
        cols = [("DISTANCE", dist, "km", br.TEXT), ("PACE", pace, "/km", br.TEXT), ("HEART RATE", hr, "bpm", (255, 120, 120))]
        pad, gap = round(28 * k), round(34 * k)
        clock_w = max(self.f_clock.length("-0:00:00"), self.f_clock.length(clock), self.f_label.length("TO THE GATE"))
        # Widths from the widest value each column will ever show, so the card never jumps.
        widest = ["00.000", "00:00", "000"]
        col_w = [max(self.f_num.length(widest[n]) + 6 * k + self.f_unit.length(u), self.f_label.length(lab))
                 for n, (lab, _, u, _) in enumerate(cols)]
        w = round(pad * 2 + clock_w + gap + sum(col_w) + gap * (len(cols) - 1))
        h = round(150 * k)
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=round(18 * k), fill=(8, 11, 16, 200),
                            outline=br.RULE + (230,), width=max(1, round(2 * k)))
        x = pad
        self.f_label.draw(d, x, round(40 * k), label, br.MUTED)
        self.f_clock.draw(d, x - round(2 * k), round(106 * k), clock, br.TEXT)
        self.f_wall.draw(d, x, round(136 * k), "BEIJING " + wall, (170, 180, 194))
        x += clock_w + gap
        for n, (lab, val, unit, fill) in enumerate(cols):
            self.f_label.draw(d, x, round(40 * k), lab, br.MUTED)
            vx = self.f_num.draw(d, x, round(100 * k), val, fill)
            self.f_unit.draw(d, vx + round(6 * k), round(100 * k), unit, br.MUTED)
            x += col_w[n] + gap
        if len(self._cache) > 600:
            self._cache.clear()
        self._cache[key] = img
        return img

    def frame(self, ms):
        img = Image.new("RGBA", (self.W, self.H), (0, 0, 0, 0))
        m = self.margin
        if self.show_map:
            mp = self._map_frame(ms).convert("RGBA")
            mp.putalpha(self.map_mask)
            chip = self._chip(ms)
            mp.alpha_composite(chip, (round(14 * self.k), round(14 * self.k)))
            x = m if self.corner[1] == "l" else self.W - m - self.map_w
            y = m if self.corner[0] == "t" else self.H - m - self.map_h
            img.alpha_composite(mp, (x, y))
        if self.show_stats:
            card = self._card(ms)
            img.alpha_composite(card, (m, self.H - m - card.height))
        return img


# Animation (RLE) keeps alpha and squeezes the transparent rows: at 2.7K about 55 MB a
# minute at 10 fps, against 3.5 GB a minute for ProRes 4444 at 59.94.
CODECS = {
    "animation": ["-c:v", "qtrle", "-pix_fmt", "argb"],
    "prores4444": ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le",
                   "-alpha_bits", "8", "-vendor", "apl0"],
}


def probe(clip):
    r = subprocess.run([br.FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
                        "stream=width,height,r_frame_rate:format=duration", "-of", "json", str(clip)],
                       capture_output=True, text=True, check=True)
    j = json.loads(r.stdout)
    s = j["streams"][0]
    num, den = (int(v) for v in s["r_frame_rate"].split("/"))
    return int(s["width"]), int(s["height"]), f"{num}/{den}", float(j["format"]["duration"])


def main():
    ap = argparse.ArgumentParser(description="Render the A-roll vitals and map overlay (ProRes 4444 with alpha).")
    ap.add_argument("capture")
    ap.add_argument("--clip", help="A-roll clip to match (size, frame rate, duration)")
    ap.add_argument("--at", type=float, help="run seconds at the clip's first frame (with --clip)")
    ap.add_argument("--start", type=float, help="window start, run seconds")
    ap.add_argument("--end", type=float, help="window end, run seconds")
    ap.add_argument("--out")
    ap.add_argument("--size", help="WxH (default: the clip's, else 1920x1080)")
    ap.add_argument("--fps", help="output frame rate (default: the draw rate; Premiere holds each frame)")
    ap.add_argument("--rate", type=float, default=10, help="frames drawn per second (ffmpeg repeats them)")
    ap.add_argument("--no-map", action="store_true")
    ap.add_argument("--no-stats", action="store_true")
    ap.add_argument("--codec", default="animation", choices=sorted(CODECS))
    ap.add_argument("--map-corner", default="tr", choices=["tr", "tl", "br", "bl"])
    ap.add_argument("--redact", default=str(Path(__file__).resolve().parent.parent / "private" / "broll-redact.txt"))
    args = ap.parse_args()

    capture = Path(args.capture).expanduser().resolve()
    manifest, recs = br.load(capture)
    pairs = br.load_redactions(args.redact)
    if pairs:
        br.redact(recs, pairs)
    br.strip_cjk(recs)

    W, H = 1920, 1080
    # 10 frames a second is smooth for a slow dot and a ticking clock, and about 6x
    # smaller than matching the camera's 59.94.
    fps = args.fps or f"{args.rate:g}"
    if args.clip:
        if args.at is None:
            sys.exit("--clip needs --at (run seconds at the clip's first frame)")
        W, H, _, dur = probe(args.clip)
        t0, t1 = args.at, args.at + dur
    else:
        if args.start is None or args.end is None:
            sys.exit("give --clip and --at, or --start and --end")
        t0, t1 = args.start, args.end
    if args.size:
        W, H = (int(v) for v in args.size.lower().split("x"))
    W -= W % 2
    H -= H % 2
    dur = t1 - t0
    if dur <= 0:
        sys.exit(f"empty window {t0}..{t1}")
    if args.out:
        out = Path(args.out).expanduser()
    elif args.clip:
        out = Path(args.clip).with_suffix(".overlay.mov")
    else:
        out = capture / f"overlay-{int(t0)}-{int(t1)}.mov"
    out.parent.mkdir(parents=True, exist_ok=True)

    start_ms = br.ms_of(manifest["startedAt"])
    r = Overlay(capture, manifest, recs, W, H, args.rate, not args.no_map, not args.no_stats, args.map_corner)
    if r.show_map:
        print(f"map: {len(r.fixes)} fixes, tiles {r.tiles_ok}/{r.tiles_total}", file=sys.stderr)
    # Catch the trail up to the window start so a clip mid-race shows the course so far.
    v0_ms = start_ms + t0 * 1000
    if r.show_map:
        r._map_frame(v0_ms)

    cmd = [br.FFMPEG, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{W}x{H}",
           "-framerate", f"{args.rate}", "-i", "pipe:0", "-r", fps,
           ] + CODECS[args.codec] + ["-t", f"{dur:.3f}", str(out)]
    enc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    wall0 = time.time()
    nframes = max(1, math.ceil(dur * args.rate))
    try:
        for n in range(nframes):
            enc.stdin.write(r.frame(v0_ms + n * 1000 / args.rate).tobytes())
            if n and n % max(1, int(args.rate * 60)) == 0:
                el = time.time() - wall0
                print(f"\r{n / args.rate / 60:.0f}/{dur / 60:.0f} min  {n / args.rate / el:.1f}x",
                      end="", file=sys.stderr, flush=True)
        enc.stdin.close()
    except BrokenPipeError:
        pass
    if enc.wait() != 0:
        sys.exit("ffmpeg failed")
    el = time.time() - wall0
    print(f"\n{out}: {dur:.1f}s at {W}x{H} {fps} in {el:.1f}s ({dur / el:.1f}x realtime)", file=sys.stderr)


if __name__ == "__main__":
    main()
