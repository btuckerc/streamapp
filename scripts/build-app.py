#!/usr/bin/env python3
"""Build the local macOS application and close its Homebrew dylib dependency graph."""
import argparse
import json
import os
from pathlib import Path
import re
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--identity', help='Persistent Apple signing identity; - explicitly requests a development-only ad-hoc build')
parser.add_argument('--install', action='store_true', help='Install the verified bundle into ~/Applications')
a = parser.parse_args()

def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.STDOUT)


# Match Dictation's persistent local identity policy: never silently change the
# designated requirement and invalidate camera/microphone/Screen Recording consent.
pin = ROOT / '.local/macos-signing-identity'
requested = a.identity or os.environ.get('APPLE_SIGNING_IDENTITY')
pinned = pin.read_text().strip() if pin.exists() else None
if requested == '-':
    if a.install:
        raise SystemExit('Installed builds require a persistent signing identity, not ad-hoc signing.')
else:
    identities = re.findall(r'\d+\) ([A-Fa-f0-9]{40}) "((?:Apple Development:|Developer ID Application:)[^"]+)"',
                            run('security', 'find-identity', '-v', '-p', 'codesigning'))
    selected = requested or pinned
    if selected:
        matches = [(key, name) for key, name in identities if selected in (key, name)]
        if len(matches) != 1:
            raise SystemExit('Selected signing identity unavailable or ambiguous; specify its SHA-1 fingerprint.')
        requested = matches[0][0]
    elif identities and len({name for _, name in identities}) == 1:
        requested = sorted(key for key, _ in identities)[0]
    else:
        raise SystemExit('Select a persistent identity with --identity. No ad-hoc fallback.')
    if pinned and pinned != requested:
        raise SystemExit('Identity differs from the local pin. Migrate signing intentionally before rebuilding.')
    pin.parent.mkdir(exist_ok=True)
    pin.write_text(requested + '\n')
a.identity = requested
print(run('swift', 'build', '-c', 'release'), end='')
binary_dir = Path(run('swift', 'build', '-c', 'release', '--show-bin-path').strip())
ffmpeg = shutil.which('ffmpeg')
if not ffmpeg:
    raise SystemExit('Install FFmpeg before packaging: brew install ffmpeg pkg-config')
app = ROOT / 'StreamApp.app'
staging = ROOT / '.build/StreamApp-staging.app'
if staging.exists():
    shutil.rmtree(staging)
macos = staging / 'Contents/MacOS'
frameworks = staging / 'Contents/Frameworks'
resources = staging / 'Contents/Resources'
for path in (macos, frameworks, resources):
    path.mkdir(parents=True, exist_ok=True)
shutil.copy2(binary_dir / 'StreamApp', macos / 'StreamApp')
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
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.1.0', 'CFBundleVersion': '2',
    'CFBundleIconFile': 'StreamApp.icns',
    'LSMinimumSystemVersion': '26.0', 'LSUIElement': True, 'NSHighResolutionCapable': True,
    'NSCameraUsageDescription': 'StreamApp uses the camera you enable in your broadcast layout.',
    'NSMicrophoneUsageDescription': 'StreamApp mixes the microphone you enable into recordings and broadcasts.',
    'NSScreenCaptureUsageDescription': 'StreamApp captures only the display or window you select for your session.',
    'NSCameraUseContinuityCameraDeviceType': True,
}
(staging / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
entitlements = ROOT / '.build/StreamApp.entitlements.plist'

copied = {}
queue = [macos / 'StreamApp', macos / 'ffmpeg']
entitlement_values = {'com.apple.security.device.camera': True, 'com.apple.security.device.audio-input': True}
if a.identity == '-':
    # Ad-hoc signatures have no shared Team ID. Developer ID builds keep validation.
    entitlement_values['com.apple.security.cs.disable-library-validation'] = True
entitlements.write_bytes(plistlib.dumps(entitlement_values))
manifest = []
while queue:
    binary = queue.pop(0)
    dependencies = []
    for line in run('otool', '-L', str(binary)).splitlines()[1:]:
        dependency = line.strip().split(' (compatibility version', 1)[0]
        if dependency.startswith(('/System/', '/usr/lib/')):
            continue
        if dependency.startswith('@'):
            # The supplied Homebrew graph should be absolute. Fail closed if not.
            if dependency.startswith('@loader_path/') and (binary.parent / dependency[len('@loader_path/'):]).exists():
                continue
            raise SystemExit(f'Unresolved dynamic dependency: {binary.name}: {dependency}')
        source = Path(dependency)
        if not source.is_file():
            raise SystemExit(f'Missing dependency: {dependency}')
        real = source.resolve()
        destination = frameworks / source.name
        if source.name in copied and copied[source.name] != real:
            raise SystemExit(f'Dylib basename collision: {source.name}')
        if source.name not in copied:
            copied[source.name] = real
            shutil.copy2(real, destination)
            queue.append(destination)
            manifest.append({'name': source.name, 'source': str(real)})
        replacement = '@loader_path/' + ('../Frameworks/' if binary.parent == macos else '') + source.name
        subprocess.run(['install_name_tool', '-change', dependency, replacement, str(binary)], check=True, capture_output=True)
        dependencies.append(replacement)
    if binary.parent == frameworks:
        subprocess.run(['install_name_tool', '-id', '@loader_path/' + binary.name, str(binary)], check=True, capture_output=True)

licenses = resources / 'ThirdParty'
licenses.mkdir()
(licenses / 'ffmpeg-build.txt').write_text(run(ffmpeg, '-version'))
(licenses / 'dependency-manifest.json').write_text(json.dumps(manifest, indent=2))
(licenses / 'NOTICE.txt').write_text(
    'This local build bundles FFmpeg and the dependencies listed in dependency-manifest.json.\n'
    'FFmpeg licensing depends on its build configuration, recorded in ffmpeg-build.txt.\n'
    'The Homebrew build used here enables GPL/version-3 components. This is NOT an LGPL-only distribution.\n'
    'Do not redistribute without satisfying all applicable source, notice, relinking and license obligations.\n'
    'See https://ffmpeg.org/legal.html and the corresponding Homebrew formula sources.\n'
    'Ad-hoc builds are for local use, not notarized public releases.\n')
# Preserve available notices from the exact installed formula versions.
formula_roots = set()
for row in manifest:
    source = Path(row['source'])
    parts = source.parts
    if 'Cellar' in parts:
        index = parts.index('Cellar')
        formula_roots.add(Path(*parts[:index + 3]))
for formula in sorted(formula_roots):
    notices = [p for p in formula.iterdir() if p.is_file() and any(word in p.name.upper() for word in ('LICENSE', 'COPYING', 'NOTICE', 'AUTHORS'))]
    if notices:
        target = licenses / (formula.parent.name + '-' + formula.name)
        target.mkdir(exist_ok=True)
        for notice in notices:
            shutil.copy2(notice, target / notice.name)
for library in sorted(frameworks.iterdir()):
    run('codesign', '--force', '--sign', a.identity, str(library))
helper_signing = ['--options', 'runtime'] if a.identity != '-' else []
run('codesign', '--force', '--sign', a.identity, *helper_signing, str(macos / 'ffmpeg'))
run('codesign', '--force', '--sign', a.identity, '--options', 'runtime', '--entitlements', str(entitlements), str(staging))
run('codesign', '--verify', '--deep', '--strict', str(staging))
if a.identity != '-':
    requirement = subprocess.run(['codesign', '-d', '-r-', str(staging)], text=True, capture_output=True, check=True)
    if 'designated =>' not in requirement.stdout + requirement.stderr or 'designated => cdhash' in requirement.stdout + requirement.stderr:
        raise SystemExit('Persistent designated requirement missing; refusing installation.')
# Replace only this generated application, after its replacement has passed signing checks.
if app.exists():
    shutil.rmtree(app)
staging.rename(app)
print(f'Built {app} ({len(copied)} bundled dynamic libraries)')
print('Local ad-hoc build; not notarized.' if a.identity == '-' else 'Persistently signed local build; not notarized.')
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
