# Automatic YouTube updates

The `sync-youtube` Edge Function reads public uploads, public playlists and public video counts from YouTube Data API v3. It resolves `@ashiy_ish` using the channel handle on the first run, then saves the stable YouTube channel ID. No Google account password or YouTube OAuth login is required for these public data.

## Publication behavior

- Enable synchronization for a channel and choose its active default section in Studio → YouTube.
- **Public YouTube uploads appear automatically, including the first import**, when automatic publication is enabled. The first backfill is silent: old uploads do not generate a burst of notifications. Quizzes are still created, reviewed and published manually in Studio.
- With **Automatically publish new uploads** enabled (the default), newly discovered videos are published; after the initial silent backfill, each new video enters the existing notification queue once. Disable that option to import new videos as drafts instead.
- Previously imported or manually created videos keep their title, description, section and publication state. Synchronization refreshes their YouTube publication date, thumbnail and public counts only. An existing draft is never automatically promoted.
- Deleting an imported video can cause it to be re-imported on the next synchronization. Keep it as a draft to hide it persistently, or disable synchronization before deleting it.
- A manual video with the same YouTube ID in that channel is reused. If legacy duplicates exist, the oldest row is reused and the other rows are left alone.
- Imported playlists receive `sync_managed=true`. Their membership refreshes from YouTube; only videos in this channel's imported catalog are included. Their existing title, description, thumbnail, visibility and position remain owner-controlled. Manually created playlists default to `sync_managed=false`, and their membership is not changed. An owner can turn off `sync_managed` through Supabase to keep manual membership permanently.
- If a public YouTube playlist disappears, its imported membership is cleared, but the playlist row is retained. Videos removed or made private on YouTube are not automatically deleted or unpublished in CURLYmax; review availability and unpublish those videos in Studio. This avoids silently discarding owner-managed content.

YouTube upload dates determine latest ordering. “Trending” based on these data means **most viewed among imported videos**, using lifetime public view counts; it is not YouTube's global trending ranking or a recent-growth measurement. Missing/disabled counts remain null. Aggregate dashboard counts are for imported videos, not whole-channel Analytics reports. Watch time, revenue, audience demographics and private YouTube Analytics require a separate owner OAuth integration and are not supplied here.

## Set up the server

1. In Google Cloud, select the project used for CURLYmax and enable **YouTube Data API v3**. Create an API key and restrict its API access to **YouTube Data API v3**. Keep the key on the server; do not add it to Flutter configuration or source control.
2. Apply migrations in order through `202611080008_youtube_channel_avatar.sql` to an existing project. `supabase/install.sql` is for an empty project only. The authenticated Supabase CLI must be installed and signed in to your project.
3. From the repository root run:

   ```sh
   python3 scripts/setup_youtube_sync.py --project-ref qsmnvfkrxzwyjugkbpwp
   ```

   Enter the YouTube API key at the hidden terminal prompt. The helper sends it directly to Supabase's server secrets, generates a separate `YOUTUBE_SYNC_SECRET`, deploys the worker, and configures the matching Vault credential and 15-minute Cron job. Neither credential is compiled into either app. Temporary files have owner-only permissions and are removed afterward. Do not paste credentials into chat. If the command fails, review its redacted CLI error and rerun it.
4. In Studio → YouTube → Configure, select the channel and active import section. Leave the UC channel ID blank to resolve the saved handle, enable synchronization, keep automatic publication enabled, and save. Select **Sync now**. The first successful import publishes its public videos automatically without backfill alerts.
5. Public uploads appear in the viewer app automatically. Create a linked quiz using **Quizzes → New quiz**: select the video, enter its title/question and two to four answer options, and choose the correct answer. Creation saves the quiz and private answer key together as a draft. Review it, then publish manually. Later new public uploads are published automatically at the next scheduled sync.

The function's gateway JWT check is disabled because the scheduler uses a separate secret. Every call is authenticated inside the function: matching scheduler secret, or a verified Supabase user JWT plus database owner membership. Never remove those checks.

The function never fetches user-provided URLs. It uses fixed Google API endpoints and parameter encoding, uploads-playlist pagination rather than search, batches `videos.list` up to 50 IDs, and commits each complete channel snapshot atomically. Google responses and key-bearing URLs are never written to operational status.

## Schedule every 15 minutes

The setup helper installs `curlymax-youtube-sync` every 15 minutes. Its credential is stored in Vault as `curlymax_youtube_sync_secret`, matching the Edge Function secret. No credential is embedded in the Cron command. Running the helper again safely replaces this named job and rotates its scheduler credential.

Empty-body calls process enabled, active channels oldest-attempt-first (up to five per invocation) within a shared 100-second API budget. A per-channel 10-minute lease prevents overlapping imports. The next schedule continues with older unattempted channels. An owner can run a single channel immediately by invoking `sync-youtube` with `{"channel_id":"CHANNEL_UUID"}` and their existing JWT. Save-settings operations invalidate running leases so an old job cannot commit after settings change.

Safe scheduler status (no credentials):

```sql
select status, return_message, start_time, end_time
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname='curlymax-youtube-sync')
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

The second command uses a disposable, network-isolated PostgreSQL Docker container. Tests cover guest/viewer denial, private settings, same-channel memberships, concurrent sync lease exclusion, initial automatic publication without backfill alerts, future automatic publication once, unchanged manual titles/drafts, owner-unpublished videos and quizzes, public metric refresh, and playlist RLS. Mocked Google tests cover pagination, batching, private/foreign video filtering, deadlines, bounds, quota failures and credential-safe errors. They do not prove real Google credentials, hosted scheduling or end-to-end Android notifications. Complete one live import and a later-upload notification test after server configuration.

## Channel logos

The channel request also fetches YouTube's public profile thumbnail. A validated Google HTTPS thumbnail is saved in `channels.youtube_avatar_url` on each successful synchronization. A distinct manual `avatar_url` stays in control. For older installed apps, the worker fills an empty `avatar_url` and refreshes it only while it still matches the previous automatic logo. Missing provider images preserve the last valid icon; the app uses initials if no image is available. No additional YouTube API request is needed for the logo.
