"""Offline regression tests. Only synthetic credentials in isolated temporary trees."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SOURCE = Path(__file__).resolve().parent


class ScriptSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'artifacts').mkdir()
        for name in ('package_source.py', 'build_android.py'):
            shutil.copy2(SOURCE / name, self.root / 'scripts' / name)

    def run_script(self, name, *args):
        return subprocess.run([sys.executable, str(self.root / 'scripts' / name), *args],
                              capture_output=True, text=True)

    def test_package_excludes_config_and_symlink(self):
        (self.root / 'mobile_dashboard').mkdir()
        (self.root / 'mobile_dashboard/config.json').write_text('{}')
        (self.root / 'outside-link').symlink_to('/etc/hosts')
        (self.root / 'private.pem').write_text('synthetic private material')
        result = self.run_script('package_source.py')
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.root / 'artifacts/CURLYmax-source.zip') as archive:
            names = archive.namelist()
        self.assertFalse(any('config.json' in n or 'outside-link' in n or 'private.pem' in n for n in names))

    def test_service_account_refused_without_partial_archive(self):
        (self.root / 'accidental.json').write_text(json.dumps({'type': 'service_account', 'private_key': 'synthetic'}))
        result = self.run_script('package_source.py')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'artifacts/CURLYmax-source.zip').exists())
        self.assertNotIn('synthetic', result.stderr)

    def test_build_rejects_extra_server_setting_before_flutter(self):
        config = self.root / 'client.json'
        config.write_text(json.dumps({'SUPABASE_URL': 'https://example.supabase.co',
                                     'SUPABASE_PUBLISHABLE_KEY': 'public-test',
                                     'SCHEDULER_SECRET': 'synthetic'}))
        result = self.run_script('build_android.py', '--config', str(config))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('only documented public', result.stderr)
        self.assertNotIn('synthetic', result.stderr)

    def test_build_rejects_privileged_key(self):
        config = self.root / 'client.json'
        config.write_text(json.dumps({'SUPABASE_URL': 'https://example.supabase.co',
                                     'SUPABASE_PUBLISHABLE_KEY': 'sb_' + 'secret_' + 'synthetic'}))
        result = self.run_script('build_android.py', '--config', str(config))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('privileged', result.stderr)

    def test_all_keys_and_malformed_configs_rejected_by_both_launchers(self):
        dashboard = self.root / 'dashboard'
        (dashboard / 'scripts').mkdir(parents=True)
        shutil.copy2(SOURCE.parent / 'dashboard/scripts/run.py', dashboard / 'scripts/run.py')
        public = 'sb_publishable_' + 'synthetic_public_value'
        import base64
        unknown_role = 'header.' + base64.urlsafe_b64encode(b'{"role":"authenticated"}').decode().rstrip('=') + '.signature'
        cases = [
            {'SUPABASE_URL': 'https://example.supabase.co', 'SUPABASE_PUBLISHABLE_KEY': public,
             'SUPABASE_ANON_KEY': 'sb_' + 'secret_' + 'synthetic'},
            {'SUPABASE_URL': 'https://example.supabase.co', 'SUPABASE_PUBLISHABLE_KEY': public,
             'SUPABASE_ANON_KEY': unknown_role},
            {'SUPABASE_URL': 'https://example.supabase.co', 'SUPABASE_PUBLISHABLE_KEY': 123},
            {'SUPABASE_URL': 'https://example.supabase.co', 'SUPABASE_PUBLISHABLE_KEY': 'x.W10.x'},
            [],
        ]
        for body in [json.dumps(case) for case in cases] + ['{bad json']:
            for launcher in ('build', 'dashboard'):
                with self.subTest(body=body, launcher=launcher):
                    config = (self.root / 'client.json') if launcher == 'build' else dashboard / 'config.json'
                    config.write_text(body)
                    if launcher == 'build':
                        result = self.run_script('build_android.py', '--config', str(config))
                    else:
                        result = subprocess.run([sys.executable, str(dashboard / 'scripts/run.py')], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('Traceback', result.stderr)
                    self.assertNotIn('synthetic', result.stderr)


if __name__ == '__main__':
    unittest.main()
