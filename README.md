# CURLYmax

A **live-only Flutter/Dart Android app** for **@ashiy_ish**, backed by Supabase PostgreSQL, Auth and Realtime. There is no demo switch, sample catalog, local account or client-side quiz grading. Videos, quizzes, notes and scores come from your Supabase project.

## Run the app

Use Flutter **3.47.9** / Dart **3.13.7**, Android Studio's bundled JDK **25**, and the Android SDK. The Android minimum is API 24 and target is API 37. Package name: **com.curlymax.app**. Version: **1.1.0+2**.

Your public Supabase settings go in ignored `config/live.json`. Copy `config/live.example.json` when setting up another checkout; use a public publishable/anon key, never a database connection string, service-role key or `sb_secret_` key.

```sh
flutter pub get
flutter run --dart-define-from-file=config/live.json
python3 scripts/build_android.py
adb install -r artifacts/CURLYmax-live.apk
```

The build script creates a universal **debug-signed Android test APK** at `artifacts/CURLYmax-live.apk`. Private Play Store release signing is a separate owner setup step. A build without client configuration displays a connection/setup state; it never substitutes sample content. CI's unconfigured artifact is only a compilation check.

## Backend and first content

In a fresh Supabase project, run **`supabase/install.sql`** once in the Dashboard SQL editor. It installs the two versioned migrations, RLS, private server grading, publication outbox and the initial @ashiy_ish channel/section. It does **not** add sample videos or quizzes. Existing projects managed with the CLI can instead apply the versioned migrations through their normal migration workflow.

An empty library is expected until you publish your actual YouTube links through the dashboard. The [setup and publishing walkthrough](docs/SETUP.md) covers your first video and quiz, Google sign-in, Firebase, and adding CURLYmax Tech without an app release.

```sh
python3 scripts/check_live_backend.py
```

This checks your configured project's public catalog and denial of guest access to private data/RPCs. It prints no keys and creates no viewer accounts or catalog rows.

## App logo

The dark-and-lime **C/play** mark is installed as the Android launcher icon, startup icon and themed monochrome icon. Its main adaptive foreground is `android/app/src/main/res/drawable/ic_curlymax_foreground.xml`. See [app-icon locations](docs/SETUP.md#app-icon) before replacing the artwork so legacy and in-app branding stay consistent.

## Notifications

Until Firebase is configured, `FCM_ENABLED` may be `false`; browsing, sign-in, notes and quizzes still use Supabase. To enable notifications:

1. Create a Firebase project and add an Android app named `com.curlymax.app`.
2. Download its **public Android** `google-services.json` to ignored `config/google-services.json`.
3. Run `python3 scripts/configure_firebase.py`, then rebuild the app.
4. Configure the server sender and scheduled job as explained in [setup](docs/SETUP.md#firebase-notifications).

Google OAuth secrets and Firebase service-account credentials stay in the Supabase/Firebase consoles or server secrets. They never belong in Flutter configuration.

## Checks

```sh
flutter analyze
flutter test
python3 scripts/check_live_backend.py
```

Unit tests use isolated HTTP fixtures, not a special application mode. They verify real repository request shapes, server-only grading, guest gates, configuration/key validation, offline catalog behavior and UI states. The app contains no test accounts or answers.

For a real local Supabase/Auth/RLS Android test, start this project's local backend and an arm64 Android emulator, then run:

```sh
supabase start
python3 scripts/run_live_android_test.py emulator-5554
```

The runner is restricted to the local stack on port 55321. It creates a temporary confirmed test account and isolated video/quiz, grades through the real server RPC, checks notes in the database, and removes its fixtures afterward. It never runs against your hosted project. Keep integration APKs separate from the normal app APK.

The previous direct local backend permission suite remains available as `python3 scripts/verify_backend.py`; the guest Realtime check is `node scripts/verify_realtime.mjs` (Node 22+).

Read [the current verification record](docs/VERIFICATION.md) for checks actually run and remaining console/device acceptance work.
