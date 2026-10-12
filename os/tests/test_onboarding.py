import importlib.util
import os
from pathlib import Path
import pty
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('onboarding', Path(__file__).resolve().parents[1] / 'onboarding.py')
onboarding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(onboarding)


def result(code=0):
    return subprocess.CompletedProcess([], code)


class Onboarding(unittest.TestCase):
    def test_signed_in_welcome_starts_the_agent_without_reopening_networking(self):
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(onboarding.Path, 'is_file', return_value=False), \
             patch.object(onboarding.Path, 'home', return_value=Path(temp)), \
             patch.object(onboarding.subprocess, 'run', return_value=result()) as command, \
             patch.object(onboarding.os, 'execv') as execute, \
             patch.dict(os.environ, {'TMUX_PANE': '%4'}):
            onboarding.welcome()
            self.assertEqual(command.call_args_list[0].args[0],
                             ['hn', 'os-action', 'ready', '%4'])
            self.assertEqual(command.call_count, 1)
            execute.assert_called_once_with('/usr/bin/hn-os', ['hn-os', 'try'])
            self.assertTrue((Path(temp) / '.local/state/harness-os/onboarded').exists())

    def test_usb_never_opens_networking_or_an_agent(self):
        with patch.object(onboarding.Path, 'is_file', return_value=True), \
             patch.object(onboarding.subprocess, 'run') as command, \
             patch.object(onboarding.os, 'execv') as execute:
            onboarding.welcome()
            command.assert_not_called()
            execute.assert_called_once_with('/usr/lib/harness-os/open-install', ['open-install'])

    def test_failed_layout_request_does_not_mark_first_use_complete(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(onboarding.Path, 'is_file', return_value=False), \
             patch.object(onboarding.Path, 'home', return_value=Path(temp)), \
             patch.object(onboarding.subprocess, 'run', side_effect=subprocess.TimeoutExpired('hn', 15)), \
             patch.object(onboarding.os, 'execv') as execute:
            onboarding.welcome()
            self.assertFalse((Path(temp) / '.local/state/harness-os/onboarded').exists())
            execute.assert_called_once()

    def test_network_failure_does_not_claim_onboarding_or_start_agent(self):
        with patch.object(onboarding.Path, 'is_file', return_value=False), \
             patch.object(onboarding.subprocess, 'run', return_value=result(1)), \
             patch.object(onboarding.os, 'execv') as execute:
            with self.assertRaisesRegex(SystemExit, 'Could not open Wi-Fi'):
                onboarding.prepare()
            execute.assert_not_called()

    def test_first_use_requires_networking_before_the_tui_starts(self):
        with patch.object(onboarding.Path, 'is_file', return_value=False), \
             patch.object(onboarding.subprocess, 'run', return_value=result()) as command, \
             patch.object(onboarding.os, 'execv') as execute:
            onboarding.prepare()
            command.assert_called_once_with(
                ['sudo', '/usr/bin/python3', '/usr/lib/harness-os/network.py', '--first-use'])
            execute.assert_not_called()

    def test_completed_setup_can_reopen_offline_and_usb_never_requires_network(self):
        for files in ([False, True], [True]):
            with self.subTest(files=files), \
                 patch.object(onboarding.Path, 'is_file', side_effect=files), \
                 patch.object(onboarding.subprocess, 'run') as command:
                onboarding.prepare()
                command.assert_not_called()

    def test_launcher_connects_before_tui_and_stops_if_setup_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            events = root / 'events'
            runtime = root / 'runtime'
            runtime.mkdir()
            for name, text in {
                'python': 'echo network >> "$EVENTS"; exit "$NETWORK_RESULT"',
                'runtime/hn': 'echo "tui $*" >> "$EVENTS"',
            }.items():
                path = root / name
                path.write_text('#!/bin/sh\n' + text + '\n')
                path.chmod(0o755)
            source = (Path(__file__).resolve().parents[1] / 'root/usr/bin/hn').read_text()
            source = source.replace('. /usr/lib/harness-os/runtime-path',
                                    'harness_runtime=' + shlex.quote(str(runtime)))
            source = source.replace('/usr/bin/python3', shlex.quote(str(root / 'python')))
            source = source.replace('/etc/harness-live', str(root / 'not-live'))
            launcher = root / 'launcher'
            launcher.write_text(source)
            master, slave = pty.openpty()
            try:
                for args, os_mode, code, expected in [
                    ([], '1', '0', ['network', 'tui ']),
                    (['list-panes'], '1', '0', ['tui list-panes']),
                    ([], '0', '0', ['tui ']),
                    ([], '1', '1', ['network']),
                ]:
                    with self.subTest(args=args, os_mode=os_mode, code=code):
                        events.unlink(missing_ok=True)
                        completed = subprocess.run(['/bin/sh', str(launcher), *args], stdin=slave,
                            capture_output=True, text=True, timeout=5,
                            env=dict(os.environ, HOME=str(root), HARNESS_OS=os_mode,
                                     EVENTS=str(events), NETWORK_RESULT=code))
                        self.assertEqual(events.read_text().splitlines(), expected)
                        self.assertEqual(completed.returncode, int(code), completed.stderr)
            finally:
                os.close(master)
                os.close(slave)
