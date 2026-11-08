#!/usr/bin/env python3
"""Install the server-only YouTube key, worker, and 15-minute scheduler.

Run after migration 005. Requires an authenticated Supabase CLI. Credentials
are read without echo and passed in owner-only temporary files, never argv.
"""
import argparse
import getpass
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile


def scheduler_sql(project_ref, scheduler_secret):
    # Both inputs are constrained before interpolation; the API key is not SQL.
    if not re.fullmatch(r'[a-z0-9]{20}', project_ref):
        raise ValueError('Invalid Supabase project reference')
    if not re.fullmatch(r'[a-f0-9]{64}', scheduler_secret):
        raise ValueError('Invalid generated scheduler credential')
    return f"""begin;
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
do $$ declare existing uuid; begin
 if to_regprocedure('public.sync_youtube_targets()') is null then
  raise exception 'Apply migration 005 before installing the YouTube scheduler';
 end if;
 select id into existing from vault.secrets where name='curlymax_youtube_sync_secret';
 if existing is null then
  perform vault.create_secret('{scheduler_secret}','curlymax_youtube_sync_secret','YouTube sync scheduler');
 else
  perform vault.update_secret(existing,'{scheduler_secret}','curlymax_youtube_sync_secret','YouTube sync scheduler');
 end if;
end $$;
select cron.unschedule(jobid) from cron.job where jobname='curlymax-youtube-sync';
select cron.schedule('curlymax-youtube-sync','*/15 * * * *',$job$
 select net.http_post(
  url := 'https://{project_ref}.supabase.co/functions/v1/sync-youtube',
  headers := jsonb_build_object('Content-Type','application/json','Authorization',
   'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='curlymax_youtube_sync_secret')),
  body := '{{}}'::jsonb, timeout_milliseconds := 120000
 );
$job$);
commit;
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-ref', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9]{20}', args.project_ref):
        parser.error('Use the 20-character Supabase project reference.')
    api_key = getpass.getpass('YouTube Data API v3 key (hidden; server only): ').strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]{20,200}', api_key):
        raise SystemExit('Invalid key format. Nothing was uploaded.')
    scheduler_secret = secrets.token_hex(32)
    root = Path(__file__).resolve().parents[1]
    def run(command, *, quiet=False):
        result = subprocess.run(command, cwd=root, capture_output=True, text=True)
        if result.returncode:
            safe_error = (result.stderr or result.stdout).replace(api_key, '[redacted]').replace(scheduler_secret, '[redacted]')
            print(safe_error[-3000:])
            raise subprocess.CalledProcessError(result.returncode, command)
        if not quiet:
            print('Completed:', ' '.join(command[:3]))
    try:
        with tempfile.TemporaryDirectory(prefix='curlymax-youtube-') as directory:
            env = Path(directory) / 'server.env'
            sql = Path(directory) / 'scheduler.sql'
            env.touch(mode=0o600)
            sql.touch(mode=0o600)
            os.chmod(env, 0o600)
            os.chmod(sql, 0o600)
            env.write_text(f'YOUTUBE_API_KEY={api_key}\nYOUTUBE_SYNC_SECRET={scheduler_secret}\n')
            sql.write_text(scheduler_sql(args.project_ref, scheduler_secret))
            run(['supabase', 'secrets', 'set', '--project-ref', args.project_ref,
                 '--env-file', str(env)])
            run(['supabase', 'functions', 'deploy', 'sync-youtube', '--project-ref',
                 args.project_ref, '--no-verify-jwt'])
            run(['supabase', 'db', 'query', '--project-ref', args.project_ref,
                 '--linked', '--file', str(sql)], quiet=True)
    except subprocess.CalledProcessError:
        raise SystemExit('Setup did not finish. Check the CLI error, then rerun this command; temporary credentials were removed.') from None
    print('Server configured. In Studio → YouTube, choose a channel and section, enable sync, save, then Sync now. Scheduled updates run every 15 minutes.')


if __name__ == '__main__':
    main()
