"""Credential transport and cleanup regression with a mocked Supabase CLI."""
import contextlib
import io
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import setup_youtube_sync as setup


class SetupSecurityTests(unittest.TestCase):
    def test_rejects_sql_input_in_project_reference(self):
        with self.assertRaises(ValueError):
            setup.scheduler_sql("bad'; select 1;--", 'a' * 64)

    def test_credentials_are_files_only_and_removed_after_success(self):
        api = 'synthetic_' + 'a' * 30
        secret = 'b' * 64
        temporary_paths = []

        def cli(command, **kwargs):
            self.assertNotIn(api, ' '.join(command))
            self.assertNotIn(secret, ' '.join(command))
            if '--env-file' in command:
                env = Path(command[command.index('--env-file') + 1])
                temporary_paths.append(env)
                self.assertEqual(env.stat().st_mode & 0o777, 0o600)
                self.assertIn(api, env.read_text())
            if '--file' in command:
                sql = Path(command[command.index('--file') + 1])
                temporary_paths.append(sql)
                self.assertNotIn(api, sql.read_text())
                self.assertIn('vault.decrypted_secrets', sql.read_text())
            return SimpleNamespace(returncode=0, stdout=api + secret, stderr='')

        output = io.StringIO()
        with patch('sys.argv', ['setup', '--project-ref', 'a' * 20]), \
                patch.object(setup.getpass, 'getpass', return_value=api), \
                patch.object(setup.secrets, 'token_hex', return_value=secret), \
                patch.object(setup.subprocess, 'run', side_effect=cli), \
                contextlib.redirect_stdout(output):
            setup.main()
        self.assertTrue(temporary_paths)
        self.assertTrue(all(not path.exists() for path in temporary_paths))
        self.assertNotIn(api, output.getvalue())
        self.assertNotIn(secret, output.getvalue())

    def test_cli_failure_redacts_credentials_and_removes_files(self):
        api = 'synthetic_' + 'c' * 30
        secret = 'd' * 64
        paths = []

        def fail(command, **kwargs):
            paths.append(Path(command[command.index('--env-file') + 1]))
            return SimpleNamespace(returncode=1, stdout='', stderr=api + secret)

        output = io.StringIO()
        with patch('sys.argv', ['setup', '--project-ref', 'a' * 20]), \
                patch.object(setup.getpass, 'getpass', return_value=api), \
                patch.object(setup.secrets, 'token_hex', return_value=secret), \
                patch.object(setup.subprocess, 'run', side_effect=fail), \
                contextlib.redirect_stdout(output), self.assertRaises(SystemExit):
            setup.main()
        self.assertTrue(all(not path.exists() for path in paths))
        self.assertNotIn(api, output.getvalue())
        self.assertNotIn(secret, output.getvalue())


if __name__ == '__main__':
    unittest.main()
