"""A saved offline account for isolated terminal fixtures that do not run a daemon."""
import shlex
import sys


def signed_in_account(env, root):
    """Exercise ordinary authenticated startup without a real account or network."""
    script = root / 'account-fixture.py'
    script.write_text('import json, sys\n'
                      'if sys.argv[1:3] != ["auth", "status"]: sys.exit(1)\n'
                      'print(json.dumps({"loggedIn": True, "offline": True}))\n')
    wrapper = root / 'account-fixture'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(script)]) + ' "$@"\n')
    wrapper.chmod(0o700)
    env['HARNESS_CLI'] = str(wrapper)
