#!/usr/bin/env python3
"""Connect before launching hn; start the first workspace after hn's sign-in."""
import os
from pathlib import Path
import subprocess
import sys


def prepare():
    if Path('/etc/harness-live').is_file() or (Path.home() / '.local/state/harness-os/onboarded').is_file():
        return
    # The OS owns initial connectivity. hn is launched only after this form
    # succeeds; Ethernet advances immediately and Wi-Fi waits for a connection.
    result = subprocess.run(['sudo', '/usr/bin/python3', '/usr/lib/harness-os/network.py', '--first-use'])
    if result.returncode != 0:
        raise SystemExit('Could not open Wi-Fi. Restart Harness to try again.')


def welcome():
    live = Path('/etc/harness-live').is_file()
    if live:
        os.execv('/usr/lib/harness-os/open-install', ['open-install'])
        return
    # Initial networking finished before hn launched. This pane is created only
    # after hn's shared account gate has opened.
    pane = os.environ.get('TMUX_PANE', '')
    try:
        result = subprocess.run(['hn', 'os-action', 'ready', pane], check=False, timeout=15)
        if result.returncode == 0:
            state = Path.home() / '.local/state/harness-os'
            state.mkdir(parents=True, exist_ok=True)
            (state / 'onboarded').touch()
    except (OSError, subprocess.TimeoutExpired):
        pass
    os.execv('/usr/bin/hn-os', ['hn-os', 'try'])


if __name__ == '__main__':
    if sys.argv[1:] == ['--prepare']:
        prepare()
    else:
        welcome()
