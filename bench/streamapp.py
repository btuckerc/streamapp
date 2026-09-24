"""StreamApp adapter: launches the bundle through LaunchServices (so its own screen/audio grants
apply, as for a user launch) in `--bench` mode, which uses the non-persisting demo model with a
real main-display session and reports CLOCK_UPTIME_RAW events as `BENCH {json}` stdout lines."""
import json, os, plistlib, subprocess, time
from pathlib import Path

from media import now_ns
from obs import executable_pids, find_new_pid

NAME = 'StreamApp'


def version(app: Path) -> dict:
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    ffmpeg = subprocess.run([str(app / 'Contents/MacOS/ffmpeg'), '-version'], capture_output=True, text=True).stdout
    return {'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
            'bundle_id': info.get('CFBundleIdentifier'), 'ffmpeg': ffmpeg.splitlines()[0] if ffmpeg else None}


class Session:
    def __init__(self, app: Path, directory: Path, scenario: str, settle: float, session_seconds: float, stream_url: str, workload: dict):
        self.app, self.directory, self.scenario = app, directory, scenario
        self.stdout = directory / 'streamapp.out'
        self.args = ['--bench', str(directory / 'media'), '--bench-delay', str(settle), '--bench-seconds', str(session_seconds)]
        if scenario == 'idle': self.args.append('--bench-idle')
        if scenario == 'stream': self.args.append('--bench-no-record')
        if scenario in ('stream', 'both'): self.args += ['--bench-rtmp', stream_url, '--bench-stream-key', 'bench']
        if workload['microphone']: self.args.append('--bench-microphone')
        if not workload['system_audio']: self.args.append('--bench-no-system-audio')
        self.pid = 0

    def launch(self) -> tuple[int, int]:
        executable = str(self.app / 'Contents/MacOS/StreamApp')
        before = executable_pids(executable)
        started = now_ns()
        subprocess.run(['open', '-n', '-g', '-a', str(self.app), '--stdout', str(self.stdout),
                        '--stderr', str(self.directory / 'streamapp.err'), '--args', *self.args], check=True)
        self.pid = find_new_pid(executable, before)
        return started, self.pid

    def run(self, timeout: float) -> dict:
        """Waits for the self-timed session to finish and the app to exit."""
        deadline = time.monotonic() + timeout
        events: dict = {}
        while time.monotonic() < deadline:
            text = self.stdout.read_text() if self.stdout.exists() else ''
            for line in text.splitlines():
                if line.startswith('BENCH '):
                    record = json.loads(line[6:])
                    events[record['event']] = record
            if 'failed' in events: raise RuntimeError(f"StreamApp bench failed: {events['failed'].get('error')}")
            if ('done' in events or 'stopped' in events) and not _alive(self.pid): break
            time.sleep(0.05)
        else:
            raise TimeoutError('StreamApp bench session did not finish')
        stopped = events.get('stopped', {})
        return {
            'ready': events['ready']['t_ns'],
            'start_requested': events.get('start_requested', {}).get('t_ns'),
            'started': events.get('start_returned', {}).get('t_ns'),
            'stop_requested': events.get('stop_requested', {}).get('t_ns'),
            'stopped': stopped.get('t_ns'),
            'recording': stopped.get('recording'),
            'app_stats': {'encoded_frames_reported': stopped.get('frames'), 'media_seconds_reported': stopped.get('media_seconds')}
                         if stopped else {},
        }

    def abort(self) -> None:
        if self.pid and _alive(self.pid):
            os.kill(self.pid, 15)


def _alive(pid: int) -> bool:
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False
