#!/usr/bin/env python3
"""Package portable source and selected verification evidence, without local config or build caches."""
from pathlib import Path
import zipfile
root=Path(__file__).resolve().parents[1]
output=root/'artifacts/CURLYmax-source.zip'
skip_dirs={'.git','.dart_tool','.idea','.gradle','.cxx','build','.temp','.branches','.vscode','.aws','.agents','.codex','__pycache__'}
reports={'flutter-analyze.txt','flutter-tests.txt','backend-verification.txt','realtime-verification.txt','android-build.txt','apk-signature.txt','apk-manifest.txt','android-verification.txt'}
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob('*')):
        relative=path.relative_to(root)
        if not path.is_file() or any(part in skip_dirs for part in relative.parts): continue
        if path.name == '.DS_Store': continue
        if path.name.startswith('.env') or path.suffix in {'.iml','.apk','.zip','.jks','.keystore'}: continue
        if str(relative) in {'android/local.properties','android/key.properties','config/live.json'}: continue
        if relative.parts[0]=='artifacts' and path.name not in reports and path.name not in {'android-home.png','android-player.png','android-playback.png'}: continue
        archive.write(path,Path('CURLYmax')/relative)
print(output)
