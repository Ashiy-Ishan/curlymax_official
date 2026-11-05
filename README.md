# CURLYmax

Flutter/Dart Android companion for **@ashiy_ish**, with Supabase PostgreSQL/Auth/Realtime and an FCM publication worker. Material 3, dark surfaces, lime accent. The default build is an explicitly labeled **demo**; no live backend credentials were supplied.

## Run and install

Put Flutter on your PATH first. On this Mac the build SDK is at `/tmp/curlymax-flutter`; `export PATH="/tmp/curlymax-flutter/bin:$PATH"` enables it for this shell. That location is temporary, so install the tested Flutter version permanently for ongoing development.

Tested toolchain: Flutter **3.47.9**, Dart **3.13.7**, Android compile/target SDK **37**, min SDK **24**, JDK **25** (Android Studio bundled JBR). Use the committed `pubspec.lock` and Gradle wrapper.

```sh
flutter pub get
flutter run --dart-define=DEMO=true
flutter build apk --debug --dart-define=DEMO=true
adb install -r artifacts/CURLYmax-demo.apk
```

The APK is debug-signed for testing, not Play Store release signing. Demo notes, account and scores persist on one device. Demo quizzes grade locally with sample answers. Sample videos are Flutter learning content by other creators, **not @ashiy_ish uploads**. Demo mode never contacts Supabase or registers for FCM; YouTube thumbnails and playback still require internet.

For live mode, copy `config/live.example.json` to ignored `config/live.json`, fill in public client settings, then:

```sh
flutter build apk --debug --dart-define-from-file=config/live.json
```

Set `FCM_ENABLED` to `false` if Firebase is not configured yet. Never put a Supabase service-role/secret key, Google OAuth secret, or Firebase service-account private key in that file or the app. Public anon/publishable keys are intended for clients; RLS provides authorization.

## What is included

- Channel/section catalog from the database; channel selector appears when multiple active channels exist. Latest manually published video is featured per selected channel.
- Guest YouTube iframe playback and always-visible “Open in YouTube” fallback.
- Google browser OAuth and email/password Supabase Auth. Persisted video/notes/quiz destination resumes after authentication, including process restart.
- Private per-video note CRUD, server-scored MCQs, retries and score history.
- Realtime invalidation, launch/resume/reconnect fetch, 45-second recovery poll and a public catalog cache. Offline note writes and quiz submissions show errors and require retry; they are not silently queued.
- Android opt-in notifications, foreground notifications and background/cold-start destination routing. Topic contains only public publication announcements.
- SQL migrations, private grading keys, RLS, durable publication outbox and authenticated Edge Function sender.

See [setup and publishing walkthrough](docs/SETUP.md), [verification record](docs/VERIFICATION.md), and [architecture](docs/ARCHITECTURE.md).

## Verification commands

```sh
flutter analyze
flutter test
flutter test integration_test/demo_test.dart -d emulator-5554 --dart-define=DEMO=true
supabase start
python3 scripts/verify_backend.py
node scripts/verify_realtime.mjs
```

For an emulator on a memory-limited machine, build the integration APK first, stop Gradle, then run it separately:

```sh
flutter build apk --debug --target=integration_test/demo_test.dart --target-platform=android-arm64 --dart-define=DEMO=true
cp build/app/outputs/flutter-apk/app-debug.apk /tmp/CURLYmax-tests.apk
(cd android && ./gradlew --stop)
# Start your emulator/device, then:
flutter drive --no-pub --driver=test_driver/integration_test.dart --target=integration_test/demo_test.dart --use-application-binary=/tmp/CURLYmax-tests.apk -d emulator-5554
```

Use the correct device ID/ABI for your hardware. Keep the deliverable app APK separate from this test APK, which runs the test suite rather than the normal app entrypoint.

The backend test runs against **only** `http://127.0.0.1:55321`, creates two temporary confirmed accounts and isolated fixtures, calls real Auth/REST endpoints, and removes its fixtures. Docker and the Supabase CLI are required. The Realtime socket check also needs Node.js 22 or later. Local Supabase ports use 55321–55324 to avoid an existing project. Do not run reset commands against another project.
