"""OBS adapter: isolated fresh config home, generated profile/scene, obs-websocket v5 client.

The user's own OBS configuration (~/Library/Application Support/obs-studio) is never read or
written. OBS is launched through LaunchServices with CFFIXED_USER_HOME pointing at a
benchmark-owned directory, so every config/log/profile path resolves inside that directory.
"""
import base64, ctypes, json, os, plistlib, socket, struct, subprocess, time
from pathlib import Path

BUNDLE_ID = 'com.obsproject.obs-studio'
PORT = 4466  # not the default 4455, so a user's own OBS server is never contacted


def version(app: Path) -> str:
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']


def version_int(text: str) -> int:
    major, minor, patch = (int(x) for x in (text.split('.') + ['0', '0'])[:3])
    return (major << 24) | (minor << 16) | patch


def main_display_uuid() -> str:
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cs = ctypes.CDLL('/System/Library/Frameworks/ColorSync.framework/ColorSync')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg.CGMainDisplayID.restype = ctypes.c_uint32
    cs.CGDisplayCreateUUIDFromDisplayID.restype = ctypes.c_void_p
    cs.CGDisplayCreateUUIDFromDisplayID.argtypes = [ctypes.c_uint32]
    cf.CFUUIDCreateString.restype = ctypes.c_void_p
    cf.CFUUIDCreateString.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    uuid = cs.CGDisplayCreateUUIDFromDisplayID(cg.CGMainDisplayID())
    text = cf.CFUUIDCreateString(None, uuid)
    buffer = ctypes.create_string_buffer(64)
    cf.CFStringGetCString(text, buffer, 64, 0x08000100)
    cf.CFRelease(text); cf.CFRelease(uuid)
    return buffer.value.decode()


def write_home(home: Path, app: Path, workload: dict, media_dir: Path, stream_server: str, stream_key: str) -> dict:
    """Creates a fresh OBS config home matching the StreamApp workload. Returns the settings used."""
    base = home / 'Library/Application Support'
    root = base / 'obs-studio'
    if root.exists():
        raise SystemExit(f'Refusing to reuse OBS bench home {root}; the harness always starts fresh.')
    (root / 'basic/profiles/Bench').mkdir(parents=True)
    (root / 'basic/scenes').mkdir(parents=True)
    media_dir.mkdir(parents=True, exist_ok=True)  # OBS refuses to record into a missing directory
    v = version_int(version(app))
    general = (f'[General]\nFirstRun=true\nLastVersion={v}\nInfoIncrement=999\nInfoLastVersion={v << 16}\n'
               'MacOSPermissionsDialogLastShown=999\nPre19Defaults=false\nPre21Defaults=false\nPre23Defaults=false\n'
               'Pre24.1Defaults=false\nPre31Migrated=true\nEnableAutoUpdates=false\nMaxLogs=4\n')
    (root / 'global.ini').write_text(general + f'\n[Locations]\nConfiguration={base}\nSceneCollections={base}\nProfiles={base}\n')
    (root / 'user.ini').write_text(
        general + 'ConfirmOnExit=false\n\n[Basic]\nProfile=Bench\nProfileDir=Bench\nSceneCollection=Bench\nSceneCollectionFile=Bench\n\n'
        '[BasicWindow]\nSysTrayEnabled=true\nSysTrayWhenStarted=true\nPreviewEnabled=true\nRecordWhenStreaming=false\n'
        'KeepRecordingWhenStreamStops=false\nWarnBeforeStartingStream=false\nWarnBeforeStoppingStream=false\n'
        'WarnBeforeStoppingRecord=false\n')
    # obs-websocket 5.5 reads only its module config file, not user.ini.
    (root / 'plugin_config/obs-websocket').mkdir(parents=True)
    (root / 'plugin_config/obs-websocket/config.json').write_text(json.dumps({
        'first_load': False, 'server_enabled': True, 'server_port': PORT, 'alerts_enabled': False, 'auth_required': False}))
    w = workload
    encoder = {'rate_control': 'CBR', 'bitrate': w['video_kbps'], 'keyint_sec': w['keyframe_seconds'],
               'profile': 'high', 'bframes': False}
    profile = root / 'basic/profiles/Bench'
    (profile / 'basic.ini').write_text(
        '[General]\nName=Bench\n\n[Output]\nMode=Advanced\nReconnect=false\nLowLatencyEnable=false\n\n'
        '[AdvOut]\nApplyServiceSettings=false\nEncoder=com.apple.videotoolbox.videoencoder.ave.avc\nRecEncoder=none\n'
        f'RecType=Standard\nRecFilePath={media_dir}\nRecFormat2=hybrid_mp4\nRecTracks=1\nTrackIndex=1\n'
        f'AudioEncoder=CoreAudio_AAC\nRecAudioEncoder=CoreAudio_AAC\nTrack1Bitrate={w["audio_kbps"]}\n\n'
        f'[Video]\nBaseCX={w["width"]}\nBaseCY={w["height"]}\nOutputCX={w["width"]}\nOutputCY={w["height"]}\n'
        f'FPSType=2\nFPSNum={w["fps"]}\nFPSDen=1\nScaleType=bicubic\nColorFormat=NV12\nColorSpace=709\nColorRange=Partial\n\n'
        f'[Audio]\nSampleRate={w["sample_rate"]}\nChannelSetup=Stereo\n')
    (profile / 'streamEncoder.json').write_text(json.dumps(encoder))
    (profile / 'service.json').write_text(json.dumps({'type': 'rtmp_custom', 'settings': {
        'server': stream_server, 'key': stream_key, 'use_auth': False, 'bwtest': False}}))
    screen = {'id': 'screen_capture', 'versioned_id': 'screen_capture', 'name': 'Display', 'uuid': 'b7a1c0de-0000-4000-8000-000000000001',
              'settings': {'type': 0, 'display_uuid': main_display_uuid(), 'show_cursor': True, 'hide_obs': False},
              'muted': not w['system_audio'], 'volume': 1.0, 'enabled': True}
    scene = {'id': 'scene', 'versioned_id': 'scene', 'name': 'Bench', 'uuid': 'b7a1c0de-0000-4000-8000-000000000002',
             'settings': {'id_counter': 1, 'custom_size': False, 'items': [{
                 'name': 'Display', 'source_uuid': screen['uuid'], 'visible': True, 'locked': True, 'id': 1,
                 'align': 5, 'bounds_type': 2, 'bounds_align': 0, 'bounds': {'x': w['width'], 'y': w['height']},
                 'pos': {'x': 0.0, 'y': 0.0}, 'scale': {'x': 1.0, 'y': 1.0}, 'rot': 0.0}]}}
    collection = {'name': 'Bench', 'current_scene': 'Bench', 'current_program_scene': 'Bench',
                  'scene_order': [{'name': 'Bench'}], 'sources': [screen, scene], 'groups': [],
                  'transitions': [], 'current_transition': 'Cut', 'transition_duration': 0,
                  'resolution': {'x': w['width'], 'y': w['height']}, 'version': 2}
    if w['microphone']:
        collection['AuxAudioDevice1'] = {'id': 'coreaudio_input_capture', 'versioned_id': 'coreaudio_input_capture',
                                         'name': 'Mic/Aux', 'uuid': 'b7a1c0de-0000-4000-8000-000000000003',
                                         'settings': {'device_id': 'default'}, 'volume': 1.0, 'muted': False}
    (root / 'basic/scenes/Bench.json').write_text(json.dumps(collection, indent=1))
    return {'encoder': encoder, 'record_format': 'hybrid_mp4', 'audio_encoder': 'CoreAudio_AAC',
            'renderer': 'default', 'window': 'minimized to tray (preview not drawn)', 'screen_source': screen['settings']}


def launch(app: Path, home: Path) -> tuple[int, int]:
    """Returns (CLOCK_UPTIME_RAW ns just before `open`, new OBS pid)."""
    executable = str(app / 'Contents/MacOS/OBS')
    before = executable_pids(executable)
    started = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
    subprocess.run(['open', '-n', '-g', '-a', str(app),
                    '--env', f'CFFIXED_USER_HOME={home}', '--env', f'HOME={home}',
                    '--args', '--minimize-to-tray', '--disable-updater', '--disable-shutdown-check',
                    '--profile', 'Bench', '--collection', 'Bench'], check=True)
    return started, find_new_pid(executable, before)


def executable_pids(path: str) -> set[int]:
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    return {int(pid) for pid, _, comm in (r.strip().partition(' ') for r in rows) if comm.strip() == path}


def find_new_pid(path: str, before: set[int], timeout: float = 30) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        new = executable_pids(path) - before
        if len(new) == 1: return new.pop()
        if len(new) > 1: raise RuntimeError(f'Several new {path} processes: {sorted(new)}')
        time.sleep(0.02)
    raise TimeoutError(f'{path} did not start')


def quit(pid: int, timeout: float = 30) -> None:
    subprocess.run(['osascript', '-e', f'tell application id "{BUNDLE_ID}" to quit'], capture_output=True, timeout=timeout)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try: os.kill(pid, 0)
        except ProcessLookupError: return
        time.sleep(0.1)
    os.kill(pid, 15)


class WebSocket:
    """Minimal RFC 6455 client (text frames) for obs-websocket v5 without authentication."""

    def __init__(self, port: int = PORT, timeout: float = 30):
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.sock = socket.create_connection(('127.0.0.1', port), timeout=2); break
            except OSError:
                if time.monotonic() > deadline: raise
                time.sleep(0.05)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f'GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                           f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: obswebsocket.json\r\n\r\n').encode())
        header = b''
        while b'\r\n\r\n' not in header:
            chunk = self.sock.recv(1)
            if not chunk: raise ConnectionError('obs-websocket closed during handshake')
            header += chunk
        if b' 101 ' not in header.split(b'\r\n')[0]: raise ConnectionError(header.decode(errors='replace'))
        self.sock.settimeout(None)
        self.events, self.counter = [], 0
        hello = self._recv()
        if hello['op'] != 0: raise ConnectionError(f'unexpected {hello}')
        self._send({'op': 1, 'd': {'rpcVersion': 1, 'eventSubscriptions': 1 << 6}})  # Outputs
        while self._recv()['op'] != 2: pass

    def _send(self, message: dict) -> None:
        payload = json.dumps(message).encode(); mask = os.urandom(4); n = len(payload)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack('!H', n) if n < 65536 else bytes([0x80 | 127]) + struct.pack('!Q', n))
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _exact(self, n: int) -> bytes:
        data = b''
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk: raise ConnectionError('obs-websocket closed')
            data += chunk
        return data

    def _recv(self, timeout: float | None = None) -> dict:
        self.sock.settimeout(timeout)
        try:
            while True:
                b0, b1 = self._exact(2); n = b1 & 0x7F
                if n == 126: n = struct.unpack('!H', self._exact(2))[0]
                elif n == 127: n = struct.unpack('!Q', self._exact(8))[0]
                payload = self._exact(n); opcode = b0 & 0x0F
                if opcode == 1: return json.loads(payload)
                if opcode == 8: raise ConnectionError('obs-websocket closed')
                if opcode == 9: self.sock.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
        finally:
            self.sock.settimeout(None)

    def request(self, kind: str, data: dict | None = None, timeout: float = 30) -> dict:
        self.counter += 1; rid = str(self.counter)
        self._send({'op': 6, 'd': {'requestType': kind, 'requestId': rid, **({'requestData': data} if data else {})}})
        while True:
            m = self._recv(timeout)
            if m['op'] == 5: self.events.append(m['d']); continue
            if m['op'] == 7 and m['d']['requestId'] == rid:
                status = m['d']['requestStatus']
                if not status['result']: raise RuntimeError(f'{kind}: {status}')
                return m['d'].get('responseData', {})

    def wait_ready(self, timeout: float = 60) -> dict:
        """obs-websocket accepts connections before OBS finishes loading (status 207)."""
        deadline = time.monotonic() + timeout
        while True:
            try: return self.request('GetVersion')
            except RuntimeError as error:
                if "'code': 207" not in str(error) or time.monotonic() > deadline: raise
                time.sleep(0.02)

    def wait_output(self, event: str, state: str, timeout: float = 30) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            for i, e in enumerate(self.events):
                if e['eventType'] == event and e['eventData'].get('outputState') == state:
                    return self.events.pop(i)['eventData']
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise TimeoutError(f'{event} {state}')
            m = self._recv(remaining)
            if m['op'] == 5: self.events.append(m['d'])

    def close(self) -> None:
        try: self.sock.close()
        except OSError: pass


class Session:
    """One OBS launch in a fresh home, driven over obs-websocket to mirror a StreamApp bench session."""
    OUTPUTS = {'record': [('Record', 'RecordStateChanged')], 'stream': [('Stream', 'StreamStateChanged')],
               'both': [('Stream', 'StreamStateChanged'), ('Record', 'RecordStateChanged')], 'idle': []}

    def __init__(self, app: Path, directory: Path, scenario: str, settle: float, session_seconds: float, stream_url: str, workload: dict):
        self.app, self.scenario, self.settle, self.seconds = app, scenario, settle, session_seconds
        self.home = directory / 'obs-home'
        self.settings = write_home(self.home, app, workload, directory / 'media', stream_url, 'bench')
        self.pid = 0

    def launch(self) -> tuple[int, int]:
        started, self.pid = launch(self.app, self.home)
        return started, self.pid

    def run(self, timeout: float) -> dict:
        from media import now_ns
        ws = WebSocket(timeout=timeout)
        try:
            ws.wait_ready(timeout)
            events: dict = {'ready': now_ns()}
            time.sleep(self.settle)
            outputs = self.OUTPUTS[self.scenario]
            if not outputs:
                time.sleep(self.seconds)
                return events
            events['start_requested'] = now_ns()
            for kind, event in outputs:
                ws.request(f'Start{kind}')
                ws.wait_output(event, 'OBS_WEBSOCKET_OUTPUT_STARTED')
            events['started'] = now_ns()
            time.sleep(self.seconds)
            stats = {'GetStats': ws.request('GetStats')}
            for kind, _ in outputs: stats[f'Get{kind}Status'] = ws.request(f'Get{kind}Status')
            events['stop_requested'] = now_ns()
            for kind, event in outputs:
                ws.request(f'Stop{kind}')
                data = ws.wait_output(event, 'OBS_WEBSOCKET_OUTPUT_STOPPED')
                if kind == 'Record': events['recording'] = data.get('outputPath')
            events['stopped'] = now_ns()
            events['app_stats'] = stats
            return events
        finally:
            ws.close()
            quit(self.pid)

    def abort(self) -> None:
        if not self.pid: return
        try: os.kill(self.pid, 15)
        except ProcessLookupError: pass
