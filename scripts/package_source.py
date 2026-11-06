#!/usr/bin/env python3
"""Package portable source and selected verification evidence, without local config or build caches."""
from pathlib import Path
import zipfile
root=Path(__file__).resolve().parents[1]
output=root/'artifacts/CURLYmax-source.zip'
skip_dirs={'.git','.dart_tool','.idea','.gradle','.cxx','build','.temp','.branches','.vscode','.aws','.agents','.codex','__pycache__'}
reports={'live-flutter-analyze.txt','live-flutter-tests.txt','live-backend-verification.txt','live-sdk-verification.txt','live-android-build.txt','live-apk-signature.txt','live-apk-manifest.txt','live-android-verification.txt'}
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob('*')):
        relative=path.relative_to(root)
        if not path.is_file() or any(part in skip_dirs for part in relative.parts): continue
        if path.name == '.DS_Store': continue
        if path.name.startswith('.env') or path.suffix in {'.iml','.apk','.zip','.jks','.keystore'}: continue
        if str(relative) in {'android/local.properties','android/key.properties','config/live.json','config/google-services.json'}: continue
        if relative.parts[0]=='artifacts' and path.name not in reports and path.name not in {'live-android-home.png','live-android-icon.png'}: continue
        if relative.parts[0]=='config' and path.name.endswith('.local.json'): continue
        archive.write(path,Path('CURLYmax')/relative)
print(output)
