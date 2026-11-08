#!/usr/bin/env python3
"""Run a command in the logged-in user's GUI (Aqua) session and relay its output and exit status.

Over SSH the login keychain is unavailable: codesign fails with errSecInternalComponent and
notarytool cannot read its keychain profile. A one-shot LaunchAgent in gui/UID runs where the
keychain is already unlocked. Needs that user logged in at the Mac; no password, sudo or
extra keychain.

The job owns its own cleanup, so the caller handles no signals: it unloads itself when the
command finishes, and a watcher inside the job unloads it (launchd then kills the command)
when the caller exits for any reason, SIGKILL included, or the timeout passes.

    python3 scripts/gui_session.py COMMAND [ARGS...]
"""
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys
import tempfile

# Waits, without polling, for the caller to exit or the deadline, then unloads the job.
WATCH = '''
import select, subprocess, sys
caller, job, timeout = int(sys.argv[1]), sys.argv[2], float(sys.argv[3])
queue = select.kqueue()
try:
    queue.control([select.kevent(caller, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 1, timeout)
except ProcessLookupError:
    pass
subprocess.run(['launchctl', 'bootout', job])
'''
# Status is written before the stream closes, so the caller's EOF implies the status file exists
# unless the job was stopped. The job then unloads itself, which also ends the watcher.
SHELL = ('python=$1 caller=$2 job=$3 timeout=$4 out=$5 status=$6; shift 6; '
         '"$python" -c "$WATCH" "$caller" "$job" "$timeout" & '
         'exec 3>"$out"; "$@" >&3 2>&3; echo $? > "$status"; exec 3>&-; exec launchctl bootout "$job"')


def run(args, cwd=None, timeout=3600, sink=None):
    """Returns (exit status, combined output); `sink` also receives output as it arrives."""
    cwd = Path(cwd or os.getcwd())
    if not cwd.is_dir():
        raise FileNotFoundError(cwd)
    job = f'gui/{os.getuid()}/dev.streamapp.gui-session.{os.getpid()}.{secrets.token_hex(4)}'
    chunks = []
    with tempfile.TemporaryDirectory(prefix='gui-session.') as tmp:
        out, status, plist = Path(tmp, 'out'), Path(tmp, 'status'), Path(tmp, 'job.plist')
        os.mkfifo(out, 0o600)
        env = {k: v for k, v in os.environ.items() if not k.startswith('SSH_')}
        env['WATCH'] = WATCH
        plist.write_bytes(plistlib.dumps({
            'Label': job.rsplit('/', 1)[1], 'RunAtLoad': True, 'ProcessType': 'Interactive',
            'WorkingDirectory': str(cwd), 'EnvironmentVariables': env,
            'ProgramArguments': ['/bin/sh', '-c', SHELL, 'sh', sys.executable, str(os.getpid()), job,
                                 str(timeout), str(out), str(status), *map(str, args)],
        }))
        subprocess.run(['launchctl', 'bootstrap', job.rsplit('/', 1)[0], str(plist)], check=True)
        try:
            with open(out, 'rb') as stream:
                for chunk in iter(lambda: stream.read1(65536), b''):
                    text = chunk.decode(errors='replace')
                    chunks.append(text)
                    if sink:
                        sink(text)
        finally:
            subprocess.run(['launchctl', 'bootout', job], capture_output=True)  # fast path; the job also cleans up
        if not status.exists():
            raise TimeoutError(f'{args[0]} was stopped in the GUI session (timeout {timeout} s, or the job was unloaded)')
        return int(status.read_text()), ''.join(chunks)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    code, _ = run(sys.argv[1:], sink=lambda text: (sys.stdout.write(text), sys.stdout.flush()))
    sys.exit(code)
