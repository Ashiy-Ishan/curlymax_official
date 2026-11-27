# CURLYmax verification

The `artifacts/` paths below are historical local build evidence. Generated reports, screenshots and APKs are ignored by Git and are not included in a fresh clone; rerun the documented checks to create current evidence.

## Current update — 8 November 2026

### Automatic channel logo follow-up

Viewer **1.3.1+5** adds an explicit automatic-logo fallback. Migration **008** and the updated YouTube worker are deployed. A real sync fetched CURLYmax's channel thumbnail; a guest API read confirmed it is saved and available to older clients, and the public image returned **HTTP 200 / image/jpeg**. Manual overrides are preserved. App tests **29 passed**, combined worker tests **12 passed**, analysis is clean, and the Android test APK was rebuilt. The full isolated SQL suite and Deno worker type check passed. Existing installed apps can display the logo after catalog refresh; another APK install is not required for this fix. Channels without a configured/valid YouTube source retain their manual icon or initials.

### Automatic video policy and quiz editor follow-up

The live YouTube connection and 15-minute scheduler are configured and a successful import is now verified in the database. Applied migration **007**: public uploads publish automatically even on the first import, with silent historical backfill. Existing manual drafts, deliberately unpublished videos and quizzes stay under owner control.

Published the six exact previously imported drafts in one transaction, generating **zero backfill alerts**. A direct guest Data API check now sees **8 videos and 5 playlists** in CURLYmax. Playlist membership counts are 2, 1, 1, 1 and 2. CURLYmax | Tech remains empty because that channel has no configured import.

Studio **1.1.0+2** adds one-form atomic draft quiz creation with two to four options, explicit correct-answer selection, optional explanation and a question that can default to the quiz title. Dashboard analysis is clean and **10 tests passed**. Full isolated SQL tests passed, including invalid-create rollback and owner-only/private-key checks. Hosted guest checks now total **17 passed**. The updated Studio APK was built and its v2 signature verified; this newer Studio version has not been installed or exercised through a real owner login in this follow-up.

New quiz publishing remains manual. Initial draft-backfill instructions and missing-key status in the earlier snapshot below are superseded by this follow-up. Notification delivery for a future upload and live authenticated quiz-form submission still need acceptance testing.


Viewer **1.3.0+4** and Android Studio **1.0.0+1** are built and installed on the connected Samsung. The viewer's live Home accessibility hierarchy was checked. Complete picker/settings interaction and authenticated Studio device flows remain acceptance checks. The screen changed during capture, so no final screenshot is claimed. No live account was deleted.

- Flutter analysis is clean; viewer tests **28 passed**, Studio tests **6 passed**.
- Worker tests **11 passed**; configuration/archive security tests **5 passed**; server setup tests **3 passed**.
- Isolated PostgreSQL tests passed for guest/two-user/owner permissions, sync imports and deletion cascades. Both functions pass Deno type checking.
- Live migrations **004–006** were applied, and `sync-youtube` plus `delete-account` were deployed. Migration 003 was already installed. The live database had exactly one owner at preflight.
- Hosted checks passed for six public catalog tables and guest denial of private data, owner/worker RPCs, sync execution and account deletion: **16 checks passed**. Both Email and Google providers report enabled.
- Both APK signatures verify with v2 signing. These are debug-signed test APKs, minimum Android API 24, target 37.

YouTube credentials are not yet configured. Follow [YouTube setup](YOUTUBE_SYNC.md), then test the first draft import and a later automatically published upload. Scheduled refresh, live YouTube metrics, future-upload notification, real account deletion, authenticated Studio CRUD, Google callback and full Android/TalkBack interaction are not claimed as verified. A real owner account is never deleted for testing.

Evidence: `artifacts/catalog-verification.txt`, `catalog-flutter-analyze.txt`, `catalog-flutter-tests.txt`, `catalog-worker-tests.txt`, `catalog-live-backend.txt`, `catalog-android-build.txt`, and `studio-verification.txt`.

The sections below are historical and do not override this current configuration record.

## Notification sender repair — 7 November 2026

The hosted sender was active with both required secrets, but the database scheduler and its Vault settings were missing. Installed pg_cron and pg_net, generated a replacement scheduler credential shared securely between Edge Functions and Vault, and enabled `curlymax-publications` every minute with a 120-second HTTP timeout.

The first scheduled run succeeded at 07:38 UTC. The function returned HTTP 200 with `sent=2` and `failed=0`. Both previously pending video events changed to `sent` with `Accepted by FCM`. No pending events remained at verification. Actual receipt and tap navigation on a phone still require device confirmation.

Current quiz update is **1.2.0+3**. Its analysis, automated UI/database checks, APK build and remaining Android acceptance are recorded in `artifacts/quiz-feedback-verification.txt`. The historical checks below apply to 1.1.0+2. Apply the new quiz migration described in [QUIZ_FEEDBACK.md](QUIZ_FEEDBACK.md) before using the updated quiz.

Date: **6 November 2026**. This record applies to the **live-only** 1.1.0+2 app.

## Completed

| Check | Result | Evidence |
|---|---|---|
| Flutter static analysis | No issues | `artifacts/live-flutter-analyze.txt` |
| Unit/widget tests | 14 passed | `artifacts/live-flutter-tests.txt` |
| Universal Android APK | Built successfully; package `com.curlymax.app`, version 1.1.0+2 | `artifacts/live-android-build.txt` |
| APK signature | v2 signature verified | `artifacts/live-apk-signature.txt` |
| Android manifest | Minimum API 24, target API 37 | `artifacts/live-apk-manifest.txt` |
| Hosted public API | Four catalog tables respond; guests denied questions, notes, attempts and privileged RPCs: 9 checks passed | `artifacts/live-backend-verification.txt` |
| Real Supabase Dart SDK on host | Queries succeed against the configured project; one visible channel and section, no published videos/quizzes at verification time | `artifacts/live-sdk-verification.txt` |
| Android install/start | APK installed and launched on API 37 arm64 emulator | Native ADB install/version check before the Firebase client rebuild |
| Live Android catalog | Actual @ashiy_ish channel and Latest videos section loaded; no sample content | `artifacts/live-android-home.png` |
| Realtime readiness | Guest subscription established successfully using the real SDK | `artifacts/live-sdk-verification.txt` |
| App logo | Native dark/lime C/play startup icon displayed | `artifacts/live-android-icon.png` |
| Python helpers | Build, public backend check, Firebase importer, local integration runner and source packager parse successfully | Python AST check |

Unit tests cover public-key/endpoint validation, rejection of privileged keys, strict notification destination parsing, guest private-data gates, calling the server grading RPC and using its returned score, note requests without forged owner IDs, failed edits of deleted notes, published catalog/cache/offline behavior, persisted navigation, real sign-in controls and dynamic channel selection. HTTP fixtures exist only inside tests.

The app contains no runtime demo switch, sample videos/questions, local account creation, local private-note store or client-side grading. Supabase Auth supplies real sessions. The public catalog is cached for offline browsing; private data comes from the server.

## Service configuration status

- The provided public key and HTTPS endpoint connect successfully.
- The user applied the SQL setup; required live catalog tables now respond and guest private access is denied.
- Email sign-in provider is enabled. Real email confirmation/SMTP delivery and an authenticated hosted viewer flow were not exercised.
- Google provider is **disabled** in Supabase. Owner console configuration is required before Google sign-in can work.
- Firebase Android client configuration for `curlymax-13d7d` matches `com.curlymax.app` and has been imported. The delivered APK was rebuilt with `FCM_ENABLED=true`. Both local configuration files are excluded from Git and the source archive. No service-account secret is in the app. Firebase initialization, device registration and notification delivery have not yet been verified on Android; the server sender still requires credentials and deployment.

## Android runtime and remaining acceptance

The emulator initially could not resolve the Supabase hostname (`ping: unknown host`), while both host HTTPS checks and the real Dart SDK succeeded. The app displayed its offline/loading behavior. Restarting only the test emulator with explicit DNS servers (1.1.1.1 and 8.8.8.8) resolved the issue. Android then loaded the real @ashiy_ish channel and Latest videos section and displayed the correct empty state because no videos are published. The app's HTTPS endpoint/key were not altered to work around a test-device network failure.

The retained dark/lime C/play icon was observed on the actual native startup screen and now has an adaptive Android 8+ foreground/background, a monochrome Android 13+ mask, round-icon registration, legacy artwork and an Android 12+ startup screen. The resource definitions compile in the APK. Physical launcher/theme coverage remains to be checked.

Actual new-version playback, restricted embedding/Shorts fallback, fullscreen/orientation, real Google/email callbacks, authenticated hosted notes/attempt ownership, cross-device sync, live Realtime publication/reconnect and FCM send/foreground/background/terminated taps remain acceptance items. The current catalog has no published videos or quizzes, so video/quiz acceptance requires publishing your own content first.

`integration_test/live_test.dart` and `scripts/run_live_android_test.py` provide real Supabase Auth/RLS Android coverage using temporary LOCAL fixtures. That suite was prepared for this version but was not claimed as run against the hosted project. It requires a running local stack and an Android emulator. The earlier local direct permission suite can be rerun separately; no additional cloud CLI/database changes were made by the agent.

See `docs/SETUP.md` for publishing, Google, Firebase and server sender steps. Configured APK: `artifacts/CURLYmax-live.apk`.
