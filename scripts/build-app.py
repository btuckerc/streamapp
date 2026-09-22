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
print(run('swift', 'build', '-c', 'release'), end='')
binary_dir = Path(run('swift', 'build', '-c', 'release', '--show-bin-path').strip())
ffmpeg = shutil.which('ffmpeg')
if not ffmpeg:
    raise SystemExit('Install FFmpeg before packaging: brew install ffmpeg pkg-config')
ffmpeg_config = run(ffmpeg, '-version')
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
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': a.version if a.release else '1.2.1',
    'CFBundleVersion': a.build_number if a.release else '8',
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
shutil.copy2(ROOT / 'LICENSE', licenses / 'StreamApp-GPL-3.0.txt')
(licenses / 'ffmpeg-build.txt').write_text(ffmpeg_config)
(licenses / 'dependency-manifest.json').write_text(json.dumps(manifest, indent=2))
(licenses / 'NOTICE.txt').write_text(
    'StreamApp: Copyright (C) 2026 btuckerc. Licensed under GPL-3.0-or-later.\n'
    'You may redistribute and modify StreamApp under GPL version 3 or, at your option, any later version.\n'
    'StreamApp is distributed WITHOUT ANY WARRANTY; see StreamApp-GPL-3.0.txt.\n'
    'Application and matching dependency sources are provided with each release at https://github.com/btuckerc/streamapp/releases.\n'
    'This build bundles FFmpeg and the dependencies listed in dependency-manifest.json.\n'
    'FFmpeg licensing depends on its exact build configuration, recorded in ffmpeg-build.txt.\n'
    'The bundled configuration enables GPL/version-3 components; this is NOT an LGPL-only distribution.\n'
    'Release distribution requires corresponding source availability and applicable license obligations.\n'
    + ('Release builds require an accompanying corresponding-source archive; this adapter does not create it.\n'
       if a.release else 'Ad-hoc builds are for local use, not notarized public releases.\n'))
# Preserve notices from the exact installed formula versions.
formula_roots = set()
for row in manifest:
    source = Path(row['source'])
    if 'Cellar' in source.parts:
        index = source.parts.index('Cellar')
        formula_roots.add(Path(*source.parts[:index + 3]))
for formula in sorted(formula_roots):
    notices = [p for p in formula.iterdir() if p.is_file() and any(word in p.name.upper() for word in ('LICENSE', 'COPYING', 'NOTICE', 'AUTHORS'))]
    if notices:
        target = licenses / (formula.parent.name + '-' + formula.name)
        target.mkdir(exist_ok=True)
        for notice in notices:
            shutil.copy2(notice, target / notice.name)
sign_common = ['--timestamp', '--options', 'runtime'] if a.release else []
for library in sorted(frameworks.iterdir()):
    run('codesign', '--force', '--sign', a.identity, *sign_common, str(library))
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
print(f'Built {app} ({len(copied)} bundled dynamic libraries)')
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
