#!/usr/bin/env python3
"""Package portable source and selected verification evidence, without local config or build caches."""
from pathlib import Path
import zipfile
import json
import re
import tempfile
root=Path(__file__).resolve().parents[1]
output=root/'artifacts/CURLYmax-source.zip'
skip_dirs={'.git','.dart_tool','.idea','.gradle','.cxx','build','.temp','.branches','.vscode','.aws','.agents','.codex','__pycache__'}
reports={'quiz-feedback-analyze.txt','quiz-feedback-tests.txt','quiz-feedback-backend.txt','quiz-feedback-android-build.txt','quiz-dashboard-analyze.txt','quiz-dashboard-tests.txt','quiz-feedback-verification.txt','live-flutter-analyze.txt','live-flutter-tests.txt','live-backend-verification.txt','live-sdk-verification.txt','live-android-build.txt','live-apk-signature.txt','live-apk-manifest.txt','live-android-verification.txt'}
output.parent.mkdir(exist_ok=True)
# Publish only a completely validated archive; never leave a partial source package.
with tempfile.TemporaryDirectory(dir=output.parent) as staging:
 with zipfile.ZipFile(Path(staging)/'source.zip','w',zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob('*')):
        relative=path.relative_to(root)
        if path.is_symlink() or not path.is_file() or any(part in skip_dirs for part in relative.parts): continue
        if not path.resolve().is_relative_to(root.resolve()): continue
        if path.name in {'.DS_Store','.flutter-plugins-dependencies'}: continue
        if path.name in {'local.properties','key.properties'} and 'android' in relative.parts: continue
        if path.name.startswith('.env') or path.suffix in {'.iml','.apk','.zip','.jks','.keystore','.pem','.key','.p12','.pfx'}: continue
        if str(relative) in {'android/local.properties','android/key.properties','config/live.json','config/google-services.json','dashboard/config.json','mobile_dashboard/config.json','dashboard_mobile/config.json'}: continue
        if relative.parts[0]=='artifacts' and path.name not in reports and path.name not in {'live-android-home.png','live-android-icon.png'}: continue
        if relative.parts[0]=='config' and path.name.endswith('.local.json'): continue
        # Fail closed if an accidentally copied credential escaped the path exclusions.
        if path.suffix in {'.json', '.yaml', '.yml', '.toml', '.dart', '.ts', '.py', '.txt', '.md'}:
            contents = path.read_text(errors='replace')
            if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|sb_secret_[A-Za-z0-9_-]{32,}', contents):
                raise SystemExit(f'Refusing to package possible private credentials in {relative}')
            if path.suffix == '.json':
                try:
                    document = json.loads(contents)
                except ValueError:
                    document = None
                if isinstance(document, dict) and (document.get('type') == 'service_account' or 'private_key' in document):
                    raise SystemExit(f'Refusing to package a service-account file: {relative}')
        archive.write(path,Path('CURLYmax')/relative)
 (Path(staging)/'source.zip').replace(output)
print(output)
