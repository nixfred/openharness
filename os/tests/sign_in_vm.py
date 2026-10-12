#!/usr/bin/env python3
"""Verify OS networking precedes the real TUI in a disposable installed VM."""
import argparse
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import threading
import time

from PIL import Image, ImageOps

from session_vm import put
from vm import VM

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def screen_text(path):
    # Both the OS form and hn use light text, but hn has a shaded panel. Global
    # automatic thresholding mistakes that panel for ink. Normalize the known
    # dark palette first; block OCR keeps a row's words on the same line.
    readable = path.with_name(path.stem + '-ocr.png')
    with Image.open(path) as frame:
        ink = frame.convert('L').point(lambda value: 0 if value >= 96 else 255)
        ink = ink.resize((frame.width * 2, frame.height * 2), Image.Resampling.NEAREST)
        ImageOps.expand(ink, border=24, fill=255).save(readable)
    return subprocess.check_output(['tesseract', str(readable), 'stdout', '--psm', '6'],
                                   text=True, stderr=subprocess.DEVNULL, timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iso', type=Path, required=True)
    parser.add_argument('--tui', type=Path, required=True)
    args = parser.parse_args()
    if not os.access('/dev/kvm', os.R_OK | os.W_OK):
        parser.error('Use native x86 KVM for this check.')
    iso, tui = args.iso.resolve(), args.tui.resolve()
    manifest = json.loads(iso.with_name('manifest.json').read_text())
    assert digest(iso) == manifest['iso']['sha256']
    assert iso.stat().st_size == manifest['iso']['bytes']
    files = {
        'usr/bin/hn': ROOT / 'os/root/usr/bin/hn',
        'usr/lib/harness-os/onboarding.py': ROOT / 'os/onboarding.py',
        'usr/lib/harness/harness-tui': tui,
    }
    folder = ROOT / 'os/test-results/required-sign-in'
    folder.mkdir(parents=True, exist_ok=False)
    served = folder / 'served'
    served.mkdir()
    payload = served / 'candidate.tar.gz'
    def root_owned(info):
        info.uid = info.gid = 0
        info.uname = info.gname = 'root'
        return info
    with tarfile.open(payload, 'w:gz') as archive:
        for destination, source in files.items():
            archive.add(source, arcname=destination, filter=root_owned)
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(served)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    vm = VM(folder, iso, 'bios', 2048)
    result = {'status': 'running', 'started_at': time.time(), 'checks': [],
              'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'image_source': manifest['source_commit'], 'iso_sha256': manifest['iso']['sha256'],
              'candidate_files': {name: digest(path) for name, path in files.items()},
              'scope': 'BIOS/plain disposable installation, real NetworkManager/virtual Ethernet, graphical input and required TUI sign-in. No live account or physical radio.'}
    config = dict(disk='/dev/vda', expected_serial='HN_OS_TEST', confirm_erase='/dev/vda',
                  username='me', hostname='harness', password='test-password-123',
                  encrypt=False, serial_console=True)

    def shown(name, text):
        deadline = time.monotonic() + 90
        while True:
            vm.screenshot(name)
            observed = screen_text(folder / (name + '.png'))
            (folder / (name + '.txt')).write_text(observed)
            if text.lower() in observed.lower():
                return
            if time.monotonic() >= deadline:
                raise AssertionError(f'{text} was not visible')
            time.sleep(1)

    try:
        vm.start(live=True)
        vm.wait(r'root@[^\r\n]*[#] ', timeout=180)
        vm.shell_ready = True
        vm.command('stty -echo')
        # The selected Install button is reverse video; whole-screen inverted
        # OCR misses its text. The ordinary password label identifies the form.
        shown('01-usb-installer', 'Repeat password')
        put(vm, '/tmp/sign-in-install.json', json.dumps(config))
        vm.command('nmcli networking off')
        output, _ = vm.command('harness install --config /tmp/sign-in-install.json --yes-erase-disk', timeout=360)
        (folder / 'install.log').write_text(output)
        result['checks'].append('The USB installer works offline before a Harness account exists')
        # Apply only the recorded candidate files before the first installed boot.
        # The sole block device is the fixture-owned, serial-checked QEMU disk.
        vm.command('nmcli networking on; nm-online -q --timeout=30', timeout=35)
        vm.command(f'curl --noproxy "*" -fsS --max-time 90 http://10.0.2.2:{server.server_port}/candidate.tar.gz -o /tmp/candidate.tar.gz', timeout=100)
        vm.command('printf %s ' + shlex.quote(digest(payload) + '  /tmp/candidate.tar.gz\n') + ' | sha256sum -c -')
        vm.command('mkdir -p /mnt/sign-in-test && mount -o subvol=@ /dev/vda3 /mnt/sign-in-test && '
                   'tar -xzf /tmp/candidate.tar.gz -C /mnt/sign-in-test && '
                   'chmod 755 /mnt/sign-in-test/usr/bin/hn /mnt/sign-in-test/usr/lib/harness/harness-tui && '
                   'sync && umount /mnt/sign-in-test')
        vm.stop()
        vm.start(live=False)
        vm.monitor('set_link', name='hnnet', up=False)
        vm.login_installed(config, wait_workspace=False)
        vm.command('printf %s ' + shlex.quote(config['password'] + '\n') + ' | sudo -S -v')
        shown('02-network-before-tui', 'Connect to Wi-Fi')
        vm.command('! pgrep -u 1000 -f "^/usr/lib/harness/hn$" && ! pgrep -u 1000 -x opencode')
        vm.keys('esc')
        vm.keys('meta_l', 't')
        shown('03-network-still-required', 'Connect to Wi-Fi')
        result['checks'].append('The actual OS network form owns first setup; the TUI and agent have not launched, and Escape/workspace shortcuts cannot bypass it')
        vm.monitor('set_link', name='hnnet', up=True)
        vm.command('nm-online -q --timeout=30', timeout=35)
        shown('04-required-sign-in', 'Sign in to Harness')
        shown('05-sign-in-choices', 'Continue with email')
        vm.command('test ! -e ~/.local/state/harness-os/onboarded && ! pgrep -u 1000 -x opencode')
        vm.command('printf %s ' + shlex.quote(digest(tui) + '  /usr/lib/harness/harness-tui\n') + ' | sha256sum -c -')
        result['checks'].append('Connecting Ethernet launches the exact candidate TUI at required sign-in, without starting an agent or claiming completed onboarding')
        for key in ['t', 'n', 'm']:
            vm.keys('meta_l', key)
            shown('06-gated-' + key, 'Sign in to Harness')
        vm.keys('meta_l', 'w')
        shown('07-wifi-from-sign-in', 'Connect to Wi-Fi')
        vm.keys('esc')
        shown('08-back-to-sign-in', 'Sign in to Harness')
        result['checks'].append('Real compositor shortcuts keep workspace actions gated; the existing Wi-Fi settings form opens and returns to sign-in')
        result['status'] = 'passed'
    except Exception as error:
        result['status'] = 'failed'
        result['error'] = str(error)
        try:
            vm.screenshot('failure')
            output, _ = vm.command('journalctl --user -u hn-screen -u harness-daemon --no-pager -n 150', check=False)
            (folder / 'services.log').write_text(output)
        except Exception:
            pass
        raise
    finally:
        vm.stop()
        server.shutdown()
        server.server_close()
        result['finished_at'] = time.time()
        (folder / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
        if result['status'] == 'passed':
            vm.disk.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
