#!/usr/bin/env python3
"""Build the local macOS application and package its static FFmpeg dependency."""
import argparse
import os
from pathlib import Path
import re
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--identity', help='Optional Apple signing identity; defaults to the local pin or - for an ad-hoc build')
parser.add_argument('--install', action='store_true', help='Install the verified bundle into ~/Applications')
parser.add_argument('--release', action='store_true', help='Build a notarization-ready Developer ID bundle without installing or changing the local signing pin')
parser.add_argument('--version', help='Release marketing version (X.Y.Z)')
parser.add_argument('--build-number', help='Release build number (positive integer)')
parser.add_argument('--output', help='Absolute fresh .app output path for a release build')
a = parser.parse_args()

if a.release:
    if not a.version or not re.fullmatch(r'\d+\.\d+\.\d+', a.version):
        parser.error('--release requires --version X.Y.Z')
    if not a.build_number or not a.build_number.isdigit() or int(a.build_number) <= 0:
        parser.error('--release requires --build-number as a positive integer')
    if not a.output or not Path(a.output).is_absolute() or not a.output.endswith('.app'):
        parser.error('--release requires an absolute --output path ending in .app')
    if a.install:
        parser.error('--install cannot be used with --release')
elif any(value is not None for value in (a.version, a.build_number, a.output)):
    parser.error('--version, --build-number, and --output require --release')
if a.release and os.path.lexists(a.output):
    raise SystemExit(f'Refusing to replace existing release output: {a.output}')
if a.release:
    Path(a.output).parent.mkdir(parents=True, exist_ok=True)

def run(*args):
    try:
        return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.output.rstrip() or f'{args[0]} failed ({error.returncode})') from error


# Local builds need no certificate; retain an existing pin unless explicitly overridden.
# Release builds require Developer ID and never read or write the development pin.
pin = ROOT / '.local/macos-signing-identity'
requested = a.identity or os.environ.get('APPLE_SIGNING_IDENTITY')
if a.release:
    if not requested or requested == '-':
        raise SystemExit('Release builds require --identity Developer ID Application (name or SHA-1).')
    identities = re.findall(r'\d+\) ([A-Fa-f0-9]{40}) "(Developer ID Application:[^"]+)"',
                            run('security', 'find-identity', '-v', '-p', 'codesigning'))
    matches = [(key, name) for key, name in identities if requested in (key, name)]
    if len(matches) != 1:
        raise SystemExit('Selected Developer ID Application identity unavailable or ambiguous.')
    requested = matches[0][0]
else:
    pinned = pin.read_text().strip() if pin.exists() else None
    requested = requested or pinned or '-'
    if requested != '-':
        identities = re.findall(r'\d+\) ([A-Fa-f0-9]{40}) "((?:Apple Development:|Developer ID Application:)[^"]+)"',
                                run('security', 'find-identity', '-v', '-p', 'codesigning'))
        matches = [(key, name) for key, name in identities if requested in (key, name)]
        if len(matches) != 1:
            raise SystemExit('Selected signing identity unavailable or ambiguous; specify its SHA-1 fingerprint or use --identity - for a local ad-hoc build.')
        requested = matches[0][0]
        if pinned and pinned != requested:
            raise SystemExit('Identity differs from the local pin. Migrate signing intentionally before rebuilding.')
        pin.parent.mkdir(exist_ok=True)
        pin.write_text(requested + '\n')
a.identity = requested
print(run('python3', str(ROOT / 'scripts/build-aec.py')), end='')
print(run('python3', str(ROOT / 'scripts/build-ffmpeg.py')), end='')
print(run('swift', 'build', '-c', 'release'), end='')
binary_dir = Path(run('swift', 'build', '-c', 'release', '--show-bin-path').strip())
ffmpeg = ROOT / '.build/ffmpeg/bin/ffmpeg'
if not ffmpeg.is_file():
    raise SystemExit('Static FFmpeg bootstrap did not produce .build/ffmpeg/bin/ffmpeg')
ffmpeg_config = run(str(ffmpeg), '-version')
if a.release and '--enable-nonfree' in ffmpeg_config:
    raise SystemExit('Release refused: this FFmpeg enables nonfree components; use a redistributable build.')
if a.release and Path(a.output).exists():
    raise SystemExit(f'Refusing to replace existing release output: {a.output}')
app = Path(a.output) if a.release else ROOT / 'StreamApp.app'
staging = (Path(tempfile.mkdtemp(prefix='streamapp-release-', dir=ROOT / '.build')) / 'StreamApp.app'
           if a.release else ROOT / '.build/StreamApp-staging.app')
if staging.exists():
    shutil.rmtree(staging)
macos = staging / 'Contents/MacOS'
resources = staging / 'Contents/Resources'
for path in (macos, resources):
    path.mkdir(parents=True, exist_ok=True)
# Strip the shipped copy only; keep a dSYM from the unstripped build for crash symbolication.
run('xcrun', 'dsymutil', str(binary_dir / 'StreamApp'), '-o', str(ROOT / '.build/StreamApp.dSYM'))
shutil.copy2(binary_dir / 'StreamApp', macos / 'StreamApp')
run('xcrun', 'strip', str(macos / 'StreamApp'))
shutil.copy2(ffmpeg, macos / 'ffmpeg')
for bundle in binary_dir.glob('*.bundle'):
    shutil.copytree(bundle, resources / bundle.name)
    # SwiftPM executable resource accessor checks beside the executable as well.
    os.symlink('../Resources/' + bundle.name, macos / bundle.name)
run('swift', str(ROOT / 'scripts/make-icon.swift'), str(ROOT / '.build/StreamApp.iconset'))
run('iconutil', '-c', 'icns', str(ROOT / '.build/StreamApp.iconset'), '-o', str(resources / 'StreamApp.icns'))

info = {
    'CFBundleName': 'StreamApp', 'CFBundleDisplayName': 'StreamApp',
    'CFBundleIdentifier': 'dev.streamapp.studio', 'CFBundleExecutable': 'StreamApp',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': a.version if a.release else '1.3.0',
    'CFBundleVersion': a.build_number if a.release else '9',
    'CFBundleIconFile': 'StreamApp.icns',
    'LSMinimumSystemVersion': '26.0', 'LSUIElement': True, 'NSHighResolutionCapable': True,
    'NSCameraUsageDescription': 'StreamApp uses the camera you enable in your broadcast layout.',
    'NSMicrophoneUsageDescription': 'StreamApp mixes the microphone you enable into recordings and broadcasts.',
    'NSScreenCaptureUsageDescription': 'StreamApp captures only the display or window you select for your session.',
    'NSCameraUseContinuityCameraDeviceType': True,
}
(staging / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
entitlements = ROOT / '.build/StreamApp.entitlements.plist'

entitlements.write_bytes(plistlib.dumps({'com.apple.security.device.camera': True,
                                         'com.apple.security.device.audio-input': True}))
# Every bundled executable is self-contained; fail closed on any non-system dynamic dependency.
for binary in (macos / 'StreamApp', macos / 'ffmpeg'):
    for line in run('otool', '-L', str(binary)).splitlines()[1:]:
        dependency = line.strip().split(' (compatibility version', 1)[0]
        if not dependency.startswith(('/System/', '/usr/lib/')):
            raise SystemExit(f'Unexpected non-system dynamic dependency: {binary.name}: {dependency}')
licenses = resources / 'ThirdParty'
licenses.mkdir()
shutil.copytree(ROOT / '.build/aec/ThirdParty', licenses / 'WebRTC-AEC')
shutil.copy2(ROOT / 'LICENSE', licenses / 'StreamApp-GPL-3.0.txt')
ffmpeg_notices = ROOT / '.build/ffmpeg/ThirdParty'
if not ffmpeg_notices.is_dir():
    raise SystemExit('FFmpeg bootstrap did not produce ThirdParty notices.')
shutil.copytree(ffmpeg_notices, licenses / 'FFmpeg')
(licenses / 'NOTICE.txt').write_text(
    'StreamApp: Copyright (C) 2026 btuckerc. Licensed under GPL-3.0-or-later.\n'
    'You may redistribute and modify StreamApp under GPL version 3 or, at your option, any later version.\n'
    'StreamApp is distributed WITHOUT ANY WARRANTY; see StreamApp-GPL-3.0.txt.\n'
    'Application and matching dependency sources are provided with each release at https://github.com/btuckerc/streamapp/releases.\n'
    'This build bundles a static FFmpeg command-line tool; exact source, configuration and licenses are in FFmpeg/.\n'
    'The static AEC dependency is WebRTC/Abseil; exact provenance, licenses and patent grant are in WebRTC-AEC/.\n'
    'FFmpeg is LGPLv3 (with exact configuration recorded in FFmpeg/ffmpeg-build.txt); this build has no GPL or nonfree components.\n'
    'OpenSSL is statically linked from the Apache-2.0 licensed OpenSSL 3 archives; its license is in FFmpeg/OpenSSL-LICENSE.txt.\n'
    'Release distribution requires corresponding source availability and applicable license obligations.\n'
    + ('Release builds require an accompanying corresponding-source archive; this adapter does not create it.\n'
       if a.release else 'Ad-hoc builds are for local use, not notarized public releases.\n'))
helper_signing = ['--options', 'runtime'] if a.identity != '-' else []
if a.release:
    helper_signing = ['--timestamp', '--options', 'runtime']
run('codesign', '--force', '--sign', a.identity, *helper_signing, str(macos / 'ffmpeg'))
app_signing = ['--timestamp', '--options', 'runtime'] if a.release else ['--options', 'runtime']
run('codesign', '--force', '--sign', a.identity, *app_signing, '--entitlements', str(entitlements), str(staging))
run('codesign', '--verify', '--deep', '--strict', str(staging))
if a.identity != '-':
    requirement = subprocess.run(['codesign', '-d', '-r-', str(staging)], text=True, capture_output=True, check=True)
    if 'designated =>' not in requirement.stdout + requirement.stderr or 'designated => cdhash' in requirement.stdout + requirement.stderr:
        raise SystemExit('Persistent designated requirement missing; refusing installation.')
# Replace only this generated application, after its replacement has passed signing checks.
if a.release:
    shutil.copytree(staging, app, symlinks=True)
    shutil.rmtree(staging.parent)
else:
    if app.exists():
        shutil.rmtree(app)
    staging.rename(app)
print(f'Built {app}')
print('Local ad-hoc build; not notarized. macOS permissions may need reapproval after rebuilding.'
      if a.identity == '-' else 'Persistently signed local build; not notarized.')
if a.install:
    if subprocess.run(['pgrep', '-x', 'StreamApp'], capture_output=True).returncode == 0:
        raise SystemExit('Quit StreamApp before installing. The verified new build remains at the project root.')
    destination = Path.home() / 'Applications/StreamApp.app'
    destination.parent.mkdir(exist_ok=True)
    if destination.is_symlink():
        raise SystemExit('Refusing to replace a symlink at the install destination.')
    if destination.exists():
        old_info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
        if old_info.get('CFBundleIdentifier') != info['CFBundleIdentifier']:
            raise SystemExit('The destination belongs to a different application.')
    install_staging = destination.parent / '.StreamApp-install.app'
    if install_staging.exists():
        raise SystemExit(f'Inspect and remove stale install staging first: {install_staging}')
    shutil.copytree(app, install_staging, symlinks=True)
    try:
        run('codesign', '--verify', '--deep', '--strict', str(install_staging))
        backup = ROOT / '.build/StreamApp-previous.app'
        if destination.exists():
            if backup.exists():
                shutil.rmtree(backup)
            destination.rename(backup)
        try:
            install_staging.rename(destination)
        except OSError:
            if backup.exists() and not destination.exists():
                backup.rename(destination)
            raise
    finally:
        if install_staging.exists():
            shutil.rmtree(install_staging)
    print(f'Installed {destination}')
