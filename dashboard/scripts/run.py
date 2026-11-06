#!/usr/bin/env python3
"""Run the independent dashboard on a fixed local URL allowed by Supabase Auth."""
import json, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
config = root / 'config.json'
if not config.exists():
    source = root.parent / 'config/live.json'
    if not source.exists():
        raise SystemExit('Create dashboard/config.json using config.example.json first.')
    live = json.loads(source.read_text())
    config.write_text(json.dumps({k: live[k] for k in ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY']}, indent=2)+'\n')
subprocess.run(['flutter','pub','get'], cwd=root, check=True)
subprocess.run(['flutter','run','-d','chrome','--web-port=7357','--dart-define-from-file='+str(config)], cwd=root, check=True)
