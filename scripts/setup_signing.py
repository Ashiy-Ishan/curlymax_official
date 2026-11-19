#!/usr/bin/env python3
"""Create a private upload key locally. Never overwrite an existing key/config."""
import os
from pathlib import Path
import secrets
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
directory = root / '.signing'
keystore = directory / 'curlymax-upload.jks'
properties = root / 'android/key.properties'
if keystore.exists() or properties.exists():
    raise SystemExit('Signing already exists. Preserve and back up the existing key; nothing changed.')
keytool = shutil.which('keytool')
if not keytool:
    raise SystemExit('Install a JDK or add Android Studio’s JDK bin folder to PATH first.')
directory.mkdir(mode=0o700, exist_ok=True)
os.chmod(directory, 0o700)
password = secrets.token_urlsafe(36)
environment = dict(os.environ, CURLYMAX_SIGNING_PASSWORD=password)
command = [keytool, '-genkeypair', '-v', '-keystore', str(keystore), '-storetype', 'JKS',
           '-alias', 'curlymax-upload', '-keyalg', 'RSA', '-keysize', '3072', '-validity', '10000',
           '-dname', 'CN=CURLYmax Upload, O=CURLYmax',
           '-storepass:env', 'CURLYMAX_SIGNING_PASSWORD', '-keypass:env', 'CURLYMAX_SIGNING_PASSWORD']
result = subprocess.run(command, env=environment, capture_output=True, text=True)
if result.returncode:
    raise SystemExit('Key creation failed. Check your JDK and local permissions. No password was printed.')
os.chmod(keystore, 0o600)
descriptor = os.open(properties, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, 'w') as stream:
    stream.write(f'storeFile={keystore.as_posix()}\nstorePassword={password}\nkeyPassword={password}\nkeyAlias=curlymax-upload\n')
print('Private upload key created. Back up .signing/ and android/key.properties securely together.')
print('Neither file belongs in Git, a source ZIP, or a public release attachment.')
