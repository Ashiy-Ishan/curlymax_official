# Verification record

Verified on **4 November 2026**. No hosted Supabase, Google OAuth or Firebase credentials were supplied. The deliverable defaults to visibly labeled **demo mode**. Backend checks use an isolated local Supabase stack, not a hosted production project.

## Automated source and backend checks

| Check | Result | Evidence |
|---|---|---|
| Flutter static analysis | Passed, no issues | `artifacts/flutter-analyze.txt` |
| Flutter unit/widget tests | 3 passed: guest catalog/latest, demo note/score persistence and CRUD/retry, dynamic second-channel selector/filter | `artifacts/flutter-tests.txt` |
| Direct Auth/REST security tests | 50 assertions passed as a guest, user A, user B, and a database-appointed owner | `artifacts/backend-verification.txt` |
| Realtime and catch-up | Guest received a newly added channel over WebSocket; post-reconnect guest fetch found a publication missed while disconnected | `artifacts/realtime-verification.txt` |
| SQL migrations | Both applied successfully from a clean local PostgreSQL 17 database | `supabase/migrations/` |

Direct API checks include draft and parent visibility, question authentication, inaccessible answer keys, note read/edit/delete ownership in both directions, owner-spoof rejection, immutable attempts, server grading and retry, incomplete/null-answer rejection, owner publishing, frozen published questions, unauthorized worker rejection, republish deduplication, concurrent worker claims, service-only completion and no re-claim of sent events. The notification transport itself was not called with a real service account.

## Android verification

The final universal APK built successfully, passed `apksigner verify` (v2 signature), and installed and launched on an Android 17 / API 37 **arm64 emulator**. Package: `com.curlymax.app`, version 1.0.0+1, minimum API 24, target API 37. The APK includes arm64-v8a, armeabi-v7a and x86_64 native libraries and is debug-signed for testing.

Three Android flow tests passed using a standalone integration APK with Gradle stopped (`artifacts/android-runtime-tests.txt` in the workspace; clean summary in `artifacts/android-verification.txt`):

1. Guest catalog/latest → gated notes → demo authentication → return to the same video's notes → create, edit and delete a note → linked quiz → 2/2 score → retry resets answers → saved score history.
2. A persisted cold-start quiz destination → authentication → that same quiz. This simulates the common destination path; it is **not** a real FCM notification test.
3. Account sign-in dismisses the auth screen and account sign-out returns to guest state.

All were in **demo mode**. They verify Android UI/routing and local persistence, not Google/email providers, cross-device synchronization or server grading on Android. Server grading and ownership were separately verified through direct calls to local Supabase.

Initial runs with compilation and the emulator running together hit resource pressure and an Android System UI ANR on this 8 GB Mac. The final successful run separated compilation from runtime and used hardware graphics. The final project limits Gradle to two workers and a 3 GB heap. Static analysis and all three unit/widget tests also passed after the final source changes.

Home-screen layout was inspected in the actual delivered APK; see `artifacts/android-home.png`. The YouTube iframe loaded, the sample video started and video frames advanced inside CURLYmax under the emulator's software renderer; see `artifacts/android-player.png` and `artifacts/android-playback.png`. “Open in YouTube” launched the installed YouTube app with the same Introducing Flutter video. YouTube then showed its own notification permission prompt; that permission was not granted.

The emulator's hardware graphics mode caused a Chromium `EGL_BAD_CONFIG` failure during the media check; switching to software graphics resolved it. This is a test-environment limitation to keep in mind when choosing emulator graphics. Physical-device playback, fullscreen/orientation coverage and a specifically embedding-restricted upload still need acceptance testing.

## Requires live configuration or further acceptance testing

- Hosted Google browser OAuth and email confirmation/SMTP, including provider redirects on Android.
- Cross-device notes against hosted Supabase and Realtime recovery over an actual mobile connection. Local backend behavior was tested directly; it does not prove hosted/mobile behavior.
- FCM service-account authorization, Android permission/topic delivery and taps in foreground/background/terminated states. The worker's unauthorized endpoint and service-role queue RPCs were tested; no real alert was sent.
- Actual @ashiy_ish uploads and their embedding policies. Demo uses explicitly identified third-party Flutter learning samples.
- Physical-device coverage, private Play release signing and store distribution.

Run the live acceptance checklist in `docs/SETUP.md` after supplying project configuration. Demo account entry and local grading do not verify Google/email authentication or server-side grading on Android; server grading was separately verified through real REST calls against local Supabase.
