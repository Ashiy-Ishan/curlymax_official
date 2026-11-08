# Studio verification — 8 November 2026

- `flutter analyze`: no issues.
- `flutter test`: ten tests passed, including public-only configuration validation, channel-scoped form fields, quiz draft defaults, channel icon HTTPS validation, atomic draft-form payload, explicit answer selection, legacy six-option preservation, and YouTube settings validation at a 390×844 logical-pixel mobile viewport.
- `flutter build web --release --dart-define-from-file=config.json`: succeeded.
- `flutter build apk --debug --dart-define-from-file=config.json`: succeeded. Separate package: `com.curlymax.studio`; artifact: `../artifacts/CURLYmax-Studio.apk`.
- Native manifest disables backups and cleartext traffic. Native Supabase sessions are not persisted. Google callbacks are restricted to Studio's scheme/host. Backend owner authorization is required in addition to the UI gate.

Not verified on a physical Android device in this task: installation, Google callback, owner sign-in/CRUD, or YouTube synchronization. The YouTube API key is not configured yet. The sync worker/database migration/scheduler must be installed before the new controls work; see README. Public metrics are totals reported by YouTube, not private creator analytics. Playlist membership is sync-managed.

The APK is debug-signed for testing, not a production release. No Firebase Admin or Supabase service-role credentials are included in dashboard source/configuration.
