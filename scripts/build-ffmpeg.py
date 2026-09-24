#!/usr/bin/env python3
"""Build StreamApp's pinned, static FFmpeg command-line dependency."""
from pathlib import Path
import fcntl
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PREFIX = ROOT / '.build/ffmpeg'
SOURCE = PREFIX / 'source'
BUILD = PREFIX / 'build'
OPENSSL = PREFIX / 'openssl'
BIN = PREFIX / 'bin/ffmpeg'
STAMP = PREFIX / 'built.json'
URL = 'https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz'
SHA256 = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
VERSION = '9.0.2'
TARGET = '26.0'

# Keep this list deliberately explicit: these are the components used by MediaOutput.
CONFIG = [
    '--disable-everything', '--disable-autodetect', '--disable-doc', '--disable-ffplay',
    '--disable-ffprobe', '--disable-avdevice', '--enable-static', '--disable-shared',
    '--enable-version3', '--enable-pthreads', '--enable-network', '--enable-openssl',
    # Inputs: StreamApp's timestamped H.264 FLV fifo and interleaved float PCM fifo.
    # Stream copy still opens the H.264 decoder to read dimensions from the AVC extradata.
    '--enable-demuxer=flv,pcm_f32le', '--enable-decoder=h264,pcm_f32le', '--enable-parser=h264',
    # Output: AAC audio, stream-copied video, tee to MP4/Matroska and an RTMP(S) fifo.
    '--enable-encoder=aac', '--enable-muxer=mp4,matroska,flv,tee,fifo',
    '--enable-protocol=file,pipe,tcp,tls,rtmp,rtmps',
    '--enable-filter=abuffer,abuffersink,aformat,aresample,anull,atrim',
    '--enable-swresample', '--disable-swscale', '--disable-debug', '--pkg-config=false',
]

def run(*args, cwd=None, env=None, capture=True):
    try:
        result = subprocess.run(args, cwd=cwd or ROOT, env=env, text=True,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.STDOUT if capture else None,
                                check=True)
        return result.stdout or ''
    except (OSError, subprocess.CalledProcessError) as error:
        output = getattr(error, 'stdout', '') or ''
        raise SystemExit(f'FFmpeg bootstrap failed: {args[0]}: {output}') from error

def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

PREFIX.mkdir(parents=True, exist_ok=True)
with (PREFIX / 'build.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('The StreamApp FFmpeg bootstrap targets native arm64 macOS only.')
    brew_prefix = Path(run('brew', '--prefix', 'openssl@3').strip())
    compiler = run('xcrun', 'clang', '--version')
    script_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    # OpenSSL is linked statically: any openssl@3 upgrade (security fixes) must rebuild FFmpeg.
    openssl = {name: sha256(brew_prefix / 'lib' / name) for name in ('libssl.a', 'libcrypto.a')
               if (brew_prefix / 'lib' / name).is_file()}
    identity = {'version': VERSION, 'sha256': SHA256, 'architecture': platform.machine(),
                'compiler': compiler, 'deployment_target': TARGET, 'configure': CONFIG,
                'openssl': openssl, 'script': script_hash}
    cached = json.loads(STAMP.read_text()) if STAMP.exists() else None
    if cached == identity and BIN.is_file() and (PREFIX / 'ThirdParty/provenance.json').is_file():
        print('FFmpeg dependency is current (no download or compilation).')
        sys.exit(0)

    archive = PREFIX / 'ffmpeg-9.0.2.tar.xz'
    if not archive.exists():
        print(f'Downloading {URL}...')
        urllib.request.urlretrieve(URL, archive)
    actual = sha256(archive)
    if actual != SHA256:
        raise SystemExit(f'FFmpeg source checksum mismatch: expected {SHA256}, got {actual}')
    if not SOURCE.exists():
        SOURCE.mkdir()
        run('tar', '-xf', str(archive), '-C', str(SOURCE))
        extracted = SOURCE / 'ffmpeg-9.0.2'
        if not extracted.is_dir():
            raise SystemExit('Unexpected FFmpeg source archive layout.')
        extracted.rename(SOURCE / 'src')
    if BUILD.exists() and cached != identity:
        shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True, exist_ok=True)

    # A private search directory containing only the static OpenSSL archives prevents
    # configure/link from accidentally selecting dylibs or unrelated Homebrew libs.
    if OPENSSL.exists():
        shutil.rmtree(OPENSSL)
    OPENSSL.mkdir()
    for name in ('libssl.a', 'libcrypto.a'):
        source = brew_prefix / 'lib' / name
        if not source.is_file():
            raise SystemExit(f'Missing static OpenSSL archive: {source}; brew install openssl@3')
        shutil.copy2(source, OPENSSL / name)
    env = {**os.environ, 'MACOSX_DEPLOYMENT_TARGET': TARGET}
    configure = [str(SOURCE / 'src/configure'), '--prefix=' + str(PREFIX), '--arch=arm64',
                 '--cc=clang', f'--extra-cflags=-I{brew_prefix / "include"}',
                 f'--extra-ldflags=-L{OPENSSL} -Wl,-search_paths_first -Wl,-dead_strip -Wl,-dead_strip_dylibs',
                 *CONFIG]
    config_out = run(*configure, cwd=BUILD, env=env)
    print(config_out, end='')
    run('make', '-j', str(os.cpu_count() or 2), 'ffmpeg', cwd=BUILD, env=env)
    run('make', 'install-progs', cwd=BUILD, env=env)
    if not BIN.is_file():
        raise SystemExit('FFmpeg build did not produce .build/ffmpeg/bin/ffmpeg')
    version = run(str(BIN), '-version')
    # Confirm this is truly self-contained before packaging it.
    deps = run('otool', '-L', str(BIN))
    for line in deps.splitlines()[1:]:
        dep = line.strip().split(' (', 1)[0]
        if dep and not dep.startswith(('/usr/lib/', '/System/')):
            raise SystemExit(f'Built FFmpeg has non-system dependency: {dep}')
    notices = PREFIX / 'ThirdParty'
    notices.mkdir(exist_ok=True)
    for name in ('COPYING.LGPLv3', 'COPYING.LGPLv2.1', 'LICENSE.md'):
        source = SOURCE / 'src' / name
        if source.is_file():
            shutil.copy2(source, notices / name)
    ssl_license = brew_prefix / 'share/openssl@3/LICENSE.txt'
    if not ssl_license.is_file():
        ssl_license = brew_prefix / 'LICENSE.txt'
    if ssl_license.is_file():
        shutil.copy2(ssl_license, notices / 'OpenSSL-LICENSE.txt')
    (notices / 'ffmpeg-build.txt').write_text(version)
    provenance = {**identity, 'source_url': URL, 'openssl_prefix': str(brew_prefix),
                  'openssl_archives': ['libssl.a', 'libcrypto.a'], 'configure_output': config_out}
    (notices / 'provenance.json').write_text(json.dumps(provenance, indent=2))
    STAMP.write_text(json.dumps(identity, indent=2))
    print(f'Built static FFmpeg: {BIN}')
