#!/usr/bin/env python3
"""Build a local CURLYmax Studio macOS installer from public client settings."""
import argparse
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root.parent))
from scripts.client_config import load_public_config  # noqa: E402
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', type=Path, default=root / 'config.json')
args = parser.parse_args()

try:
    load_public_config(args.config, app=False)
except ValueError as error:
    raise SystemExit(str(error)) from None
try:
    selected = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
except (OSError, subprocess.CalledProcessError):
    selected = ''
if not selected.endswith('/Contents/Developer'):
    raise SystemExit('Full Xcode is required. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer')

subprocess.run(['flutter', 'pub', 'get'], cwd=root, check=True)
subprocess.run(['flutter', 'build', 'macos', '--release', '--dart-define-from-file=' + str(args.config.resolve())], cwd=root, check=True)
app = root / 'build/macos/Build/Products/Release/CURLYmax Studio.app'
if not app.is_dir():
    raise SystemExit('Flutter completed without the expected macOS app bundle. Check the Xcode build output.')
version = '1.2.0'
output = root.parent / 'artifacts' / f'CURLYmax-Studio-{version}.pkg'
output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['pkgbuild', '--component', str(app), '--install-location', '/Applications', str(output)], check=True)
subprocess.run(['pkgutil', '--check-signature', str(output)], check=False)
print('Installer:', output)
print('This local package is unsigned. Public distribution requires Developer ID signing and notarization.')
