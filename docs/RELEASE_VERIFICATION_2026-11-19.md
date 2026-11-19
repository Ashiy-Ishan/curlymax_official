# Release verification — 19 November 2026

Status: signed release candidate built; production release still gated by live device tests, credential revocation confirmation and public policy hosting.

| Check | Result |
|---|---|
| Viewer analyzer | No issues |
| Studio analyzer | No issues |
| Viewer Flutter tests | 32 passed |
| Studio Flutter tests | 14 passed |
| Node worker/auth/sync tests | 25 passed |
| Python configuration/archive/release/setup tests | 13 passed |
| Disposable PostgreSQL integration suite | Passed, including migration 009, two-user permissions, duplicate scoring and rate boundaries |
| Notification Deno type check | Passed |
| Source/index/history recognized-secret scan | Passed; limited pattern scan, not key revocation verification |
| Additive live migration 009 | Applied successfully |
| Updated notification worker | Deployed successfully |
| Live public-key backend checks | Published catalog available; private tables, grading, owner/worker operations denied to guests |
| Live notification RPC permissions | Inbox/read RPC present, guest claim denied, authenticated read marking executable |
| Release APK build | Three signed ABI splits built; ARM64 APK signature verified (v2) |
| Release AAB | Built; jarsigner reports jar verified; self-signed upload certificate and ZIP stream-order warnings retained in artifact log. Validate in Play internal upload before treating as accepted. |
| Android manifest | Backup off, cleartext traffic off; no debuggable flag enabled |
| Static policy content/relative links | Passed source parsing; browser host unavailable, visual QA not completed |
| GitHub Pages | Files/workflow prepared; publication/reachable URLs not verified |
| Physical Android / Google OAuth / FCM delivery | Not run in this pass |

Artifacts in `artifacts/`: ABI release APKs, Play bundle, sanitized source ZIP and SHA256SUMS. Build logs and verification outputs are local and ignored by Git. Neither a successful FCM request nor a passing mock proves device receipt. No live user account was deleted and no test publication was inserted into the production catalog in this pass.

This review does not certify that every possible vulnerability is absent. See `SECURITY_AUDIT_2026-11-19.md`, `RELEASE.md` and `TESTING.md` for findings, rebuild steps and remaining release gates.
