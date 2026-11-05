# Setup and publishing walkthrough

## 1. Supabase

Create your Supabase project. Link it with `supabase link --project-ref YOUR_REF`, review the migrations, then run `supabase db push`. Or paste the two migration files in timestamp order into the Dashboard SQL editor. The migration seeds **@ashiy_ish** and one “Latest videos” section, but no fake live uploads.

Use the project URL and public anon/publishable key in `config/live.json`. Ensure `public` is exposed through the Data API and **private is not**. RLS is enabled on every public table; `private.answer_keys`, owner membership and the notification outbox are inaccessible to client roles. Realtime publication includes channels, sections, videos and quiz metadata. Questions and private user data are fetched on demand.

Sign up as the owner once, find the account UUID in Authentication → Users, then in the Dashboard SQL editor:

```sql
insert into private.owners(user_id) values ('YOUR_AUTH_USER_UUID');
```

Only database administrators may change that membership. Dashboard administrators inherently have privileged database access; never distribute Dashboard/service credentials to viewers. The application has no publishing UI. Authenticated owners can manage catalog rows through the API; regular signed-in users cannot.

## 2. Email and Google sign-in

Enable Email in Supabase Authentication → Providers and configure your SMTP/confirmation email settings. Add the exact redirect `com.curlymax.app://login-callback/` in Authentication → URL Configuration → Redirect URLs. The Android manifest handles that scheme and disables Flutter’s default deep-link router so Supabase’s app_links handler receives OAuth callbacks. See [Flutter’s plugin deep-link guidance](https://docs.flutter.dev/ui/navigation/deep-linking). Email/password sign-in and account creation are included. If email confirmation is required, confirm using the emailed link and return to sign in; the pending destination remains saved.

For Google, create a **Web application OAuth client** in Google Cloud, configure the consent screen and test users, and add `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback` as an authorized redirect URI. Enable Google in Supabase and enter the client ID and secret there. This app uses browser OAuth with PKCE through Supabase, so no Google secret or native Google credential is compiled into Flutter. Add the app redirect above to Supabase's allowlist. For production distribution replace the custom scheme with verified Android App Links if you need stronger redirect ownership.

Reference: [Supabase Flutter OAuth](https://supabase.com/docs/reference/dart/auth-signinwithoauth), [redirect URL configuration](https://supabase.com/docs/guides/auth/redirect-urls).

## 3. Publish one video and quiz

In Dashboard → Table Editor, open `videos` and insert a **draft**:

- `channel_id`: `10000000-0000-0000-0000-000000000001`
- `section_id`: `20000000-0000-0000-0000-000000000001`
- `title`, `description`, `youtube_url`: your actual upload.
- Keep `status = draft`; leave generated `youtube_id` and `published_at` alone.

Accepted URL examples (the ID shown here is a sample):

```text
https://www.youtube.com/watch?v=fq4N0hgOWzU&t=20
https://youtu.be/fq4N0hgOWzU?si=example
https://youtube.com/shorts/fq4N0hgOWzU
```

Save the draft, check the channel/section and URL, then change `status` to `published`. Publication time is set by the database. The home screen's latest video follows publication time; if you backfill older uploads, set `published_at` deliberately. Videos are published manually; this app does not poll the YouTube channel API. First publication creates one notification event, even if you later unpublish/re-publish the same row.

Create a draft `quizzes` row with the video UUID and a title. Insert `questions` rows with that quiz UUID, a prompt, an `options` JSON array such as `["Dart", "Python", "SQL"]`, and positions 0, 1, 2, etc. Record each generated question UUID. Answer keys live outside the exposed API. In the Dashboard SQL editor:

```sql
insert into private.answer_keys(question_id, correct_index)
values ('YOUR_QUESTION_UUID', 0);
```

Indices are **zero-based**. Repeat for every question. Now set the quiz status to `published`. The database rejects a quiz without questions, without valid keys, or whose video is not visible. Signed-in users can fetch questions, but never keys. The `submit_quiz` RPC validates every answer, grades on the server, and stores only the caller's score/total. A retry creates a separate attempt. Clients cannot write scores directly.

To revise a quiz, set it back to draft first, edit its questions/keys, then publish it again. Existing attempts retain their original score/total. Create a new quiz row if it is a new quiz that should generate a fresh announcement. Deleting or disabling a channel/section hides its descendants. Prefer setting `active=false` or reverting to draft rather than deleting rows referenced by notes/attempts.

## 4. Add CURLYmax Tech later

When the channel is ready, insert a `channels` row: `name = CURLYmax Tech`, your actual handle, `active = true`, and a higher `position`. Add one or more `sections` referencing that channel. Publish a video assigned to that channel and one of its sections. The foreign key prevents mismatched channel/section selections.

The app reads active channels on launch and via Realtime/reconnect. As soon as there are two, it shows the channel selector automatically. No APK release is required. You can keep a channel inactive while preparing it.

## 5. Firebase Android notifications

Create a Firebase project and register Android package **com.curlymax.app**. Enable the Firebase Cloud Messaging HTTP v1 API. Copy the public Android `apiKey`, `mobilesdk_app_id`, sender/project number and project ID from the Firebase console/`google-services.json` into `config/live.json` under the documented names. Flutter initializes Firebase explicitly; a Gradle Google Services plugin or committed `google-services.json` is not required.

FCM auto-initialization is disabled in AndroidManifest. The user enables notifications in Your space; Android permission is requested at that point, then the app subscribes to `curlymax_public`. Disabling unsubscribes and deletes the token. A sign-out also disables notifications on this installation. Notifications work for guests who opt in. The topic is public and must never carry notes, scores, keys or private data. Use an Android device/emulator with Google Play services.

Create a dedicated Google service account with the **Firebase Cloud Messaging API Admin** role on this project. Store its JSON only as the Edge Function secret `FCM_SERVICE_ACCOUNT_JSON`. Generate a long random `SCHEDULER_SECRET` and store it as another function secret, using the Supabase Dashboard secrets UI. Supabase provides `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to the function environment. None of these server secrets go in Dart defines.

Deploy:

```sh
supabase functions deploy notify-published --no-verify-jwt
```

JWT verification is off because the endpoint uses the explicit scheduler secret; unauthenticated calls receive 401. In Supabase Cron, schedule an HTTP POST every minute to `https://YOUR_PROJECT_REF.supabase.co/functions/v1/notify-published` with `Authorization: Bearer YOUR_SCHEDULER_SECRET`. Keep the bearer value in Vault, not in checked-in SQL. If using SQL, enable `pg_cron` and `pg_net`, create Vault secrets named `curlymax_worker_url` and `curlymax_scheduler_secret`, then:

```sql
select cron.schedule('curlymax-publications', '* * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='curlymax_worker_url'),
    headers := jsonb_build_object('Content-Type','application/json','Authorization',
      'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='curlymax_scheduler_secret')),
    body := '{}'::jsonb
  );
$$);
```

The worker atomically claims up to 50 visible pending publication events. Parallel workers cannot claim the same event. It makes **one send attempt per event**, uses event IDs for Android tags/collapse keys, and deduplicates foreground notifications locally. FCM cannot guarantee delivery or exactly-once presentation. A network timeout may mean delivery is ambiguous; failed/dispatching events require operator review in `private.notification_outbox`. There are no blind retries that could create duplicate alerts. If a worker dies after claiming but before sending, that alert may be missed. Fix configuration before publishing, and monitor the queue. You may deliberately reset a failed row to pending after determining it was not delivered; that is an operator action, not automatic retry.

Reference: [Flutter FCM setup](https://firebase.google.com/docs/cloud-messaging/flutter/get-started), [foreground/background/tap behavior](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages).

## 6. Live acceptance checklist

Use a test Supabase/Firebase project first. On two Android installations sign in to the same viewer account and check note synchronization after refresh; sign in as another account and confirm isolation. Test guest → quiz and guest → notes destinations through Google and email, including process restart. With the app open, publish a video/quiz; check Realtime. Disable network, publish elsewhere, reconnect and check catch-up. Opt in to notifications, publish new rows, and tap alerts with the app foregrounded, backgrounded and terminated. Check embedding-restricted, private, deleted and Shorts videos through the fallback. Run the supplied direct API test locally, then adapt it to test accounts/fixtures in your staging environment before release.
