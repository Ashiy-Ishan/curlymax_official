#!/usr/bin/env python3
"""Run the independent dashboard on a fixed local URL allowed by Supabase Auth."""
import argparse
import json
import base64
import subprocess
from pathlib import Path
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', default='web-server', help='web-server, macos, or a Flutter device ID')
args = parser.parse_args()
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
        config.write_text(json.dumps({k: live[k] for k in ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','SUPABASE_ANON_KEY','GOOGLE_WEB_CLIENT_ID'] if k in live}, indent=2)+'\n')
    except (OSError, ValueError, UnicodeError):
        raise SystemExit('Cannot read public config: use a valid JSON object.') from None
try:
    settings = json.loads(config.read_text())
except (OSError, ValueError, UnicodeError):
    raise SystemExit('Cannot read dashboard config: use a valid JSON object.') from None
allowed = {'SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY', 'GOOGLE_WEB_CLIENT_ID'}
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
    command = ['flutter', 'run', '-d', args.device,
               '--dart-define-from-file=' + str(config)]
    if args.device == 'web-server':
        command += ['--web-hostname=localhost', '--web-port=7357']
        print('Open http://localhost:7357 when Flutter is ready. Keep this terminal running.', flush=True)
    subprocess.run(command, cwd=root, check=True)
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode) from None
except KeyboardInterrupt:
    raise SystemExit(0) from None
