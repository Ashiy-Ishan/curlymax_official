# CURLYmax redesign security and QA — 27 November 2026

The new viewer surfaces were reviewed against the existing server authorization model. Graphify mapped 916 code nodes and 1,264 edges after this change; its source-only graph skips 66 configuration/resource files, which were inspected separately where relevant. The graph is in `graphify-out/` and has no token cost.

## Checks passed

- `python3 scripts/test_all.py`: viewer and Studio analysis/tests, Node Edge Function tests, public-source secret scan, release and setup script checks all pass. The full result is credential-free and uses no live user accounts.
- `python3 scripts/test_quiz_feedback.py`: all isolated PostgreSQL fixtures pass, including owner-only quiz import, private answer keys, note/attempt ownership, account deletion cascade, and concurrent duplicate answer awards.
- `python3 scripts/secret_scan.py --history`: 438 public source/index copies scanned, with no recognized privileged credential pattern. The scan cannot verify revocation or detect every encoding.
- `flutter build web --release` from `dashboard/`: succeeds with public config. `python3 scripts/build_android.py` creates an Android debug APK at `artifacts/CURLYmax-live.apk`; Studio's Android debug APK is at `artifacts/CURLYmax-Studio-redesign-test.apk`. Both APK signatures verify. The source archive at `artifacts/CURLYmax-source.zip` excludes ignored client config and signing files.
- Native Android Google sign-in obtains an ID and access token through Google's account picker, then calls Supabase Auth; no Google client secret is stored in either app. The public Web client ID is validated before the viewer release build. Email credentials stay in Flutter's sign-in form and Supabase Auth; Studio still checks owner membership after authentication.
- Search filters the published in-memory catalog; it does not construct SQL. Notes use typed PostgREST operations and server RLS. A stable random UUID makes autosave retries idempotent, while the insert omits `user_id` so PostgreSQL assigns `auth.uid()`. A duplicate ID can update only a note with matching user and video IDs.
- Notification destinations accept only known kinds and UUID item IDs. Opt-in starts FCM topic registration after Android permission; opt-out clears the requested flag and unsubscribes. No private note, quiz answer or score is sent in public push payloads.
- Both Android manifests disable cleartext and backup. Studio's database mutations remain owner-gated by PostgreSQL policies/functions, not by a hidden client key.

## Release gates and remaining risks

1. **Google setup:** ignored `config/live.json` and `dashboard/config.json` currently lack `GOOGLE_WEB_CLIENT_ID`. The viewer release builder correctly refuses an AAB until a real public Web client ID and matching Android OAuth clients/certificate fingerprints are configured. Native Google sign-in was compiled but not exercised with a real account. Google Auth Platform branding is still a separate external configuration step.
2. **Notification delivery and device smoke:** the Firebase Android client fields exist, but no connected phone was available during this run. A headless Android emulator reached the viewer startup screen, then its System UI stopped responding during screenshot capture, so it did not provide a reliable interaction test. Permission grant, FCM delivery and notification-tap routing remain physical-device checks. The server sender's live state was not changed or verified here.
3. **Policy URLs:** GitHub Pages privacy and account-deletion URLs could not be independently fetched from this environment. Confirm both open publicly, without a portfolio redirect, before Play submission.
4. **Mac installer:** `dashboard/scripts/build_macos_pkg.py` passes public-config validation, then stops at its Xcode preflight. This Mac has only Command Line Tools. No `.pkg` was produced or installed. A local package will be unsigned; public Mac distribution requires signing/notarization.
5. **Historical credentials:** privileged Firebase and scheduler credentials were pasted into earlier conversation context. Their replacement or revocation was not independently verified. Repository cleanliness alone cannot revoke exposed credentials.
6. **Offline notes:** autosave keeps unsaved content visible and blocks leaving until retry/discard, but a process kill while offline can lose an unsynced in-memory edit. Private drafts are intentionally not written to ordinary local preferences.
7. **Backend scope:** SQL tests run in a disposable database; they do not substitute for guest and two-real-user permission probes on production. Existing residual risks around lifetime storage quotas, concurrent owner quiz edits and external send ambiguity remain in `SECURITY_AUDIT_2026-11-19.md`.

This is a release candidate after the external gates are completed and tested. It is not evidence of Play approval or a guarantee of exhaustive security coverage.
