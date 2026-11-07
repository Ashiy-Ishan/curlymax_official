# Dashboard verification — 6 November 2026

- `flutter analyze`: no issues.
- `flutter test`: 2 tests passed (required video fields, channel-scoped sections, new-quiz draft defaults and publication guidance).
- `flutter build web --release`: succeeded. This compilation check used no live configuration; launch using `scripts/run.py` or build with `--dart-define-from-file=config.json` to connect to your project.
- Python launcher syntax checked.

Not yet verified: SQL upgrade execution, direct guest/two-user permission tests of new RPCs, live owner CRUD, browser Google OAuth return, notification-status retrieval, or actual notification sending. The SQL must be run and your account granted owner membership as described in README.md. The app does not contain a service-role key or credentials for sending notifications.
