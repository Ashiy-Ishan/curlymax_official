#!/usr/bin/env python3
"""Build configured Android test APKs or privately signed release APKs/AABs."""
import argparse
from pathlib import Path
import shutil
import subprocess
from client_config import load_public_config

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', default='config/live.json')
parser.add_argument('--release', action='store_true')
parser.add_argument('--format', choices=['apk', 'aab'], default='apk')
parser.add_argument('--universal', action='store_true', help='Release APK for all architectures; larger download.')
args = parser.parse_args()
config_path = (root / args.config).resolve()
try:
    config = load_public_config(config_path)
except ValueError as error:
    raise SystemExit(str(error)) from None
if args.format == 'aab' and not args.release:
    parser.error('A Play App Bundle requires --release.')
if args.release:
    if not (root / 'android/key.properties').is_file():
        raise SystemExit('Run python3 scripts/setup_signing.py first. Release builds never use debug signing.')
    for field in ('PRIVACY_POLICY_URL', 'ACCOUNT_DELETION_URL', 'SUPPORT_EMAIL'):
        if not config.get(field):
            raise SystemExit(f'Set public {field} in the client config before a release build.')

kind = 'appbundle' if args.format == 'aab' else 'apk'
command = ['flutter', 'build', kind, '--release' if args.release else '--debug',
           f'--dart-define-from-file={config_path}']
if args.release and kind == 'apk' and not args.universal:
    command.append('--split-per-abi')
subprocess.run(command, cwd=root, check=True)
artifacts = root / 'artifacts'
artifacts.mkdir(exist_ok=True)
if kind == 'appbundle':
    pairs = [(root / 'build/app/outputs/bundle/release/app-release.aab', artifacts / 'CURLYmax-release.aab')]
elif args.release and not args.universal:
    pairs = [(root / f'build/app/outputs/flutter-apk/app-{abi}-release.apk', artifacts / f'CURLYmax-{abi}-release.apk')
             for abi in ('armeabi-v7a', 'arm64-v8a', 'x86_64')]
else:
    filename = 'app-release.apk' if args.release else 'app-debug.apk'
    output = 'CURLYmax-release.apk' if args.release else 'CURLYmax-live.apk'
    pairs = [(root / 'build/app/outputs/flutter-apk' / filename, artifacts / output)]
for source, destination in pairs:
    shutil.copy2(source, destination)
    print(destination)
