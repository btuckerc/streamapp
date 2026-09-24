#!/usr/bin/env python3
"""Build pinned WebRTC/Abseil once; the Swift target compiles our C ABI bridge."""
from pathlib import Path
import fcntl
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
AEC = ROOT / '.build/aec'
SOURCE = AEC / 'source'
BUILD = AEC / 'build'
LIB = AEC / 'lib/libstreamapp_aec.a'
COMMIT = '846fe90a289f58b7c9303a635142aa2c7caa93e5'
REPOSITORY = 'https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git'
ABSEIL = SOURCE / 'subprojects/abseil-cpp-20240722.0'
BUILD_ENV = {**os.environ, "MACOSX_DEPLOYMENT_TARGET": "26.0"}

def run(*args, cwd=None):
    try:
        return subprocess.check_output(args, cwd=cwd or ROOT, text=True, stderr=subprocess.STDOUT, env=BUILD_ENV)
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'AEC bootstrap failed: {args[0]}: {getattr(error, "output", "") or error}') from error
AEC.mkdir(parents=True, exist_ok=True)
# Two simultaneous app builds must not share a half-written dependency archive.
with (AEC / 'build.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    identity = {'commit': COMMIT, 'architecture': platform.machine(),
                'compiler': run('xcrun', 'clang++', '--version'),
                'deployment_target': '26.0',
                'script': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    stamp = AEC / 'built.json'
    cached = json.loads(stamp.read_text()) if stamp.exists() else None
    if (cached == identity and LIB.is_file() and (SOURCE / 'webrtc/api/audio/audio_processing.h').is_file()
            and (ABSEIL / 'absl/base/config.h').is_file() and (AEC / 'ThirdParty/provenance.json').is_file()):
        print('AEC dependency is current (no download or compilation).')
        sys.exit(0)
    if platform.system() != 'Darwin':
        raise SystemExit('The StreamApp AEC bootstrap currently targets native macOS builds.')
    meson = shutil.which('meson')
    uvx = shutil.which('uvx')
    command = [meson] if meson else ([uvx, '--from', 'meson==1.12.1', 'meson'] if uvx else None)
    if not command or not shutil.which('ninja'):
        raise SystemExit('Install AEC build prerequisites: brew install meson ninja')
    if not SOURCE.exists():
        SOURCE.mkdir()
        run('git', 'init', str(SOURCE))
        run('git', 'fetch', '--depth', '1', REPOSITORY, COMMIT, cwd=SOURCE)
        run('git', 'checkout', '--detach', 'FETCH_HEAD', cwd=SOURCE)
    if run('git', 'rev-parse', 'HEAD', cwd=SOURCE).strip() != COMMIT:
        raise SystemExit(f'AEC source does not match pinned commit; inspect {SOURCE} before rebuilding.')
    if BUILD.exists() and cached != identity:
        # Generated, precisely scoped dependency output only; never source/user files.
        shutil.rmtree(BUILD)
    if not (BUILD / 'build.ninja').exists():
        print(run(*command, 'setup', str(BUILD), str(SOURCE), '--buildtype=release',
                  '--default-library=static', '--wrap-mode=forcefallback'), end='')
    print(run('ninja', '-C', str(BUILD), '-j', str(min(os.cpu_count() or 2, 6))), end='')
    archives = sorted(BUILD.rglob('*.a'))
    if not archives or not (ABSEIL / 'absl/base/config.h').is_file():
        raise SystemExit('AEC dependency build did not produce its libraries and pinned Abseil headers.')
    LIB.parent.mkdir(exist_ok=True)
    temporary = LIB.with_suffix('.tmp.a')
    run('xcrun', 'libtool', '-static', '-o', str(temporary), *(str(p) for p in archives))
    temporary.replace(LIB)
    notices = AEC / 'ThirdParty'
    notices.mkdir(exist_ok=True)
    for name in ('COPYING', 'AUTHORS'):
        shutil.copy2(SOURCE / name, notices / ('WebRTC-' + name))
    for source in (SOURCE / 'webrtc').rglob('*'):
        if source.is_file() and source.name in {'LICENSE', 'COPYING', 'PATENTS', 'AUTHORS', 'NOTICE'}:
            destination = notices / 'WebRTC' / source.relative_to(SOURCE / 'webrtc')
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    shutil.copy2(ABSEIL / 'LICENSE', notices / 'Abseil-LICENSE')
    shutil.copy2(SOURCE / 'subprojects/abseil-cpp.wrap', notices / 'abseil-cpp.wrap')
    (notices / 'provenance.json').write_text(json.dumps({**identity, 'repository': REPOSITORY,
        'tag': 'v2.1', 'abseil': '20240722.0', 'configuration': 'Meson release/static; pinned wrap checksum validation'}, indent=2))
    stamp.write_text(json.dumps(identity, indent=2))
    print(f'Built static AEC dependency: {LIB}')
