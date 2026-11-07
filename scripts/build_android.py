#!/usr/bin/env python3
"""Build a configured live-only Android APK. Never silently builds sample content."""
import argparse,base64,json,shutil,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--config',default='config/live.json')
parser.add_argument('--release',action='store_true',help='Requires a private release signing configuration.')
args=parser.parse_args()
path=root/args.config
if not path.exists():sys.exit('Missing config/live.json. Copy config/live.example.json and enter the public client settings.')
try:
    config=json.loads(path.read_text())
except (OSError, ValueError, UnicodeError):
    sys.exit('Cannot read build config: use a valid JSON object with public client settings.')
allowed_settings={'SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','SUPABASE_ANON_KEY','FCM_ENABLED','FIREBASE_API_KEY','FIREBASE_APP_ID','FIREBASE_SENDER_ID','FIREBASE_PROJECT_ID'}
if not isinstance(config,dict) or set(config)-allowed_settings:
    sys.exit('Build config must contain only documented public client settings. Remove unknown or server-only fields.')
url=config.get('SUPABASE_URL','')
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

keys=[config[name] for name in ('SUPABASE_PUBLISHABLE_KEY','SUPABASE_ANON_KEY') if name in config]
if not keys or not all(public_key(key) for key in keys):
    sys.exit('Refusing invalid or privileged Supabase keys: every configured key must be public publishable/anon.')
if not isinstance(url,str) or not url.startswith('https://') or 'YOUR_PROJECT' in url.upper():
    sys.exit('Enter a real HTTPS Supabase project URL first.')
if args.release:sys.exit('Release signing must be configured with your own private keystore before store distribution. Build the installable test APK without --release.')
subprocess.run(['flutter','build','apk','--debug',f'--dart-define-from-file={path}'],cwd=root,check=True)
output=root/'artifacts/CURLYmax-live.apk';output.parent.mkdir(exist_ok=True)
shutil.copy2(root/'build/app/outputs/flutter-apk/app-debug.apk',output)
print(f'Live-only Android test APK: {output}')
