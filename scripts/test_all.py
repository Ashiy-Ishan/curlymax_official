#!/usr/bin/env python3
"""Run credential-free checks. Database tests use only a disposable local container."""
import argparse
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--with-database', action='store_true')
args = parser.parse_args()
commands = [
    ([sys.executable, 'scripts/secret_scan.py'], root),
    (['flutter', 'analyze'], root),
    (['flutter', 'test', '--reporter', 'expanded'], root),
    (['flutter', 'analyze'], root / 'dashboard'),
    (['flutter', 'test', '--reporter', 'expanded'], root / 'dashboard'),
    (['node', '--experimental-strip-types', '--test'] + [str(p.relative_to(root)) for p in sorted((root / 'test').glob('*_test.mjs'))], root),
]
for script in ('test_security_scripts.py', 'test_release_security.py', 'test_youtube_setup.py'):
    commands.append(([sys.executable, 'scripts/' + script], root))
if args.with_database:
    commands.append(([sys.executable, 'scripts/test_quiz_feedback.py'], root))
for command, cwd in commands:
    print('Running:', ' '.join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)
print('All selected checks passed. This does not verify live OAuth, push delivery or Play approval.')
