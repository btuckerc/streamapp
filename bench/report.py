#!/usr/bin/env python3
"""Summaries and Markdown for bench/run.py results.

    python3 bench/report.py RESULTS.json                 # re-render one run (StreamApp vs OBS)
    python3 bench/report.py OLD.json NEW.json [...]      # same app+scenario across runs (releases, OBS upgrades)
"""
import json, statistics, sys
from pathlib import Path

# (section, label, dotted path into a trial, unit, scale)
METRICS = [
    ('Startup', 'Launch → ready', 'timings.launch_to_ready_ms', 'ms', 1),
    ('Startup', 'CPU time to reach ready', 'launch.cpu_ms', 'ms', 1),
    ('Startup', 'Start request → output started', 'timings.start_ms', 'ms', 1),
    ('Startup', 'Stop request → finalized', 'timings.stop_ms', 'ms', 1),
    ('App process tree', 'CPU (100% = one core)', 'window.cpu_percent', '%', 1),
    ('App process tree', 'CPU energy (kernel estimate)', 'window.energy_mw', 'mW', 1),
    ('App process tree', 'Instructions retired', 'window.instructions_g_per_s', 'G/s', 1),
    ('App process tree', 'GPU time', 'window.gpu_ms_per_s', 'ms/s', 1),
    ('App process tree', 'Wakeups', 'window.wakeups_per_s', '/s', 1),
    ('App process tree', 'Memory footprint (mean)', 'window.footprint_mb_mean', 'MB', 1),
    ('App process tree', 'Memory footprint (peak)', 'window.footprint_mb_max', 'MB', 1),
    ('Machine, above pre-launch baseline', 'Host CPU', 'above_baseline.host_cpu_cores', 'cores', 1),
    ('Machine, above pre-launch baseline', 'WindowServer GPU', 'above_baseline.windowserver_gpu_ms_per_s', 'ms/s', 1),
    ('Machine, above pre-launch baseline', 'GPU energy', 'above_baseline.gpu_energy_mw', 'mW', 1),
    ('Latency and sync', 'Glass → loopback receiver (median)', 'stream.glass_to_receiver_ms.median', 'ms', 1),
    ('Latency and sync', 'Glass → loopback receiver (p95)', 'stream.glass_to_receiver_ms.p95', 'ms', 1),
    ('Latency and sync', 'Start request → first received frame', 'stream.first_frame_after_start_ms', 'ms', 1),
    ('Latency and sync', 'A/V offset, recording (median)', 'recording.av_offset.offset_ms.median', 'ms', 1),
    ('Latency and sync', 'A/V offset, received stream (median)', 'stream.av_offset.offset_ms.median', 'ms', 1),
    ('Output', 'Recording effective frame rate', 'recording.cadence.effective_fps', 'fps', 1),
    ('Output', 'Recording gaps > 1.5 frames after 1 s', 'recording.cadence.gaps_over_1_5_frames', '', 1),
    ('Output', 'Recording max frame interval after 1 s', 'recording.cadence.max_gap_ms', 'ms', 1),
    ('Output', 'Recording bitrate', 'recording.bit_rate', 'Mb/s', 1e-6),
    ('Output', 'Received effective frame rate', 'stream.received.cadence.effective_fps', 'fps', 1),
    ('Output', 'Received bitrate', 'stream.received.bit_rate', 'Mb/s', 1e-6),
]
NAMES = {'streamapp': 'StreamApp', 'obs': 'OBS'}
SCENARIOS = ('idle', 'record', 'stream', 'both', 'record-motion', 'stream-motion', 'both-motion')


def title(scenario: str) -> str:
    base, _, content = scenario.partition('-')
    return base.capitalize() + (' · full-screen motion' if content == 'motion' else ' · static screen' if base != 'idle' else '')


def lookup(trial: dict, path: str):
    value = trial
    for key in path.split('.'):
        if not isinstance(value, dict) or key not in value: return None
        value = value[key]
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def summarize(document: dict) -> dict:
    groups: dict = {}
    for trial in document['trials']:
        groups.setdefault(trial['app'], {}).setdefault(trial['scenario'], []).append(trial)
    summary: dict = {}
    for app, scenarios in groups.items():
        for scenario, trials in scenarios.items():
            for _, _, path, _, scale in METRICS:
                values = [v * scale for t in trials if (v := lookup(t, path)) is not None]
                if values:
                    summary.setdefault(app, {}).setdefault(scenario, {})[path] = {
                        'median': round(statistics.median(values), 3), 'min': round(min(values), 3), 'max': round(max(values), 3), 'n': len(values)}
    return summary


def cell(stat: dict | None) -> str:
    if not stat: return '—'
    text = f"{stat['median']:.4g}"
    return text + (f" ({stat['min']:.4g}–{stat['max']:.4g})" if stat['n'] > 1 and stat['min'] != stat['max'] else '')


def header(document: dict) -> list[str]:
    env = document['environment']
    m, power = env['machine'], env['power']
    lines = [f"- Date: {env['date']} · label `{document.get('label') or '—'}` · repo `{env['repo']['commit']}` ({env['repo']['dirty_files']} uncommitted files)",
             f"- Machine: {m['model']}, {m['cpu']}, {m['cores']} cores, {m['memory_gb']} GB, macOS {m['macos']}",
             f"- Displays: " + '; '.join(f"{d.get('_name')} {d.get('_spdisplays_pixels') or ''} as {d.get('_spdisplays_resolution') or ''}".strip() for d in m['displays']),
             f"- Power: {power['source']}, Low Power Mode {'on' if power['low_power_mode'] else 'off'}" + (f" — **{power['warning']}; treat absolute numbers with caution**" if power.get('warning') else '')]
    for name, app in env['apps'].items():
        detail = f"{app.get('version')}" + (f" build {app['build']}" if app.get('build') else '') + f", bundle {app['bundle_mb']} MB"
        lines.append(f"- {NAMES.get(name, name)}: {detail}" + (f" ({app['ffmpeg']})" if app.get('ffmpeg') else ''))
    if floor := env.get('receiver_floor'):
        latency = floor.get('glass_to_receiver_ms') or {}
        lines.append(f"- Receiver floor (synthetic x264 publisher → socket): median {latency.get('median')} ms, max {latency.get('max')} ms"
                     + (f" — error: {floor['error']}" if floor.get('error') else ''))
    c = document['config']
    lines.append(f"- Trials: {c['repeat']} reps × {c['seconds']:g} s window (after {c['warmup']:g} s warmup), probe every {c['interval']:g} s, apps interleaved")
    w = document['workload']
    lines.append(f"- Workload: {w['width']}×{w['height']} @ {w['fps']} fps, {w['video_kbps']} kb/s, keyframe {w['keyframe_seconds']} s, {w['encoder']}; "
                 f"AAC {w['audio_kbps']} kb/s {w['sample_rate']} Hz; {w['capture']}; {w['recording']}; {w['extras']}")
    return lines


def render(document: dict) -> str:
    summary = document.get('summary') or summarize(document)
    apps = list(document['environment']['apps'])
    scenarios = [s for s in SCENARIOS if any(s in summary.get(a, {}) for a in apps)]
    out = ['# StreamApp vs OBS runtime benchmark', '', *header(document), '',
           'Values are medians across repetitions, with (min–max). Lower is better except frame rate and bitrate.', '']
    ratio = len(apps) == 2
    for scenario in scenarios:
        out += [f'## {title(scenario)}', '']
        columns = [NAMES.get(a, a) for a in apps] + ([f'{NAMES.get(apps[0], apps[0])} ÷ {NAMES.get(apps[1], apps[1])}'] if ratio else [])
        out += ['| Metric | ' + ' | '.join(columns) + ' |', '|---|' + '---|' * len(columns)]
        section = None
        for group, label, path, unit, _ in METRICS:
            stats = [summary.get(a, {}).get(scenario, {}).get(path) for a in apps]
            if not any(stats): continue
            if group != section:
                out.append(f'| **{group}** |' + ' |' * len(columns)); section = group
            row = [cell(s) for s in stats]
            if ratio:
                a, b = stats
                row.append(f"{a['median'] / b['median']:.2f}×" if a and b and b['median'] and unit not in ('fps', 'Mb/s', '') and 'offset' not in path else '')
            out.append(f"| {label}{f' ({unit})' if unit else ''} | " + ' | '.join(row) + ' |')
        out.append('')
    out += ['## Per-process CPU and GPU (median trial, measured window)', '']
    for scenario in scenarios:
        for app in apps:
            trials = sorted((t for t in document['trials'] if t['app'] == app and t['scenario'] == scenario and t.get('window')),
                            key=lambda t: t['window']['cpu_percent'])
            if not trials: continue
            processes = trials[len(trials) // 2]['window']['processes']
            parts = [f"{n} {p['cpu_percent']:.2f}% / {p['gpu_ms_per_s']:.2f} ms/s / {p['footprint_mb_max']:.0f} MB"
                     for n, p in sorted(processes.items(), key=lambda kv: -kv[1]['cpu_percent'])]
            out.append(f"- {scenario} · {NAMES.get(app, app)}: " + '; '.join(parts))
    if document.get('failures'):
        out += ['', '## Failures', ''] + [f"- {f['app']} {f['scenario']} rep {f['rep'] + 1}: `{f['error']}`" for f in document['failures']]
    return '\n'.join(out) + '\n'


def compare(paths: list[Path]) -> str:
    documents = [json.loads(p.read_text()) for p in paths]
    names = [f"{d['environment']['date'][:16]} {d.get('label') or ''}".strip() for d in documents]
    out = ['# Benchmark comparison across runs', '']
    for d, n in zip(documents, names):
        apps = ', '.join(f"{NAMES.get(k, k)} {v.get('version')}" + (f" ({v['build']})" if v.get('build') else '') for k, v in d['environment']['apps'].items())
        out.append(f"- **{n}**: {apps}; commit `{d['environment']['repo']['commit']}`; power {d['environment']['power']['source']}"
                   + (' ⚠︎' if d['environment']['power'].get('warning') else ''))
    if len({d.get('schema', 1) for d in documents}) > 1:
        out.append('- ⚠︎ Runs use different harness schemas; schema 1 captured whatever the display showed, so its screen content was uncontrolled.')
    out.append('')
    summaries = [d.get('summary') or summarize(d) for d in documents]
    for app in NAMES:
        for scenario in SCENARIOS:
            rows = []
            for _, label, path, unit, _ in METRICS:
                stats = [s.get(app, {}).get(scenario, {}).get(path) for s in summaries]
                if not any(stats): continue
                first, last = stats[0], stats[-1]
                change = f"{(last['median'] - first['median']) / first['median'] * 100:+.0f}%" if first and last and first['median'] else ''
                rows.append(f"| {label}{f' ({unit})' if unit else ''} | " + ' | '.join(cell(s) for s in stats) + f' | {change} |')
            if rows:
                out += [f'## {NAMES[app]} · {title(scenario)}', '', '| Metric | ' + ' | '.join(names) + ' | Change |',
                        '|---|' + '---|' * (len(names) + 1), *rows, '']
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    files = [Path(a) for a in sys.argv[1:]]
    if not files: raise SystemExit(__doc__)
    if len(files) == 1:
        document = json.loads(files[0].read_text())
        document['summary'] = summarize(document)
        print(render(document), end='')
    else:
        print(compare(files), end='')
