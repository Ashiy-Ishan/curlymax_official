# CURLYmax live setup

The app is live-only. It does not contain sample videos, a local account, local notes or local quiz grading.

## Supabase connection

Use the project's **HTTPS API URL** and **public publishable key** in `config/live.json`. A database URI starting with `postgresql://` is for server/database tools and must not be put in Flutter. For an endpoint like `db.PROJECT_REF.supabase.co`, the API URL is `https://PROJECT_REF.supabase.co`.

The public-key field is `SUPABASE_PUBLISHABLE_KEY`. Older anon JWTs are accepted under `SUPABASE_ANON_KEY`. Privileged keys are rejected by the configuration/build checks. `config/live.json` is ignored by Git and excluded from source archives.

For a fresh project, open **Supabase → SQL Editor → New query**, paste the **entire** `supabase/install.sql` file, and press Run. Expected result: **Success. No rows returned.** This file combines the versioned migrations. Do not run it again on an already installed database; use new versioned migrations for future changes.

Check the installation:

```sql
select to_regclass('public.channels'); -- public.channels, not NULL
select name, handle from public.channels;
```

Keep `public` exposed through the Data API. Keep `private` unexposed. Private answer keys, owner membership and the notification queue are not client-readable. Realtime publication includes channel, section, video and quiz metadata. Viewer notes and attempts are protected by ownership policies.

Run `python3 scripts/check_live_backend.py` to verify the public connection and guest denial of private data. That script cannot install the schema because it deliberately uses only the app's public key.

## Email sign-in and owner account

In Supabase Authentication → Sign In / Providers, enable Email. Configure a production SMTP service and email-confirmation templates before accepting public viewer registrations. Add the exact redirect URL **`com.curlymax.app://login-callback/`** under Authentication → URL Configuration → Redirect URLs.

Users can create an account and sign in with email/password in the app. With confirmation enabled, they confirm their email and return to sign in; a selected video/notes/quiz destination remains saved through authentication.

Create your own account, find its UUID in Authentication → Users, then grant catalog publishing membership in the SQL editor:

```sql
insert into private.owners(user_id) values ('YOUR_AUTH_USER_UUID');
```

Use a real authenticated account UUID. This private membership cannot be set through viewer-editable metadata. Dashboard administrators retain privileged SQL access; viewers never receive those credentials.

## Google sign-in

Google sign-in must be enabled in the Supabase console; an Android app cannot enable it with a public key.

1. Open Google Cloud Console and select/create your project. You can use the Google Cloud project associated with your Firebase project.
2. Configure the OAuth consent screen and test users while the consent app is in testing.
3. Create an OAuth client of type **Web application**.
4. Add `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback` as an authorized redirect URI.
5. In Supabase Authentication → Sign In / Providers → Google, enable Google and enter the OAuth client ID and secret there.
6. Ensure `com.curlymax.app://login-callback/` is allowed in Supabase's redirect URLs, then test sign-in from Android.

The app uses Supabase browser OAuth/PKCE. A native Google sign-in client secret is not needed in Flutter. The Android manifest routes callbacks through Supabase's app-links handler and disables Flutter's competing default deep-link router. For public production distribution, verified Android App Links can replace the custom redirect scheme.

References: [Supabase Flutter OAuth](https://supabase.com/docs/reference/dart/auth-signinwithoauth), [redirect URL settings](https://supabase.com/docs/guides/auth/redirect-urls), [Flutter plugin deep links](https://docs.flutter.dev/ui/navigation/deep-linking).

## Publish one video and quiz

The installation creates the @ashiy_ish channel and a Latest videos section. It deliberately inserts **no videos or quizzes**.

In Supabase Table Editor → `videos`, insert a row:

- `channel_id`: `10000000-0000-0000-0000-000000000001`
- `section_id`: `20000000-0000-0000-0000-000000000001`
- `title`, `description`, `youtube_url`: your actual content.
- `status`: leave as `draft` until ready.

The database accepts normal `youtube.com/watch?v=VIDEO_ID`, `youtu.be/VIDEO_ID`, and `youtube.com/shorts/VIDEO_ID` HTTPS links. Leave generated `youtube_id` alone. Check the channel and section before changing the video to `published`; the database fills publication time. The latest manually published video is featured on Home. For backfilled older uploads, choose `published_at` deliberately.

Create a draft row in `quizzes` with the published video's UUID and a title. Insert `questions` rows with the quiz UUID, prompt, an `options` JSON array of 2–6 nonempty strings and positions 0, 1, 2, etc. Answer keys are zero-based and go in the private schema through the SQL editor:

```sql
insert into private.answer_keys(question_id, correct_index)
values ('YOUR_QUESTION_UUID', 0);
```

Add one valid key per question, then set the quiz to `published`. The database rejects quizzes without questions/keys or without a visible published video. Published questions are frozen; unpublish the quiz before editing questions or keys. Existing attempts retain their historical score and total.

Viewers submit only question-ID/option-index selections. The `submit_quiz` RPC validates, grades and creates the caller's attempt on the server. The app never calculates a score or downloads answer keys. Retries create separate attempts.

Realtime refreshes an open app after publication. The catalog is also fetched on launch, resume and reconnect, with a recovery poll for missed events. Notes sync through Supabase and can be refreshed from another device. Failed note writes preserve an in-memory draft while the video screen remains open; offline writes are not silently queued.

Prefer unpublishing or setting channel/section `active=false` over deleting rows referenced by viewer notes or attempts.

## Add CURLYmax Tech later

Insert a `channels` row with name **CURLYmax Tech**, your actual handle, `active=true`, and a higher `position`. Add sections referencing that channel, then publish actual videos assigned to that channel and one of its sections.

The live app fetches channels from the database. With two active channels, the selector appears automatically; no APK release is needed. Keep a channel inactive while preparing content. A foreign key prevents mismatching a video's channel and section.

## Firebase notifications

### Create the public Android client configuration

1. Open Firebase Console and create a project.
2. From Project overview, choose **Add app → Android**.
3. Enter Android package **`com.curlymax.app`** and app nickname **CURLYmax**.
4. Download **`google-services.json`** and save it as `config/google-services.json` in this workspace.
5. Run:

   ```sh
   python3 scripts/configure_firebase.py
   python3 scripts/build_android.py
   ```

The importer copies the public Android API key, app ID, sender/project number and project ID into ignored `config/live.json` and sets `FCM_ENABLED=true`. It refuses service-account JSON and checks the Android package name. Flutter initializes Firebase explicitly, so there is no need to add the Gradle Google Services plugin or commit the JSON file. Firebase Authentication is not used; sign-in belongs to Supabase.

The app has FCM auto-init disabled until the viewer opts in. The notification switch asks Android permission and subscribes to `curlymax_public`. Opt-out unsubscribes and deletes the token. This topic carries public announcements only, never private notes, scores or answer keys. Devices need Google Play services for FCM.

### Configure the server sender

Enable the Firebase Cloud Messaging HTTP v1 API. Create a dedicated Google service account with the **Firebase Cloud Messaging API Admin** role for this project.

In **Supabase → Edge Functions → Secrets**, save:

- `FCM_SERVICE_ACCOUNT_JSON`: the service-account JSON, **server-side only**.
- `SCHEDULER_SECRET`: a long random secret for the scheduled sender endpoint.

Supabase supplies the function's own `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. None of these privileged values go into Flutter, `config/live.json`, Git or chat.

Deploy `supabase/functions/notify-published/index.ts`:

```sh
supabase functions deploy notify-published --no-verify-jwt
```

The endpoint verifies its own scheduler bearer secret. In Supabase Cron, schedule an HTTP POST every minute to `https://YOUR_PROJECT_REF.supabase.co/functions/v1/notify-published` with the scheduler Authorization header. Store secrets in Vault, not checked-in SQL.

Enable `pg_cron`/`pg_net` and create Vault secrets named `curlymax_worker_url` and `curlymax_scheduler_secret`, then schedule:

```sql
select cron.schedule('curlymax-publications', '* * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='curlymax_worker_url'),
    headers := jsonb_build_object('Content-Type','application/json','Authorization',
      'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='curlymax_scheduler_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
$$);
```

First publication creates one durable outbox event per video/quiz. Re-publishing the same row does not create another event. Parallel workers cannot claim an event twice. The worker makes one FCM send attempt and uses an event ID for Android tagging/collapse and foreground deduplication. FCM cannot promise exactly-once delivery; ambiguous timeouts are not blindly retried. Monitor `private.notification_outbox` for failed/stranded events and review them before deliberate retries.

References: [FCM Flutter setup](https://firebase.google.com/docs/cloud-messaging/flutter/get-started), [receive messages and notification taps](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages).

## App icon

The existing dark-and-lime **C/play** artwork is retained. Android resources:

- `android/app/src/main/res/drawable/ic_curlymax_foreground.xml`: adaptive foreground artwork.
- `android/app/src/main/res/drawable/ic_curlymax_monochrome.xml`: Android 13+ themed-icon mask.
- `android/app/src/main/res/drawable/ic_curlymax.xml` and `mipmap-anydpi/ic_curlymax_launcher.xml`: legacy complete artwork.
- `mipmap-anydpi-v26/ic_curlymax_launcher.xml` and `mipmap-anydpi-v33/ic_curlymax_launcher.xml`: adaptive icon definitions.
- `values-v31/styles.xml` / `values-night-v31/styles.xml`: Android 12+ startup screen.
- `lib/brand.dart`: matching in-app mark used by the setup screen.

The manifest uses `@mipmap/ic_curlymax_launcher` for both icon and roundIcon. When replacing the logo later, update the foreground, monochrome and legacy artwork together. Keep the important artwork within the adaptive icon's safe area. See [Android's adaptive icon design guidance](https://codelabs.developers.google.com/design-android-launcher).

## Acceptance before public distribution

Test real Google/email callbacks on Android, email confirmation and SMTP, two-account note/attempt isolation, cross-device notes, server quiz grading/retry, Realtime publication while open and reconnect catch-up. Test FCM foreground/background/terminated taps to a video and a quiz, retaining sign-in destinations. Check embedding-restricted, private, deleted and Shorts video fallback, fullscreen and orientation on physical devices.

The source includes a real-backend Android test (`integration_test/live_test.dart`) and an isolated local fixture runner (`scripts/run_live_android_test.py`). Mock HTTP fixtures exist only in unit tests; they are never an app mode. The current verification record distinguishes tests run from console/device checks still pending.

## Mac owner dashboard

The separate Flutter browser application is in [`dashboard/`](../dashboard/README.md). Follow its README to install the owner-only SQL upgrade, grant your account owner access and run `python3 dashboard/scripts/run.py`. It manages channels, sections, videos, quizzes/questions/answer keys and displays notification status.

The same separate project also builds the Android owner app **CURLYmax Studio** (`com.curlymax.studio`). Add `com.curlymax.studio://login-callback/` to Supabase Auth's redirect URLs for its Google sign-in. It can be installed alongside the viewer app. See the dashboard README for its build command and the [security review](SECURITY.md) for owner access and credential handling.

## Animated MCQ feedback

See [quiz feedback setup](QUIZ_FEEDBACK.md) for the one-time server upgrade, private explanations, attempt points and animation/accessibility behavior. Existing projects must apply `202611060003_quiz_feedback.sql` before using the new quiz screen.

## YouTube updates, playlists and account controls

See [YouTube setup](YOUTUBE_SYNC.md) for the server API key and 15-minute automatic sync. Public YouTube uploads publish automatically when enabled, including the first import; first-import alerts are silent. Quizzes remain manually reviewed drafts. Studio manages playlists, public metrics, linked quizzes and channel icon URLs. Added active channels appear in the viewer's top avatar picker without another app release.

Apply migrations `202611080005_youtube_sync.sql` and `202611080006_account_controls.sql` in order after the earlier migrations. Deploy `sync-youtube` and `delete-account` with their repository configuration. Settings → Who am I includes logout and **Clear all my data**, which permanently deletes the current sign-in account and its private notes/quiz records after typed confirmation and recent sign-in. See [security details](SECURITY.md).

Apply `202611080007_automatic_youtube_import.sql` for the latest video policy and atomic quiz form. In Studio → Quizzes → Add, choose **Video**, enter **Quiz title**, and provide two to four answer options plus the correct answer. A blank question uses the quiz title. The quiz and its private answer are saved together as a draft; review before publishing. Legacy quizzes with more options remain readable without truncation.
