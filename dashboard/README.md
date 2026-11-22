# CURLYmax Studio — Android and Mac owner dashboard

This is a separate Flutter owner application for Android and Mac browsers. It uses the same Supabase backend as the viewer app, with server-enforced owner access. No server secrets belong in Studio.

## One-time setup

1. In your existing Supabase project's SQL Editor, run **dashboard/supabase/001_dashboard.sql**. Do not rerun the original install.sql. This adds three owner-only functions and does not reset existing catalog data.
2. Sign in to the Android app at least once to create your account. Find its user UUID in Supabase → Authentication → Users, then run:

   ```sql
   insert into private.owners(user_id) values ('YOUR_AUTH_USER_UUID')
   on conflict do nothing;
   ```

   Only grant this to your own trusted publishing account.
3. In Supabase → Authentication → URL Configuration → Redirect URLs, add **http://localhost:7357**. This allows the dashboard's Google OAuth return. The existing Google Web client and Supabase callback stay the same.
4. From the repository root run:

   ```sh
   python3 dashboard/scripts/run.py
   ```

   Flutter must be installed. Once Flutter reports the server is ready, open **http://localhost:7357** in your browser. Keep the terminal running; press Ctrl+C to stop. Chrome installation or Flutter Chrome-device detection is not required. The launcher creates ignored `dashboard/config.json` from the Android project's public Supabase settings if present. Alternatively copy `config.example.json` to `config.json` and enter the URL/public key yourself. Never use a service-role key, client secret or notification service account.
5. Sign in with the owner's email/password or Google account. Accounts without `private.owners` membership are refused; RLS and SQL functions independently enforce access.

## Manage your app

- **Channels:** add CURLYmax Tech when ready; choose its handle, optional HTTPS channel icon URL, active status and sort position (channel icons require migration 006). The Android app discovers active channels without an app release.
- **Sections:** choose a channel and create or edit its sections. Deactivate a channel/section to hide its content.
- **Videos:** select a matching channel/section, paste a YouTube watch, youtu.be or Shorts URL, enter title/description and save a draft. Change status to published when ready.
- **Quizzes:** choose Add new, select a video and enter a quiz title, two to four answers, the correct answer and an optional explanation. An optional first-question prompt defaults to the quiz title. Save creates the quiz and its first question together as a draft (requires migration 007). Review it, add more questions through **Questions & answers** if needed, then edit the quiz to publish. New questions default to four options and require an explicit correct answer. Legacy five/six-option questions remain intact; you cannot add beyond four. Unpublish before editing questions.
- **Delete:** each item has a confirmation. Foreign-key restrictions protect linked content and viewer records; unpublish/deactivate instead if deletion is blocked. Delete child content first only when you intend to remove it. Quiz deletion may require first saving it as draft due to the published-question guard.
- **Alerts:** inspect the last 100 publication events and errors. Sending still requires the server sender described in `../docs/SETUP.md`. The dashboard does not resend uncertain deliveries automatically.
- **Automatic updates:** published catalog changes refresh through Realtime while Studio is open. Studio reloads on resume/reconnect and checks every 30 seconds to recover missed updates and refresh alert status. Updates stop after sign-out or while backgrounded. **Refresh** also reloads immediately. Failed network operations show an error. If saving a content form fails, reopen it and enter the changes again.

Viewer notes and individual scores remain private, including from the publishing dashboard. Manage Auth users, owner membership, OAuth credentials and server secrets through the Supabase console. This UI cannot configure cloud credentials or grant itself permissions.

## Build / verify

```sh
cd dashboard
flutter pub get
flutter analyze
flutter build web --release --dart-define-from-file=config.json
```

Deploy `build/web` only behind HTTPS, adding its exact origin to Supabase Auth redirect URLs. Public client configuration is included in browser builds by design; database authorization is enforced server-side. Do not expose the local development server to your network.

The SQL upgrade must be installed manually before quiz/alert tools work. Live owner CRUD, OAuth callbacks and notification sending require configuration and acceptance testing; a compiled dashboard is not evidence those remote flows have passed.

### Quiz feedback update

Apply `../supabase/migrations/202611060003_quiz_feedback.sql` once to enable the Android app's server-checked answer feedback and points. The Questions & answers editor now accepts a private explanation for each question. See `../docs/QUIZ_FEEDBACK.md`.

## Android owner application

Studio is a separate installed app (`com.curlymax.studio`) that shares this dashboard's source and database. It installs alongside the viewer app. Phone navigation is in the menu at the top left; tablets show a navigation rail.

```sh
cd dashboard
flutter build apk --debug --dart-define-from-file=config.json
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The delivered test build is `../artifacts/CURLYmax-Studio.apk`. This debug-signed APK is for testing; configure private release signing before distribution. Android backups and cleartext traffic are disabled. Native owner sessions are held in memory and are not restored after the process ends; sign in again when needed. A browser OAuth round trip normally keeps the process alive; if Android terminates it, restart sign-in. Email/password sign-in needs no mobile redirect setup.

For Google sign-in, add `com.curlymax.studio://login-callback/` to Supabase Authentication → URL Configuration → Redirect URLs. The existing Google provider uses the same Supabase callback. Do not add a service-role key or Firebase Admin credentials to this project. Configuration accepts only an HTTPS origin and a publishable key (or legacy anon key).

## YouTube workspace and playlists

Complete the backend setup from the repository root with `python3 scripts/setup_youtube_sync.py --project-ref qsmnvfkrxzwyjugkbpwp` after applying the YouTube migration. The helper privately prompts for the YouTube API key, configures server secrets, deploys the worker and schedules sync. Keep that key out of Studio and source control; see [the YouTube setup guide](../docs/YOUTUBE_SYNC.md) for prerequisites. In Studio → YouTube → Configure, enter the channel's UC… identifier (or leave it blank to resolve its saved handle) and its import section. Enable sync and save. Public YouTube videos publish automatically when that switch is on, including the first import. Quizzes remain drafts until you review and publish them. Use **Sync now** for a manual server run, or let the backend schedule run. Status shows the last sync, errors and public view/like/comment totals. These are public metadata totals, not private audience, watch-time or revenue analytics.

The **Playlists** page lets you add/edit channel playlists, visibility and display position. The Manage this playlist from YouTube switch controls whether sync refreshes its video membership. Existing title, description and thumbnail edits are preserved. Imported playlists start managed; manual playlists start unmanaged. Owner visibility and display position are always preserved. Quiz authoring remains under **Quizzes → Questions & answers**; save a draft, add options/explanations, then publish after review.

## Import a quiz from JSON

Apply `supabase/migrations/202611220010_quiz_json_import.sql` once to an existing database (fresh installations include it in `supabase/install.sql`). The `owner_import_quiz` RPC requires the authenticated owner and saves all questions and private answer keys in one transaction. A failed validation leaves no partial quiz. Imports always start as drafts and send no publication notification until you publish.

In Studio select **Quizzes**, then the **Import quiz JSON** upload icon in the top bar. Select the related video, paste the contents of `examples/quiz-import.json`, click **Validate JSON**, then **Upload draft**. Inspect the imported quiz and publish it using the existing editor. The JSON contains `title` and a `questions` array. Each question contains `prompt`, two to four `options`, zero-based `correct_index` (0 = first answer), and optional `explanation`. A single quiz may contain 1–100 questions. Do not put private answer-key JSON in the public repository; the example is synthetic.

If an upload times out, refresh the quiz list before retrying: the database may have committed even if the network response did not arrive. A deliberate second upload creates another draft.

## Google still shows a Supabase address

The app's own sign-in page is branded CURLYmax. The external Google page is controlled by Google Auth Platform and Supabase's OAuth callback hostname, not Flutter widgets. In the Google Cloud project that owns the OAuth client configured in Supabase, open **Google Auth Platform → Branding**, verify the name/logo/homepage/privacy information and complete verification/publication. Saved draft branding may not be displayed to users. Verify you edited the same OAuth client project used by Supabase.

A visible `<project-ref>.supabase.co` hostname may remain because it is the actual authentication server address. To brand that address, configure and activate a Supabase custom auth domain (a paid-plan add-on), prepare DNS and certificates, and add its exact `/auth/v1/callback` URL to the Google Web OAuth client's authorized redirect URIs before activation. Do not replace the backend URL with an unconfigured website domain or remove the existing callback prematurely. The Android app callback (`com.curlymax.app://login-callback/` or Studio's `com.curlymax.studio://login-callback/`) is a separate return destination.

Official setup: https://supabase.com/docs/guides/auth/social-sign-in/auth-google and https://supabase.com/docs/guides/platform/custom-domains . An app rebuild alone cannot publish Google branding or replace the server hostname.
