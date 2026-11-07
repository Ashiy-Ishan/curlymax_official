#!/usr/bin/env python3
"""Run the independent dashboard on a fixed local URL allowed by Supabase Auth."""
import json
import base64
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
config = root / 'config.json'
if not config.exists():
    source = root.parent / 'config/live.json'
    if not source.exists():
        raise SystemExit('Create dashboard/config.json using config.example.json first.')
    try:
        live = json.loads(source.read_text())
        if not isinstance(live, dict):
            raise ValueError()
        config.write_text(json.dumps({k: live[k] for k in ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','SUPABASE_ANON_KEY'] if k in live}, indent=2)+'\n')
    except (OSError, ValueError, UnicodeError):
        raise SystemExit('Cannot read public config: use a valid JSON object.') from None
try:
    settings = json.loads(config.read_text())
except (OSError, ValueError, UnicodeError):
    raise SystemExit('Cannot read dashboard config: use a valid JSON object.') from None
allowed = {'SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY'}
if not isinstance(settings, dict) or set(settings) - allowed:
    raise SystemExit('Dashboard config may contain only public Supabase client settings.')
def public_key(value):
    if not isinstance(value, str):
        return False
    if value.startswith('sb_publishable_') and len(value) > 20:
        return True
    try:
        parts = value.split('.')
        if len(parts) != 3 or not parts[2]:
            return False
        payload = json.loads(base64.urlsafe_b64decode(parts[1] + '==='))
        return isinstance(payload, dict) and payload.get('role') == 'anon'
    except (ValueError, UnicodeError):
        return False

keys = [settings[name] for name in ('SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY') if name in settings]
if not keys or not all(public_key(key) for key in keys):
    raise SystemExit('Every dashboard key must be a public publishable/anon key, never a privileged or malformed key.')
try:
    subprocess.run(['flutter', 'pub', 'get'], cwd=root, check=True)
    print('\nWhen Flutter reports that the server is ready, open '
          'http://localhost:7357 in Safari, Chrome, or Edge.\n'
          'Keep this terminal running. Press Ctrl+C to stop.\n', flush=True)
    subprocess.run([
        'flutter', 'run', '-d', 'web-server',
        '--web-hostname=localhost', '--web-port=7357',
        '--dart-define-from-file=' + str(config),
    ], cwd=root, check=True)
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode) from None
except KeyboardInterrupt:
    raise SystemExit(0) from None
