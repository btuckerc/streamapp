#!/usr/bin/env python3
"""Verify actual media decode, timestamp continuity and selected fixture tones."""
import argparse
import array
import json
import math
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('media')
parser.add_argument('--output', required=True)
parser.add_argument('--audio-at', type=float, default=1.0)
a = parser.parse_args()

def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)

probe = json.loads(run('ffprobe', '-v', 'error', '-count_frames', '-show_streams', '-show_format', '-of', 'json', a.media))
packets = json.loads(run('ffprobe', '-v', 'error', '-show_packets', '-show_entries', 'packet=stream_index,pts_time,dts_time,duration_time,flags', '-of', 'json', a.media))['packets']
chronology = {}
for stream in probe['streams']:
    selected = [packet for packet in packets if packet['stream_index'] == stream['index']]
    pts = sorted(float(packet['pts_time']) for packet in selected if 'pts_time' in packet)
    dts = [float(packet['dts_time']) for packet in selected if 'dts_time' in packet]
    chronology[stream['codec_type']] = {
        'packets': len(selected), 'first_pts': pts[0] if pts else None, 'last_pts': pts[-1] if pts else None,
        'backward_dts': sum(right < left for left, right in zip(dts, dts[1:])),
        'duplicate_pts': len(pts) - len(set(pts)),
        'max_pts_gap': max((right - left for left, right in zip(pts, pts[1:])), default=0),
    }
decode = subprocess.run(['ffmpeg', '-v', 'error', '-i', a.media, '-f', 'null', '-'], capture_output=True)
pcm = array.array('f')
pcm.frombytes(run('ffmpeg', '-v', 'error', '-ss', str(a.audio_at), '-i', a.media, '-t', '1', '-vn', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'))

def amplitude(frequency):
    coefficient = 2 * math.cos(2 * math.pi * frequency / 48000)
    previous = before_previous = 0
    for sample in pcm:
        current = sample + coefficient * previous - before_previous
        before_previous, previous = previous, current
    power = previous * previous + before_previous * before_previous - coefficient * previous * before_previous
    return 2 * math.sqrt(max(0, power)) / len(pcm) if pcm else None

result = {
    'media': a.media, 'probe': probe, 'chronology': chronology,
    'decode_exit': decode.returncode, 'decode_errors': decode.stderr.decode(),
    'audio_sample_at': a.audio_at, 'audio_samples': len(pcm),
    'audio_tone_amplitude': {str(f): amplitude(f) for f in (440, 880, 1500)},
    'audio_rms': math.sqrt(sum(x * x for x in pcm) / len(pcm)) if pcm else None,
}
Path(a.output).write_text(json.dumps(result, indent=2))
print(json.dumps({key: value for key, value in result.items() if key != 'probe'}, indent=2))
if decode.returncode or decode.stderr or any(value['backward_dts'] or value['duplicate_pts'] or not value['packets'] for value in chronology.values()):
    raise SystemExit(1)
