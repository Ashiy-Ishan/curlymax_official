#!/usr/bin/env python3
"""Run the independent dashboard on a fixed local URL allowed by Supabase Auth."""
import json
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
config = root / 'config.json'
if not config.exists():
    source = root.parent / 'config/live.json'
    if not source.exists():
        raise SystemExit('Create dashboard/config.json using config.example.json first.')
    live = json.loads(source.read_text())
    config.write_text(json.dumps({k: live[k] for k in ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY']}, indent=2)+'\n')
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
