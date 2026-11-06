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
config=json.loads(path.read_text());url=config.get('SUPABASE_URL','')
key=config.get('SUPABASE_PUBLISHABLE_KEY') or config.get('SUPABASE_ANON_KEY','')
if not url.startswith('https://') or 'YOUR_PROJECT' in url.upper() or not key or 'YOUR_PUBLIC' in key:
    sys.exit('Enter a real HTTPS Supabase project URL and public publishable/anon key first.')
role=None
try:role=json.loads(base64.urlsafe_b64decode(key.split('.')[1]+'===').decode()).get('role')
except (ValueError,IndexError,UnicodeDecodeError):pass
if key.startswith('sb_secret_') or role=='service_role':sys.exit('Refusing to compile a privileged Supabase key into Android.')
if args.release:sys.exit('Release signing must be configured with your own private keystore before store distribution. Build the installable test APK without --release.')
subprocess.run(['flutter','build','apk','--debug',f'--dart-define-from-file={path}'],cwd=root,check=True)
output=root/'artifacts/CURLYmax-live.apk';output.parent.mkdir(exist_ok=True)
shutil.copy2(root/'build/app/outputs/flutter-apk/app-debug.apk',output)
print(f'Live-only Android test APK: {output}')
