# CURLYmax 1.1 verification

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
