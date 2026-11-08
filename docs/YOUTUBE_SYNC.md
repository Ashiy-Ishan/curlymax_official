# Automatic YouTube updates

The `sync-youtube` Edge Function reads public uploads, public playlists and public video counts from YouTube Data API v3. It resolves `@ashiy_ish` using the channel handle on the first run, then saves the stable YouTube channel ID. No Google account password or YouTube OAuth login is required for these public data.

## Publication behavior

- Enable synchronization for a channel and choose its active default section in Studio → YouTube.
- **The first successful import is always draft.** Review those videos in Studio and publish the ones you want. It sends no backfill notifications.
- With **Automatically publish new uploads** enabled (the default), newly discovered videos on subsequent successful runs are published and enter the existing notification queue once. Disable that option to import later uploads as drafts too.
- Previously imported or manually created videos keep their title, description, section and publication state. Synchronization refreshes their YouTube publication date, thumbnail and public counts only. An existing draft is never automatically promoted.
- A manual video with the same YouTube ID in that channel is reused. If legacy duplicates exist, the oldest row is reused and the other rows are left alone.
- Imported playlists receive `sync_managed=true`. Their membership refreshes from YouTube; only videos in this channel's imported catalog are included. Their existing title, description, thumbnail, visibility and position remain owner-controlled. Manually created playlists default to `sync_managed=false`, and their membership is not changed. An owner can turn off `sync_managed` through Supabase to keep manual membership permanently.
- If a public YouTube playlist disappears, its imported membership is cleared, but the playlist row is retained. Videos removed or made private on YouTube are not automatically deleted or unpublished in CURLYmax; review availability and unpublish those videos in Studio. This avoids silently discarding owner-managed content.

YouTube upload dates determine latest ordering. “Trending” based on these data means **most viewed among imported videos**, using lifetime public view counts; it is not YouTube's global trending ranking or a recent-growth measurement. Missing/disabled counts remain null. Aggregate dashboard counts are for imported videos, not whole-channel Analytics reports. Watch time, revenue, audience demographics and private YouTube Analytics require a separate owner OAuth integration and are not supplied here.

## Set up the server

1. In Google Cloud, select the project used for CURLYmax and enable **YouTube Data API v3**. Create an API key and restrict its API access to **YouTube Data API v3**. Keep the key on the server; do not add it to Flutter configuration or source control.
2. In Supabase → Edge Functions → Secrets, add **`YOUTUBE_API_KEY`** with that value. Add a separately generated random **`YOUTUBE_SYNC_SECRET`** for scheduled calls. This is a different credential from the notification sender secret. Do not paste either secret into chat.
3. Apply migrations in order, including `202611080005_youtube_sync.sql`, to the existing project. `supabase/install.sql` is for an empty project only, not an upgrade script.
4. Deploy from the repository root:

   ```sh
   supabase functions deploy sync-youtube --project-ref qsmnvfkrxzwyjugkbpwp
   ```

   The repository config sets `verify_jwt=false` for this function because the scheduler uses its own secret. The function still authenticates every request itself: a matching scheduler secret, or a verified Supabase user JWT with the database owner membership. Never remove those checks.
5. In Studio, open YouTube settings, select the channel/default section, enable synchronization and save. Leave YouTube channel ID blank to resolve the channel handle automatically. Run Sync once. The returned status should show an initial import, and its videos should be drafts.
6. Publish selected initial drafts through the dashboard. A later newly uploaded public YouTube video should import automatically as published when the next sync runs.

The function never fetches user-provided URLs. It uses fixed Google API endpoints and parameter encoding, uploads-playlist pagination rather than search, batches `videos.list` up to 50 IDs, and commits each complete channel snapshot atomically. Google responses and key-bearing URLs are never written to operational status.

## Schedule every 15 minutes

Save the **same** `YOUTUBE_SYNC_SECRET` value in Supabase Vault with the name `youtube_sync_secret`. The Edge Function secret and Vault secret must match. Use the Dashboard's secret input, rather than committing the value to SQL. Enable Supabase Cron (`pg_cron`) and `pg_net` if not already enabled, then run this SQL (it contains no credential):

```sql
select cron.schedule(
  'youtube-catalog-sync',
  '*/15 * * * *',
  $$select net.http_post(
    url := 'https://qsmnvfkrxzwyjugkbpwp.supabase.co/functions/v1/sync-youtube',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'youtube_sync_secret' limit 1
      )
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );$$
);
```

Empty-body calls process enabled, active channels oldest-sync-first (up to five per invocation) within a shared 100-second API budget. A per-channel 10-minute lease prevents overlapping imports. The next schedule continues with older unsynced channels. An owner can run a single channel immediately by invoking `sync-youtube` with `{"channel_id":"CHANNEL_UUID"}` and their existing JWT. Save-settings operations invalidate running leases so an old job cannot commit after settings change.

Safe scheduler status (no credentials):

```sql
select status, return_message, start_time, end_time
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname='youtube-catalog-sync')
order by start_time desc limit 10;
```

Cron success means the HTTP request was scheduled, not that YouTube finished. Check Studio's **last successful synchronization** and **last error**, or Edge Function invocation status. Missing server API key returns HTTP 503. Invalid token returns 401; signed-in non-owner returns 403. Provider quota/access errors leave existing catalog data unchanged. Notification dispatch still uses the separate `notify-published` worker; an imported published video can remain pending if that worker is not scheduled/configured.

## Limits and verification

Each channel snapshot supports at most 1,000 upload IDs, 50 public playlists and 1,000 items per playlist, with at most 100 Google requests and a shared request deadline. If any limit, provider error or quota error is reached, the channel snapshot is not partially committed. Large catalogs need a resumable import extension before enabling synchronization. Avoid frequent manual refreshes: each scheduled snapshot refreshes counts and memberships, which consume YouTube quota. Lease failures safely expire; a previous successful catalog remains available.

Run local regression checks:

```sh
node --experimental-strip-types --test test/youtube_sync_test.mjs
python3 scripts/test_quiz_feedback.py
```

The second command uses a disposable, network-isolated PostgreSQL Docker container. Tests cover guest/viewer denial, private settings, same-channel memberships, concurrent sync lease exclusion, initial drafts, future automatic publication once, unchanged manual titles/drafts, public metric refresh, and playlist RLS. Mocked Google tests cover pagination, batching, private/foreign video filtering, deadlines, bounds, quota failures and credential-safe errors. They do not prove real Google credentials, hosted scheduling or end-to-end Android notifications. Complete one live import and a later-upload notification test after server configuration.
