#!/usr/bin/env python3
"""Scan public source/index (and optionally history) without printing secrets."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess

PRIVATE_KEY = re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')
SECRET_KEY = re.compile(r'sb_secret_[A-Za-z0-9_-]{20,}|GOCSPX-[A-Za-z0-9_-]{20,}')
JWT = re.compile(r'[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}')


def findings(content):
    """Return categories only, never secret values or matching source lines."""
    result = set()
    if PRIVATE_KEY.search(content): result.add('private key')
    if SECRET_KEY.search(content): result.add('server secret key')
    try:
        value = json.loads(content)
        if isinstance(value, dict) and value.get('type') == 'service_account':
            result.add('service-account JSON')
    except (ValueError, TypeError):
        pass
    for match in JWT.finditer(content):
        try:
            payload = json.loads(base64.urlsafe_b64decode(match.group().split('.')[1] + '==='))
            if isinstance(payload, dict) and payload.get('role') == 'service_role':
                result.add('legacy service-role JWT')
        except (ValueError, UnicodeError):
            pass
    return sorted(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true', help='Also scan text blobs in reachable Git history.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
    problems = []
    scanned = set()
    for name in filter(None, paths):
        path = root / name
        # Scan the working copy and staged copy, including a staged file that
        # was subsequently removed or cleaned in the working tree.
        candidates = []
        if path.is_file() and not path.is_symlink():
            candidates.append(('worktree', path.read_bytes()))
        stage = subprocess.run(['git', 'show', ':' + name], cwd=root, capture_output=True)
        if stage.returncode == 0: candidates.append(('index', stage.stdout))
        for source, raw in candidates:
            if b'\0' in raw: continue
            text = raw.decode('utf-8', errors='replace')
            for category in findings(text): problems.append((source + ':' + name, category))
            scanned.add((source, name))
    if args.history:
        records = subprocess.check_output(['git', 'rev-list', '--objects', '--all'], cwd=root).decode().splitlines()
        for record in records:
            parts = record.split(' ', 1)
            if len(parts) != 2: continue
            oid, name = parts
            kind = subprocess.check_output(['git', 'cat-file', '-t', oid], cwd=root).strip()
            if kind != b'blob': continue
            size = int(subprocess.check_output(['git', 'cat-file', '-s', oid], cwd=root))
            if size > 5_000_000:
                continue  # Binary/large-artifact audit is a separate check.
            raw = subprocess.check_output(['git', 'cat-file', '-p', oid], cwd=root)
            if b'\0' in raw: continue
            for category in findings(raw.decode('utf-8', errors='replace')):
                problems.append(('history:' + oid[:12] + ':' + name, category))
    for name, category in sorted(set(problems)):
        print(f'FAIL {name}: {category}')
    if problems: raise SystemExit(1)
    print(f'PASS: {len(scanned)} public source/index copies scanned; no recognized privileged credential pattern.')
    print('Public publishable/Firebase client keys are not private credentials. This scan does not prove key revocation or detect every secret format.')


if __name__ == '__main__':
    main()
