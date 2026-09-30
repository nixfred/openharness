#!/usr/bin/env python3
"""New Harness's real terminal UI, desktop choices, launch payloads and recovery.

Only a private fixture backend, temporary HOME and explicitly named hn/tmux sockets.
"""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PORT = int(os.environ.get('HN_NEW_UI_PORT', '19786'))
assert 19783 <= PORT <= 19789, 'refusing non-test popup port'
PREFIX = f'hn-new-ui-{os.getpid()}'
BASE = Path(tempfile.mkdtemp(prefix='hnnu-', dir='/tmp')).resolve()
HN = BASE / 'hn'
shutil.copy2(os.environ.get('HN_NEW_UI_BINARY', ROOT / 'target/release/harness-tui'), HN)
TMUX = shutil.which('tmux')
assert TMUX
ENV = {k: os.environ[k] for k in ('PATH', 'LANG', 'LC_ALL', 'TZ') if k in os.environ}
ENV.update(HOME=str(BASE), HN_TMPDIR=str(BASE), HN_SOCKET_NAME=PREFIX, PORT=str(PORT),
           TERM='xterm-256color', COLORTERM='truecolor', SHELL='/bin/sh', HARNESS_TUI_DESK='sync',
           HARNESS_TUI_NOTIFY='off', HN_DESKTOP='off', MOCK_DEMO='1', MOCK_RECONNECT='1', MOCK_NEW_UI='1')
OUTPUT = Path(os.environ['HN_NEW_UI_OUTPUT']) if os.environ.get('HN_NEW_UI_OUTPUT') else None
if OUTPUT: OUTPUT.mkdir(parents=True, exist_ok=True)

def hn(*args, ok=True):
    p = subprocess.run([str(HN), '-L', PREFIX, '--port', str(PORT), '-f', '/dev/null', *args],
                       env=ENV, cwd=BASE, text=True, capture_output=True, timeout=12)
    if ok: assert p.returncode == 0, (args, p.stdout, p.stderr)
    return p.stdout.strip()

def tmux(*args, ok=True):
    p = subprocess.run([TMUX, '-L', PREFIX + '-outer', *args], env=ENV, cwd=BASE,
                       text=True, capture_output=True, timeout=10)
    if ok: assert p.returncode == 0, (args, p.stderr)
    return p.stdout

def state(route='dial'):
    with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/test/{route}', timeout=2) as r:
        result = json.load(r)
        return result.get('data', result)

def screen(): return tmux('capture-pane', '-p', '-t', 'test')
def settle_ui():
    # Wait for chooser content to redraw, not just tmux send-keys returning,
    # before taking mouse coordinates.
    # Crop to popup borders so animated working panes cannot keep it unsettled.
    previous, changed = None, time.monotonic()
    deadline = changed + 3
    while time.monotonic() < deadline:
        signature = tuple(line[line.index('│'):line.rindex('│') + 1]
                          for line in screen().splitlines() if line.count('│') >= 2)
        if signature != previous:
            previous, changed = signature, time.monotonic()
        elif time.monotonic() - changed >= .15:
            return
        time.sleep(.025)
    raise AssertionError('popup did not settle\n' + screen())
def keys(*args):
    tmux('send-keys', '-t', 'test', *args)
    settle_ui()
def type_text(text): tmux('send-keys', '-l', '-t', 'test', text)
def wait(fn, label, seconds=8):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if fn(): return
        time.sleep(.05)
    raise AssertionError(label + '\n' + screen())
def shows(text): wait(lambda: text in screen(), text)
def snapshot(name):
    time.sleep(.1)
    if OUTPUT: (OUTPUT / (name + '.ansi')).write_text(tmux('capture-pane', '-p', '-e', '-t', 'test'))
def create_count(): return len(state().get('created', []))
def click(x, y):
    for suffix in ['M', 'm']:
        raw = f'\x1b[<0;{x+1};{y+1}{suffix}'.encode()
        tmux('send-keys', '-H', '-t', 'test', *[f'{b:02x}' for b in raw])
    settle_ui()
def field(label):
    def find():
        for y, line in enumerate(screen().splitlines()):
            m = re.search(r'│[ ›]*(' + re.escape(label) + r') {2,}', line)
            if m: return m.start(1), y
    wait(find, f'field {label}')
    click(*find())
def choose_field(label, query):
    field(label); type_text(query); keys('Enter'); shows('New Harness')
def new_form():
    keys('C-b', 'N'); shows('Options')
def placement():
    window, windows, panes = hn('display-message', '-p', '#{window_id} #{session_windows} #{window_panes}').split()
    return window, int(windows), int(panes)
def placed_in_current_window(before):
    window, windows, panes = before
    assert placement() == (window, windows, panes + 1), 'New Harness must add a pane in the current window'
    # Keep room for the next launch as this suite creates several harnesses in one window.
    hn('select-layout', 'tiled')
def submit(count):
    # Git discovery is asynchronous. Wait for its answer before accepting the visible draft.
    time.sleep(.15)
    before = placement()
    keys('Enter')
    wait(lambda: create_count() == count and 'Options' not in screen(), 'created harness')
    placed_in_current_window(before)

def raw(data):
    tmux('send-keys', '-H', '-t', 'test', *[f'{b:02x}' for b in data.encode()])

mock = None
started = False
try:
    with socket.socket() as probe: probe.bind(('127.0.0.1', PORT))
    mock = subprocess.Popen(['node', str(ROOT / 'tests/mock-daemon.mjs'), str(PORT)], env=ENV,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for _ in range(100):
        assert mock.poll() is None
        try: state(); break
        except OSError: time.sleep(.05)
    else: raise AssertionError('mock startup timeout')
    command = shlex.join(['env', '-u', 'TMUX', '-u', 'TMUX_PANE', '-u', 'HN_SOCKET',
                          *[f'{k}={v}' for k, v in ENV.items()], str(HN), '-L', PREFIX,
                          '--port', str(PORT), '-f', '/dev/null'])
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-x', '150', '-y', '42', command)
    started = True
    shows('Fix flaky login test')
    first_window = hn('display-message', '-p', '#{window_id}')
    keys('C-b', 'n')
    wait(lambda: hn('display-message', '-p', '#{window_id}') != first_window, 'lowercase n remains next-window')
    keys('C-b', 'p'); new_form()
    snapshot('new-harness-form')
    before = create_count()
    input_before = len(state('reconnect')['inputs'])
    keys('Right'); assert create_count() == before, 'Right on New Harness must not launch'
    keys('Down'); shows('Search agents and harnesses')
    assert 'Blender' in screen(), 'the agent chooser appears while moving over Agent'
    keys('Tab'); snapshot('new-harness-agent')
    type_text('codex'); keys('Escape')
    shows('Options'); field('Agent'); type_text('codex'); keys('Enter')
    field('Project'); shows('Clone Repository'); snapshot('new-harness-project')
    type_text('clone'); keys('Enter'); shows('Choose a machine'); keys('Enter'); shows('GitHub URL')
    raw('\x1b[200~autonomous-ai/openharness\x1b[201~'); keys('Enter')
    shows('Clone: autonomous-ai/')
    assert create_count() == before, 'choosing fields must not launch'
    field('Project'); type_text('new folder'); keys('Enter'); shows('Choose a machine'); keys('Enter'); shows('Folder name')
    type_text('fail-once'); keys('Enter'); shows('New Folder: fail-once')
    field('Options'); shows('Approvals'); shows('Model'); shows('Profile')
    assert not re.search(r'│[ ›]*Machine {2,}', screen()), 'Machine belongs in Project, not Options'
    choose_field('Approvals', 'read only'); shows('Read only')
    snapshot('new-harness-options')
    keys('Enter', 'Enter'); shows('Fixture launch failure')
    assert create_count() == before + 1, 'busy popup prevents double submission'
    shows('fail-once'); shows('Read only')
    request = state()['created'][-1]
    assert request['engine'] == 'codex', request
    assert request['projectSource'] == 'new' and request['projectName'] == 'fail-once', request
    assert request['permissionMode'] == 'readOnly' and request['bypassPermission'] is False, request
    snapshot('new-harness-retry')
    keys('Escape'); new_form(); shows('Fixture launch failure')
    submit(before + 2)
    retry = state()['created'][-1]
    assert retry['creationId'] != request['creationId'], 'confirmed refusal requires a fresh receipt'
    assert retry['cwd'] == '/home/demo/fail-once', 'reuse the already prepared folder'
    assert not any(k in retry for k in ('projectSource', 'projectName', 'gitSource', 'branchRef')), retry
    assert len(state('reconnect')['inputs']) == input_before, 'form input must never reach a working pane'
    print('PASS New Harness: desktop fields, keyboard, search, paste, retry and no duplicate/input leak', flush=True)

    new_form(); field('Project'); type_text('open folder'); keys('Enter'); shows('Choose a machine'); keys('Enter'); shows('Use this folder')
    type_text('projects'); keys('Enter'); shows('Use this folder'); keys('Enter'); shows('/projects')
    field('Options'); shows('[x]'); choose_field('Branch', 'feature')
    submit(before + 3)
    request = state()['created'][-1]
    assert request['projectSource'] == 'worktree' and request['gitSource'].endswith('/projects'), request
    assert request['branchRef'] == 'refs/heads/feature' and request['branchMode'] == 'existing', request
    print('PASS New Harness: browse folders, Git discovery and desktop worktree branch selection', flush=True)

    new_form(); field('Options'); choose_field('Profile', 'Work'); shows('Work')
    submit(before + 4)
    assert state()['created'][-1]['codexHome'] == '/home/demo/.codex-work'
    new_form(); field('Options'); choose_field('Model', 'demo-model'); shows('demo-model')
    submit(before + 5)
    request = state()['created'][-1]
    assert request['gridModel'] == 'demo-model' and request['gridName'] == 'studio', request
    assert 'codexHome' not in request, request
    print('PASS New Harness: machine-scoped profiles and explicit model routes', flush=True)

    new_form(); choose_field('Agent', 'Blender'); shows('Choose a coding agent'); type_text('codex'); keys('Enter'); shows('Blender · Codex')
    submit(before + 6)
    assert state()['created'][-1]['dsh'] == 'example/blender'
    new_form(); choose_field('Harness', 'Terminal'); field('Options')
    assert not re.search(r'│[ ›]*(Model|Approvals|Profile) {2,}', screen()), 'Terminal omits irrelevant settings'
    # Return focus to the action without accepting any of the disabled Git rows.
    before_terminal = placement()
    field('New Harness')
    wait(lambda: create_count() == before + 7 and 'Options' not in screen(), 'terminal launch')
    placed_in_current_window(before_terminal)
    request = state()['created'][-1]
    assert request['engine'] == 'terminal' and request.get('permissionMode') is None, request
    assert not any(k in request for k in ('dsh', 'prompt', 'gridModel', 'gitSource', 'codexHome')), request
    print('PASS New Harness: specialized harness compatibility and ordinary Terminal launch', flush=True)

    new_form(); field('Agent'); type_text('claude'); keys('Enter'); field('Options'); choose_field('Approvals', 'plan'); shows('Plan first')
    keys('Escape'); new_form(); shows('Plan first')
    count = create_count()
    for w, h in [(80, 24), (45, 14), (22, 5), (1, 1), (150, 42)]:
        tmux('resize-window', '-t', 'test', '-x', str(w), '-y', str(h)); time.sleep(.4)
        assert hn('display-message', '-p', '#{window_panes}').isdigit(), 'hn survives tiny resizes'
    field('Project'); shows('Search projects')
    tmux('resize-window', '-t', 'test', '-x', '80', '-y', '24')
    wait(lambda: any('Search projects' in line and line.rstrip().endswith('│') for line in screen().splitlines()), 'narrow picker redraw')
    snapshot('new-harness-narrow')
    keys('Escape', 'Escape'); assert create_count() == count
    tmux('resize-window', '-t', 'test', '-x', '150', '-y', '42'); new_form()
    # Supply actual terminal palette replies, as a light terminal would.
    raw('\x1b]10;rgb:2020/2020/2020\x1b\\\x1b]11;rgb:ffff/ffff/ffff\x1b\\')
    snapshot('new-harness-light'); keys('Escape')
    print('PASS New Harness: draft restoration, narrow/light rendering and cancellation', flush=True)

    new_form(); field('Project'); type_text('new folder'); keys('Enter'); shows('Choose a machine'); keys('Enter'); shows('Folder name')
    type_text('lose-reply'); keys('Enter'); shows('New Folder: lose-reply')
    count = create_count()
    before_recovery = placement()
    keys('Enter'); shows('Check status'); shows('Launch not confirmed')
    assert create_count() == count + 1
    request = state()['created'][-1]
    # Changes cannot turn a lost reply into another launch, even across dismissal.
    keys('Down', 'a'); assert 'Search agents' not in screen()
    keys('Escape'); new_form(); shows('Check status')
    wait(lambda: any(c['machine'] == request.get('machineId', 'mock0000000000000000000000000001') for c in state('reconnect')['connections']), 'machine reconnected')
    time.sleep(.5)
    keys('Enter'); shows('Still starting your harness')
    assert create_count() == count + 1
    keys('Enter'); wait(lambda: 'Options' not in screen(), 'original harness recovered')
    placed_in_current_window(before_recovery)
    assert create_count() == count + 1, 'status recovery must never send a second create'
    checks = state()['creationChecks'][-2:]
    assert len(checks) == 2 and all(c['creationId'] == request['creationId'] for c in checks)

    new_form(); field('Project'); type_text('new folder'); keys('Enter'); shows('Choose a machine'); keys('Enter'); shows('Folder name')
    type_text('unknown-launch'); keys('Enter'); keys('Enter'); shows('Launch outcome unknown')
    count = create_count()
    keys('Enter'); shows('Launch outcome unknown')
    keys('Escape'); new_form(); shows('Check status')
    assert create_count() == count
    keys('Escape')
    print('PASS New Harness: lost reply, reconnect, pending status and uncertain launch never duplicate', flush=True)

finally:
    try:
        if started:
            hn('kill-server', ok=False); tmux('kill-server', ok=False)
        def clients():
            rows = subprocess.check_output(['ps', '-ax', '-o', 'pid=,command='], text=True).splitlines()
            return [int(parts[0]) for row in rows if len(parts := row.strip().split(None, 1)) == 2
                    and parts[1].startswith(str(HN) + ' ') and f'-L {PREFIX} ' in parts[1]]
        for pid in clients():
            try: os.kill(pid, 15)
            except ProcessLookupError: pass
        deadline = time.monotonic() + 5
        while clients() and time.monotonic() < deadline: time.sleep(.05)
        assert not clients(), 'New Harness test client did not exit'
    finally:
        if mock:
            mock.terminate()
            try: mock.wait(timeout=5)
            except subprocess.TimeoutExpired: mock.kill(); mock.wait()
        shutil.rmtree(BASE, ignore_errors=True)
