#!/usr/bin/env python3
"""Create an isolated, password-protected test keyring; never print its password."""
import os
from pathlib import Path
import secrets
import subprocess

if os.environ.get('SHIORI_ISOLATED_TEST_KEYRING') != 'true':
    raise SystemExit('Use a fresh dbus-run-session and an isolated XDG_DATA_HOME for this test helper.')
if not os.environ.get('DBUS_SESSION_BUS_ADDRESS') or not os.environ.get('XDG_DATA_HOME'):
    raise SystemExit('Missing isolated D-Bus session or data directory.')
root = Path(os.environ['XDG_DATA_HOME'])
root.mkdir(parents=True, exist_ok=True)
if any(root.iterdir()):
    raise SystemExit('Refusing to reuse an existing data directory.')
result = subprocess.run(['gnome-keyring-daemon', '--unlock', '--daemonize', '--components=secrets'],
    input=secrets.token_urlsafe(32).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
if result.returncode:
    raise SystemExit('Unable to initialize the isolated test keyring.')
print('Initialized isolated password-protected test keyring.')
