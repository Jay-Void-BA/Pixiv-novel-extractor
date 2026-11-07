#!/usr/bin/env python3
"""Exercise real Secret Service with synthetic data in an isolated CI keyring."""
import os
from pathlib import Path
import sys

if os.environ.get('SHIORI_ISOLATED_TEST_KEYRING') != 'true':
    raise SystemExit('This check requires an isolated CI keyring.')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'freebsd'))
from shiori_server import State, SystemVault

vault = SystemVault()
vault.SERVICE += '.integration-test'
if not vault.supported:
    raise SystemExit('The isolated system vault is unavailable.')
try:
    vault.delete()
    vault.write('synthetic_service_session_12345')
    assert vault.read() == ('synthetic_service_session_12345', False)
    restored = State(Path('.'), vault=vault)
    assert restored.remember_session and restored.session == 'synthetic_service_session_12345'
    assert 'synthetic_service_session' not in str(restored.status())
    restored.clear_session(forget=True)
    assert vault.read() == (None, False)
finally:
    vault.delete()
print('PASS: real system keyring persistence, restart restore, no cookie in status, and logout deletion.')
