# CURLYmax Studio — Mac owner dashboard

This is a separate Flutter web application. It runs in Chrome on your Mac and uses the same Supabase backend as the Android app. No Android code or server secret is needed to launch it.

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

   Flutter and Chrome must be installed. The launcher creates ignored `dashboard/config.json` from the Android project's public Supabase settings if present. Alternatively copy `config.example.json` to `config.json` and enter the URL/public key yourself. Never use a service-role key, client secret or notification service account.
5. Sign in with the owner's email/password or Google account. Accounts without `private.owners` membership are refused; RLS and SQL functions independently enforce access.

## Manage your app

- **Channels:** add CURLYmax Tech when ready; choose its handle, active status and sort position. The Android app discovers active channels without an app release.
- **Sections:** choose a channel and create or edit its sections. Deactivate a channel/section to hide its content.
- **Videos:** select a matching channel/section, paste a YouTube watch, youtu.be or Shorts URL, enter title/description and save a draft. Change status to published when ready.
- **Quizzes:** choose a video and save a draft. Open **Questions & answers**, add prompts/options, select correct answers, then save. Edit the quiz and publish after its video is published. Unpublish before changing questions. Question edits are atomic; an invalid edit leaves the previous questions unchanged. Existing attempts retain their original scores.
- **Delete:** each item has a confirmation. Foreign-key restrictions protect linked content and viewer records; unpublish/deactivate instead if deletion is blocked. Delete child content first only when you intend to remove it. Quiz deletion may require first saving it as draft due to the published-question guard.
- **Alerts:** inspect the last 100 publication events and errors. Sending still requires the server sender described in `../docs/SETUP.md`. The dashboard does not resend uncertain deliveries automatically.
- **Refresh:** reload the latest content after changes from another session or reconnecting. Failed network operations show an error. If saving a content form fails, reopen it and enter the changes again.

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
