#!/usr/bin/env python3
"""StreamApp vs OBS runtime benchmark: same workload, same machine, interleaved repeated trials.

    python3 bench/run.py                                   # 3 reps × 7 scenarios × both apps (~45 min)
    python3 bench/run.py --scenarios record,record-motion --repeat 5 --label rc2
    python3 bench/report.py bench/results/A/results.json bench/results/B/results.json   # compare runs

Each trial: cooldown → machine baseline (stimulus on, app off) → launch through LaunchServices →
ready → settle → start → warmup → measured window → stop → quit. Resource samples come from
bench/probe (app process tree + responsible helpers, GPU, IOReport energy); latency comes from
bench/stimulus and a loopback RTMP receiver. See docs/benchmarks.md.
"""
import argparse, datetime, json, os, platform, signal, statistics, subprocess, sys, time, traceback
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import media, obs, report, rtmp, streamapp  # noqa: E402

TOOLS = ROOT / '.build/bench'
ADAPTERS = {'streamapp': streamapp, 'obs': obs}
# Base scenario, optionally with '-motion': the stimulus scrolls noise across the whole display so every
# captured frame changes. Without it the display shows a static grey cover plus the flip square.
SCENARIOS = ('idle', 'record', 'stream', 'both', 'record-motion', 'stream-motion', 'both-motion')
WORKLOAD = {'width': 1920, 'height': 1080, 'fps': 30, 'video_kbps': 6000, 'keyframe_seconds': 2,
            'audio_kbps': 160, 'sample_rate': 48000, 'system_audio': True, 'microphone': False,
            'encoder': 'VideoToolbox H.264 High, CBR, no B-frames', 'capture': 'main display, cursor shown, fitted to 1920x1080',
            'recording': 'fragmented/hybrid MP4', 'extras': 'no camera, chat, overlays or filters'}


def sh(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def build_tools() -> None:
    TOOLS.mkdir(parents=True, exist_ok=True)
    for name in ('probe', 'stimulus'):
        source, binary = HERE / f'{name}.swift', TOOLS / name
        if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
            subprocess.run(['xcrun', 'swiftc', '-O', '-suppress-warnings', str(source), '-o', str(binary)], check=True)


def environment(apps: dict) -> dict:
    battery = sh('pmset', '-g', 'batt')
    low_power = any(l.split()[-1:] == ['1'] for l in sh('pmset', '-g').splitlines() if 'lowpowermode' in l)
    displays = json.loads(sh('system_profiler', 'SPDisplaysDataType', '-json') or '{}')
    screens = [{k: d.get(k) for k in ('_name', '_spdisplays_resolution', '_spdisplays_pixels', 'spdisplays_main')}
               for gpu in displays.get('SPDisplaysDataType', []) for d in gpu.get('spdisplays_ndrvs', [])]
    return {
        'date': datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
        'machine': {'model': sh('sysctl', '-n', 'hw.model'), 'cpu': sh('sysctl', '-n', 'machdep.cpu.brand_string'),
                    'cores': os.cpu_count(), 'memory_gb': int(sh('sysctl', '-n', 'hw.memsize')) // 2**30,
                    'macos': f"{platform.mac_ver()[0]} ({sh('sw_vers', '-buildVersion')})", 'displays': screens},
        'power': {'source': 'AC' if "'AC Power'" in battery else 'battery', 'battery': battery.splitlines()[-1].strip() if battery else None,
                  'low_power_mode': low_power, 'thermal': sh('pmset', '-g', 'therm').splitlines()[1:]},
        'repo': {'commit': sh('git', '-C', str(ROOT), 'rev-parse', '--short', 'HEAD'),
                 'dirty_files': len(sh('git', '-C', str(ROOT), 'status', '--porcelain').splitlines())},
        'apps': apps,
        'tools': {'ffmpeg_receiver': sh(media.FFMPEG, '-version').splitlines()[0]},
    }


def app_info(name: str, path: Path) -> dict:
    info = streamapp.version(path) if name == 'streamapp' else {'version': obs.version(path)}
    return {'path': str(path), 'bundle_mb': round(int(sh('du', '-sk', str(path)).split()[0]) / 1024, 1), **info}


class Probe:
    def __init__(self, path: Path, roots: list[int], interval: float):
        self.path = path
        self.handle = open(path, 'wb')
        args = [str(TOOLS / 'probe'), '--interval', str(interval)]
        for pid in roots: args += ['--root', str(pid)]
        self.process = subprocess.Popen(args, stdout=self.handle)

    def stop(self) -> list[dict]:
        self.process.send_signal(signal.SIGTERM); self.process.wait(10); self.handle.close()
        return [json.loads(l) for l in self.path.read_text().splitlines() if l.strip()]


def window(samples: list[dict], t0: int, t1: int) -> dict | None:
    """Rates between the first and last samples inside [t0, t1]; processes born inside count fully."""
    inside = [s for s in samples if t0 <= s['t_ns'] <= t1]
    if len(inside) < 2: return None
    a, b = inside[0], inside[-1]
    seconds = (b['t_ns'] - a['t_ns']) / 1e9
    before = {p['pid']: p for p in a['procs']}
    names: dict = defaultdict(lambda: defaultdict(float))
    for p in b['procs']:
        q = before.get(p['pid'], {})
        d = lambda key: max(0, p[key] - q.get(key, 0))
        row = names[p['name']]
        row['cpu_percent'] += (d('user_ns') + d('system_ns')) / seconds / 1e7
        row['gpu_ms_per_s'] += d('gpu_ns') / seconds / 1e6
        row['energy_mw'] += d('energy_nj') / seconds / 1e6
        row['instructions_g_per_s'] += d('instructions') / seconds / 1e9
        row['wakeups_per_s'] += (d('idle_wakeups') + d('interrupt_wakeups')) / seconds
        row['footprint_mb_max'] = max(row['footprint_mb_max'], max(
            (x['footprint'] for s in inside for x in s['procs'] if x['pid'] == p['pid']), default=0) / 2**20)
    totals = {k: round(sum(r[k] for r in names.values()), 3) for k in
              ('cpu_percent', 'gpu_ms_per_s', 'energy_mw', 'instructions_g_per_s', 'wakeups_per_s')}
    footprints = [sum(p['footprint'] for p in s['procs']) / 2**20 for s in inside]
    ticks = [y - x for x, y in zip(a['host_ticks'], b['host_ticks'])]
    busy, total = ticks[0] + ticks[1] + ticks[3], sum(ticks)
    gpu_energy = b['energy_nj'].get('GPU Energy', 0) - a['energy_nj'].get('GPU Energy', 0)
    return {'seconds': round(seconds, 3), **totals,
            'footprint_mb_mean': round(statistics.fmean(footprints), 1), 'footprint_mb_max': round(max(footprints), 1),
            'host_cpu_cores': round(busy / total * (os.cpu_count() or 1), 3) if total else None,
            'gpu_energy_mw': round(gpu_energy / seconds / 1e6, 1),
            'windowserver_gpu_ms_per_s': round((b['windowserver_gpu_ns'] - a['windowserver_gpu_ns']) / seconds / 1e6, 2),
            'processes': {n: {k: round(v, 3) for k, v in r.items()} for n, r in sorted(names.items())}}


def launch_cost(samples: list[dict], ready: int) -> dict | None:
    """Cumulative work from process creation to the first sample at/after ready."""
    after = [s for s in samples if s['t_ns'] >= ready]
    if not after: return None
    s = after[0]
    return {'cpu_ms': round(sum(p['user_ns'] + p['system_ns'] for p in s['procs']) / 1e6, 1),
            'footprint_mb': round(sum(p['footprint'] for p in s['procs']) / 2**20, 1),
            'processes': len(s['procs'])}


def ms(a: int | None, b: int | None) -> float | None:
    return round((b - a) / 1e6, 1) if a and b else None


def trial(args, name: str, app: Path, scenario: str, rep: int, directory: Path) -> dict:
    base, _, content = scenario.partition('-')
    directory.mkdir(parents=True)
    stimulus_log = directory / 'stimulus.jsonl'
    session_seconds = args.warmup + args.seconds
    stimulus = receiver = None
    try:
        # Always cover the display so trials capture identical content; idle needs no tone.
        stimulus = subprocess.Popen([str(TOOLS / 'stimulus'), '--events', str(stimulus_log), '--seed', str(1000 + rep)]
                                    + (['--no-audio'] if args.no_tone or base == 'idle' else [])
                                    + (['--motion'] if content == 'motion' else []))
        time.sleep(1)
        baseline_probe = Probe(directory / 'baseline.jsonl', [], args.interval)
        time.sleep(args.baseline)
        baseline_samples = baseline_probe.stop()
        baseline = window(baseline_samples, 0, 2**63)
        if base in ('stream', 'both'): receiver = rtmp.Receiver(directory)
        session = ADAPTERS[name].Session(app, directory, base, args.settle, session_seconds if base != 'idle' else args.seconds,
                                         f'rtmp://127.0.0.1:{media.RTMP_PORT}/live', WORKLOAD)
        launched, pid = session.launch()
        probe = Probe(directory / 'samples.jsonl', [pid], args.interval)
        try:
            events = session.run(timeout=120 + args.settle + session_seconds)
        except BaseException:
            session.abort(); raise
        finally:
            time.sleep(args.interval * 2)
            samples = probe.stop()
        events['launched'] = launched
    finally:
        if stimulus: stimulus.send_signal(signal.SIGTERM); stimulus.wait(10)
        if receiver: receiver.close()

    ready = events['ready']
    if base == 'idle':
        t0, t1 = ready + int(args.settle * 1e9), ready + int((args.settle + args.seconds) * 1e9)
    else:
        t0, t1 = events['started'] + int(args.warmup * 1e9), events['stop_requested']
    measured = window(samples, t0, t1)
    result = {
        'app': name, 'scenario': scenario, 'rep': rep, 'raw': str(directory.relative_to(ROOT)) if directory.is_relative_to(ROOT) else str(directory),
        'timings': {'launch_to_ready_ms': ms(launched, ready), 'start_ms': ms(events.get('start_requested'), events.get('started')),
                    'stop_ms': ms(events.get('stop_requested'), events.get('stopped'))},
        'launch': launch_cost(samples, ready), 'window': measured, 'baseline': baseline and {k: v for k, v in baseline.items() if k != 'processes'},
        'app_stats': events.get('app_stats'),
    }
    if measured and baseline:
        result['above_baseline'] = {k: round(measured[k] - baseline[k], 3) for k in ('host_cpu_cores', 'gpu_energy_mw', 'windowserver_gpu_ms_per_s')}
    if events.get('recording'):
        recording = Path(events['recording'])
        result['recording'] = {'file': recording.name, **media.facts(recording)}
        if base != 'idle': result['recording']['av_offset'] = media.av_offset(recording, stimulus_log)
    if receiver: result['stream'] = receiver.latency(stimulus_log, events.get('start_requested'))
    return result


def precheck(args, apps: dict) -> list[str]:
    problems = []
    for name, path in apps.items():
        executable = path / 'Contents/MacOS' / ('StreamApp' if name == 'streamapp' else 'OBS')
        if not executable.exists(): problems.append(f'{name}: {executable} not found')
    for process in ('StreamApp', 'OBS'):
        if subprocess.run(['pgrep', '-x', process], capture_output=True).returncode == 0 and not args.allow_running:
            problems.append(f'{process} is already running; quit it (or pass --allow-running) so trials do not contend')
    # coreaudiod holds an 'audio-out' assertion while anything plays; that audio would mix into the
    # captured system audio and break the stimulus-tone A/V measurement.
    if 'audio-out' in sh('pmset', '-g', 'assertions') and not args.allow_audio:
        problems.append('Audio is playing on this Mac; pause it (or pass --allow-audio) so it does not mix into the captured system audio')
    return problems


def main() -> None:
    def interrupted(number, frame): raise KeyboardInterrupt(signal.Signals(number).name)
    for number in (signal.SIGTERM, signal.SIGHUP): signal.signal(number, interrupted)  # run abort/cleanup paths
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--apps', default='streamapp,obs')
    p.add_argument('--scenarios', default=','.join(SCENARIOS))
    p.add_argument('--repeat', type=int, default=3)
    p.add_argument('--seconds', type=float, default=30, help='measured window per trial')
    p.add_argument('--warmup', type=float, default=5, help='session time excluded before the window')
    p.add_argument('--settle', type=float, default=5, help='idle time after ready before starting')
    p.add_argument('--baseline', type=float, default=10, help='machine baseline before each launch')
    p.add_argument('--cooldown', type=float, default=10)
    p.add_argument('--interval', type=float, default=0.5, help='probe sampling interval')
    p.add_argument('--streamapp', type=Path, default=next((x for x in (ROOT / 'StreamApp.app', Path.home() / 'Applications/StreamApp.app') if x.exists()), ROOT / 'StreamApp.app'))
    p.add_argument('--obs', type=Path, default=Path('/Applications/OBS.app'))
    p.add_argument('--label', default='')
    p.add_argument('--out', type=Path, default=HERE / 'results')
    p.add_argument('--no-tone', action='store_true', help='silent stimulus (no A/V offset measurement)')
    p.add_argument('--allow-unstable-power', action='store_true', help='run on battery / Low Power Mode and flag the results')
    p.add_argument('--allow-running', action='store_true')
    p.add_argument('--allow-audio', action='store_true', help='run while other audio plays (A/V offsets become unreliable)')
    args = p.parse_args()
    names = [n.strip() for n in args.apps.split(',') if n.strip()]
    scenarios = [s.strip() for s in args.scenarios.split(',') if s.strip()]
    if unknown := [n for n in names if n not in ADAPTERS] + [s for s in scenarios if s not in SCENARIOS]:
        raise SystemExit(f'Unknown app/scenario: {unknown}')
    apps = {n: (args.streamapp if n == 'streamapp' else args.obs).resolve() for n in names}
    if problems := precheck(args, apps): raise SystemExit('\n'.join(problems))
    build_tools()
    env = environment({n: app_info(n, path) for n, path in apps.items()})
    power = env['power']
    if power['source'] != 'AC' or power['low_power_mode']:
        warning = f"Unstable power conditions: {power['source']}, Low Power Mode {'on' if power['low_power_mode'] else 'off'}"
        if not args.allow_unstable_power: raise SystemExit(warning + ' — connect AC and disable Low Power Mode, or pass --allow-unstable-power.')
        env['power']['warning'] = warning
        print('WARNING:', warning, file=sys.stderr)

    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + (f'-{args.label}' if args.label else '')
    raw = ROOT / '.build/bench/runs' / stamp
    out = args.out / stamp
    out.mkdir(parents=True)
    config = {k: (str(v) if isinstance(v, Path) else v) for k, v in vars(args).items()}
    # schema 2: the stimulus covers the whole display in every scenario; '-motion' scenarios added
    document = {'schema': 2, 'label': args.label, 'environment': env, 'workload': WORKLOAD, 'config': config, 'trials': [], 'failures': []}
    if {'stream', 'both'} & {s.partition('-')[0] for s in scenarios}:
        print('Calibrating loopback receiver…', flush=True)
        env['receiver_floor'] = rtmp.calibrate(raw / 'calibration')
    plan = [(rep, scenario, name) for rep in range(args.repeat) for scenario in scenarios
            for name in (names if rep % 2 == 0 else names[::-1])]  # alternate order to cancel drift
    for index, (rep, scenario, name) in enumerate(plan, 1):
        time.sleep(args.cooldown if index > 1 else 0)
        print(f'[{index}/{len(plan)}] {name} {scenario} rep {rep + 1}', flush=True)
        try:
            result = trial(args, name, apps[name], scenario, rep, raw / f'{index:03d}-{name}-{scenario}-{rep + 1}')
            document['trials'].append(result)
            w = result['window'] or {}
            print(f"    cpu {w.get('cpu_percent')}%  gpu {w.get('gpu_ms_per_s')} ms/s  footprint {w.get('footprint_mb_mean')} MB", flush=True)
        except Exception as error:
            traceback.print_exc()
            document['failures'].append({'app': name, 'scenario': scenario, 'rep': rep, 'error': repr(error)})
        (out / 'results.json').write_text(json.dumps(document, indent=1))
    document['summary'] = report.summarize(document)
    (out / 'results.json').write_text(json.dumps(document, indent=1))
    (out / 'report.md').write_text(report.render(document))
    print(f'\nResults: {out / "results.json"}\nReport:  {out / "report.md"}\nRaw:     {raw}')


if __name__ == '__main__':
    main()
