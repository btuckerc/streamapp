"""Media measurement shared by bench/run.py; app-agnostic (only files and the stimulus log).

- `facts(path)`: container/stream facts plus video cadence from packet timestamps (no decode).
- `av_offset(path, stimulus)`: tone-burst onset minus dark→light video transition, per flip.
- Stimulus helpers used by bench/rtmp.py for glass→receiver latency.
"""
import array, json, math, shutil, statistics, subprocess, time
from pathlib import Path

FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'
GRID_W, GRID_H = 64, 36          # luminance grid the stimulus is detected on
TONE_WINDOW = 96                 # 2 ms at 48 kHz; Goertzel window for the 2 kHz burst
RTMP_PORT = 19351


def now_ns() -> int:
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def summary(values: list[float]) -> dict | None:
    if not values: return None
    ordered = sorted(values)
    return {'n': len(ordered), 'median': round(statistics.median(ordered), 2),
            'p95': round(ordered[min(len(ordered) - 1, math.ceil(0.95 * len(ordered)) - 1)], 2),
            'min': round(ordered[0], 2), 'max': round(ordered[-1], 2)}


def facts(path: Path) -> dict:
    info = json.loads(subprocess.check_output([FFPROBE, '-v', 'error', '-show_entries',
        'format=duration,size,bit_rate:stream=index,codec_type,codec_name,profile,width,height,pix_fmt,color_space,'
        'r_frame_rate,has_b_frames,sample_rate,channels,bit_rate,start_time', '-of', 'json', str(path)]))
    video = next((s for s in info['streams'] if s['codec_type'] == 'video'), None)
    audio = next((s for s in info['streams'] if s['codec_type'] == 'audio'), None)
    result = {'bytes': int(info['format'].get('size', 0)), 'duration_s': float(info['format'].get('duration', 0)),
              'bit_rate': int(info['format'].get('bit_rate', 0) or 0), 'video': video, 'audio': audio}
    if video:
        rows = subprocess.check_output([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                        'packet=pts_time,flags', '-of', 'csv=p=0', str(path)], text=True).split()
        packets = [(float(pts), 'K' in flags) for pts, flags in (r.split(',', 1) for r in rows if not r.startswith('N/A'))]
        pts = sorted(p for p, _ in packets)
        keys = sorted(p for p, k in packets if k)
        num, den = (int(x) for x in video['r_frame_rate'].split('/'))
        period = den / num
        # Steady-state cadence skips the first second (the first frame interval is a start-up artifact).
        deltas = [b - a for a, b in zip(pts, pts[1:]) if pts and a >= pts[0] + 1]
        span = pts[-1] - pts[0] + period if pts else 0
        result['cadence'] = {
            'frames': len(pts), 'nominal_fps': num / den, 'effective_fps': round(len(pts) / span, 3) if span else 0,
            'first_interval_ms': round((pts[1] - pts[0]) * 1000, 1) if len(pts) > 1 else None,
            'gaps_over_1_5_frames': sum(1 for d in deltas if d > 1.5 * period),
            'max_gap_ms': round(max(deltas) * 1000, 1) if deltas else None,
            'keyframe_interval_s': round(statistics.median(b - a for a, b in zip(keys, keys[1:])), 3) if len(keys) > 1 else None,
        }
    return result


def stimulus_log(path: Path) -> tuple[dict, list[dict]]:
    lines = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    return lines[0], lines[1:]


def mask(header: dict, width: int, height: int) -> list[int]:
    """Grid cells inside the central 60% of the stimulus square, assuming the display is fitted and
    centred in the output frame (true for both apps' main-display capture)."""
    sw, sh = header['screen']['w'], header['screen']['h']
    x, y, w, h = header['rect']
    scale = min(width / sw, height / sh)
    ox, oy = (width - sw * scale) / 2, (height - sh * scale) / 2
    cx, cy = ox + (x + w / 2) * scale, oy + (y + h / 2) * scale
    half = 0.3 * w * scale
    gx, gy = GRID_W / width, GRID_H / height
    cells = [r * GRID_W + c for r in range(GRID_H) for c in range(GRID_W)
             if abs((c + 0.5) / gx - cx) <= half and abs((r + 0.5) / gy - cy) <= half]
    if not cells: raise ValueError('stimulus square maps to no grid cells')
    return cells


def levels(frames: list[bytes], cells: list[int]) -> tuple[list[float], float | None]:
    """Mean masked luminance per frame and the light/dark threshold (None if the square is not visible)."""
    means = [sum(f[i] for i in cells) / len(cells) for f in frames]
    if not means: return means, None
    low, high = min(means), max(means)
    return means, ((low + high) / 2 if high - low >= 60 else None)


def decode_gray(path: Path) -> list[bytes]:
    raw = subprocess.run([FFMPEG, '-v', 'error', '-i', str(path), '-map', '0:v:0', '-fps_mode', 'passthrough',
                          '-vf', f'scale={GRID_W}:{GRID_H}:flags=area,format=gray', '-f', 'rawvideo', '-'],
                         capture_output=True, check=True).stdout
    n = GRID_W * GRID_H
    return [raw[i:i + n] for i in range(0, len(raw) - n + 1, n)]


def tone_onsets(samples: array.array, rate: int = 48_000) -> list[float]:
    """Onset times (s from first sample) of 2 kHz bursts, from a Goertzel power envelope."""
    coeff = 2 * math.cos(2 * math.pi * 2000 / rate)
    power = []
    for start in range(0, len(samples) - TONE_WINDOW + 1, TONE_WINDOW):
        s1 = s2 = 0.0
        for v in samples[start:start + TONE_WINDOW]:
            s1, s2 = v + coeff * s1 - s2, s1
        power.append(s1 * s1 + s2 * s2 - coeff * s1 * s2)
    if not power: return []
    peak = max(power)
    floor = statistics.median(power)
    if peak <= max(floor * 100, 1e3): return []
    threshold = max(peak * 0.02, floor * 20)
    onsets, i = [], 0
    while i < len(power):
        if power[i] < threshold: i += 1; continue
        j = i
        while j < len(power) and power[j] >= threshold: j += 1
        group = range(i, j)
        total = sum(power[k] for k in group)
        centre = sum((k + 0.5) * power[k] for k in group) / total * TONE_WINDOW / rate
        onsets.append(centre - 0.005)  # 10 ms Hann burst: its energy centroid is 5 ms after onset
        i = j
    return onsets


def av_offset(path: Path, stimulus: Path) -> dict:
    """Audio minus video time for each dark→light flip within one file (positive: audio late).
    Video transitions are quantised to the 33 ms capture interval; the stimulus's own audio output
    latency is a constant shared by every app, so compare apps rather than reading absolutes."""
    header, _ = stimulus_log(stimulus)
    info = facts(path)
    video, audio = info['video'], info['audio']
    if not video or not audio: return {'error': 'missing video or audio stream'}
    frames = decode_gray(path)
    rows = subprocess.check_output([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time',
                                    '-of', 'csv=p=0', str(path)], text=True).split()
    times = sorted(float(r) for r in rows if r != 'N/A')[:len(frames)]
    means, threshold = levels(frames, mask(header, video['width'], video['height']))
    if threshold is None: return {'error': 'stimulus square not visible in video'}
    rises = [times[i] for i in range(1, len(times)) if means[i - 1] < threshold <= means[i]]
    pcm = subprocess.run([FFMPEG, '-v', 'error', '-i', str(path), '-map', '0:a:0', '-ac', '1', '-ar', '48000',
                          '-f', 's16le', '-'], capture_output=True, check=True).stdout
    samples = array.array('h'); samples.frombytes(pcm[:len(pcm) // 2 * 2])
    start = float(audio.get('start_time') or 0)
    onsets = [start + t for t in tone_onsets(samples)]
    result = {'video_flips': len(rises), 'tone_bursts': len(onsets)}
    if len(onsets) > len(rises) * 1.5 + 2:  # other 2 kHz content (e.g. background playback) makes pairing meaningless
        return {**result, 'error': 'captured audio has 2 kHz bursts that the stimulus did not play'}
    offsets = []
    for rise in rises:
        nearest = min(onsets, key=lambda a: abs(a - rise), default=None)
        if nearest is not None and abs(nearest - rise) < 0.4: offsets.append((nearest - rise) * 1000)
    return {**result, 'paired': len(offsets), 'offset_ms': summary(offsets)}
