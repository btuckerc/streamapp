#!/usr/bin/env python3
"""Run a command in the logged-in user's GUI (Aqua) session and relay its output and exit status.

Over SSH the login keychain is unavailable: codesign fails with errSecInternalComponent and
notarytool cannot read its keychain profile. A one-shot LaunchAgent in gui/UID runs where the
keychain is already unlocked. Needs that user logged in at the Mac; no password, sudo or
extra keychain.

    python3 scripts/gui_session.py COMMAND [ARGS...]
"""
import os
from pathlib import Path
import plistlib
import secrets
import signal
import subprocess
import sys
import tempfile

# Writes status before closing the stream, so the reader's EOF implies the status file exists.
# The job then unloads itself, so even a SIGKILLed caller leaves nothing loaded once it finishes.
SHELL = ('job=$1 out=$2 status=$3; shift 3; exec 3>"$out"; "$@" >&3 2>&3; echo $? > "$status"; exec 3>&-; '
         'exec launchctl bootout "$job"')
SIGNALS = {signal.SIGALRM, signal.SIGTERM, signal.SIGHUP}


def run(args, cwd=None, timeout=3600, sink=None):
    """Returns (exit status, combined output); `sink` also receives output as it arrives."""
    domain = f'gui/{os.getuid()}'
    label = f'dev.streamapp.gui-session.{os.getpid()}.{secrets.token_hex(4)}'
    chunks = []

    def expired(*_):
        raise TimeoutError(f'{args[0]} did not finish in the GUI session within {timeout} s '
                           '(is the user logged in at the Mac?)')

    def interrupted(number, _):
        raise SystemExit(128 + number)

    with tempfile.TemporaryDirectory(prefix='gui-session.') as tmp:
        out, status, job = Path(tmp, 'out'), Path(tmp, 'status'), Path(tmp, 'job.plist')
        os.mkfifo(out, 0o600)
        env = {k: v for k, v in os.environ.items() if not k.startswith('SSH_')}
        job.write_bytes(plistlib.dumps({
            'Label': label, 'RunAtLoad': True, 'ProcessType': 'Interactive',
            'WorkingDirectory': str(cwd or os.getcwd()), 'EnvironmentVariables': env,
            'ProgramArguments': ['/bin/sh', '-c', SHELL, 'sh', f'{domain}/{label}', str(out), str(status), *map(str, args)],
        }))
        # Handlers go in before bootstrap so a timeout, SSH hangup or kill still unloads the job.
        previous = {number: signal.signal(number, handler) for number, handler in
                    ((signal.SIGALRM, expired), (signal.SIGTERM, interrupted), (signal.SIGHUP, interrupted))}
        try:
            subprocess.run(['launchctl', 'bootstrap', domain, str(job)], check=True)
            signal.alarm(timeout)
            with open(out, 'rb') as stream:
                for chunk in iter(lambda: stream.read1(65536), b''):
                    text = chunk.decode(errors='replace')
                    chunks.append(text)
                    if sink:
                        sink(text)
            code = int(status.read_text())
        finally:
            # A signal arriving now must not interrupt cleanup; it is delivered after the job is unloaded.
            signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
            signal.alarm(0)
            subprocess.run(['launchctl', 'bootout', f'{domain}/{label}'], capture_output=True)
            if signal.SIGALRM in signal.sigpending():
                signal.sigwait({signal.SIGALRM})  # a stale timeout; the job is already gone
            for number, handler in previous.items():
                signal.signal(number, handler)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, SIGNALS)
    return code, ''.join(chunks)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    code, _ = run(sys.argv[1:], sink=lambda text: (sys.stdout.write(text), sys.stdout.flush()))
    sys.exit(code)
