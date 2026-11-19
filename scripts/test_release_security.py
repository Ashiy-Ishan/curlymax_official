"""Offline regressions for credential boundaries and release packaging."""
import base64
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from client_config import load_public_config
from secret_scan import findings


def token(role):
    encode = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    return encode({'alg': 'HS256'}) + '.' + encode({'role': role}) + '.synthetic_signature'


class ReleaseSecurityTests(unittest.TestCase):
    def test_privileged_jwt_detected_but_public_anon_allowed(self):
        self.assertIn('legacy service-role JWT', findings(token('service_role')))
        self.assertEqual(findings(token('anon')), [])

    def test_packager_checks_sql_and_preserves_previous_archive_on_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'artifacts').mkdir()
            for name in ('package_source.py', 'secret_scan.py'):
                shutil.copy2(Path(__file__).parent / name, root / 'scripts' / name)
            archive = root / 'artifacts/CURLYmax-source.zip'
            archive.write_bytes(b'previous-safe-archive')
            (root / 'accidental.sql').write_text('-- ' + token('service_role'))
            result = subprocess.run([sys.executable, str(root / 'scripts/package_source.py')], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(archive.read_bytes(), b'previous-safe-archive')
            self.assertNotIn(token('service_role'), result.stderr)

    def test_read_only_checker_rejects_privileged_key_before_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'config').mkdir()
            for name in ('check_live_backend.py', 'client_config.py'):
                shutil.copy2(Path(__file__).parent / name, root / 'scripts' / name)
            (root / 'config/live.json').write_text(json.dumps({
                'SUPABASE_URL': 'https://127.0.0.1:9', 'SUPABASE_PUBLISHABLE_KEY': token('service_role'),
            }))
            result = subprocess.run([sys.executable, str(root / 'scripts/check_live_backend.py')], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('privileged', result.stderr)
            self.assertNotIn('Traceback', result.stderr)
            self.assertNotIn('HTTP', result.stdout)

    def test_public_config_rejects_credentials_urls_and_wrong_types(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            for url in ('https://user:password@example.com', 'https://example.com/api', 'https://example.com?key=bad', 'http://example.com'):
                path.write_text(json.dumps({'SUPABASE_URL': url, 'SUPABASE_PUBLISHABLE_KEY': 'sb_publishable_synthetic_public_value'}))
                with self.assertRaises(ValueError): load_public_config(path)

    def test_release_requires_signing_before_flutter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            for name in ('build_android.py', 'client_config.py'):
                shutil.copy2(Path(__file__).parent / name, root / 'scripts' / name)
            config = root / 'client.json'
            config.write_text(json.dumps({'SUPABASE_URL': 'https://example.supabase.co', 'SUPABASE_PUBLISHABLE_KEY': 'sb_publishable_synthetic_public_value'}))
            result = subprocess.run([sys.executable, str(root / 'scripts/build_android.py'), '--release', '--config', str(config)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('setup_signing.py', result.stderr)


if __name__ == '__main__':
    unittest.main()
