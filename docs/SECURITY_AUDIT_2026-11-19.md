# CURLYmax security review — 19 November 2026

This is a source review and local test report, not a certification or a production penetration test. It describes the working tree reviewed on this date. Migration 009 was applied to the configured live project and the updated `notify-published` worker was deployed on this date. Live permission checks confirmed the inbox/read RPC exists and guests cannot claim notifications; this does not establish end-device push delivery.

## Scope and evidence

Reviewed Supabase Edge Functions for notifications, YouTube synchronization and account deletion; client configuration validation; source packaging and credential scanning; local signing/build helpers; and CI configuration. Read-only inspection used explicit file discovery because global ignore rules can hide files from ordinary searches. No Downloads credential files were read, no credentials were printed, and no production notification was sent during this review.

Directly executed:

- `node --test test/account_deletion_test.mjs test/youtube_sync_test.mjs test/notification_worker_test.mjs`: **25 tests passed** after the added regression cases.
- Deno `check --config supabase/functions/notify-published/deno.json supabase/functions/notify-published/index.ts`: **passed**. The declared `jose` dependency was downloaded for type checking; this did not deploy or invoke the worker.
- Final script checks: build/archive security **5 passed**, release security **5 passed**, YouTube setup **3 passed**. Viewer Flutter suite **32 passed**; Studio suite **14 passed**.
- Path-only scan of tracked working-tree source found no recognized private-key, service-account JSON, secret Supabase key or JWT pattern. The coordinating agent additionally reported a source/index/history scan of **364 copies** without recognized privileged credential patterns. Neither scan proves credential revocation or exhaustively recognizes every secret format.

The database reviewer separately reported passing migration 009 integration checks for draft denial, publication deduplication, two-user private/idempotent read receipts, five-event claims, service-only worker access, failed outcome preservation, per-user minute limits/window reset, and account-deletion cascades. These are local integration results, not confirmation of production migration.

## Findings addressed in the current changes

| Finding | Original impact | Current mitigation and evidence |
|---|---|---|
| Source packaging only scanned selected suffixes and omitted legacy service-role JWT recognition | Medium: an accidentally copied privileged credential in another text format could be included in a source ZIP | `scripts/secret_scan.py` recognizes private keys, service-account JSON, Supabase secret keys, Google OAuth secrets and legacy service-role JWTs. `scripts/package_source.py` scans text independently of extension, excludes signing material and local configuration, skips symlinks, and publishes the archive atomically. |
| Backend checker assumed configuration was public despite invoking privileged RPC names | Medium, conditional on a misconfigured privileged key: a supposed read-only check could claim queue rows | `scripts/check_live_backend.py` now loads the shared public-config validator before requests. `scripts/client_config.py` validates every provided Supabase key and rejects unknown fields and credential-bearing/non-origin backend URLs. |
| Notifications could become hidden between queue claim and dispatch | Medium confidentiality concern: a withdrawn publication title could still be sent to the public topic | Worker now calls the service-only `notification_ready` RPC immediately before sending. Migration 009 adds that visibility check. A test confirms a hidden-after-claim event is not sent. A narrow visibility-change race during the external request remains unavoidable without a stronger publication protocol. |
| Sequential claims of up to 50 messages could exceed worker time limits; failed receipt writes could be concealed | Reliability/observability, not demonstrated privilege escalation | Migration 009 reduces claims to five. Worker has an overall time budget, never automatically resends an ambiguous request, and returns failure when receipt persistence cannot be confirmed. Tests cover timeout, rejection, receipt failure and OAuth failure before claims. |
| Release build process lacked a dedicated private upload-key flow | Release integrity/operational risk | `scripts/setup_signing.py` creates private signing material without printing passwords; build wiring requires private release configuration and keeps test/debug output distinct. Signing credentials are excluded from source packages and Git. This does not establish Play Console enrollment or key backup. |

## Controls verified in code and mocks

Notification authentication is checked before OAuth or queue access. OAuth and FCM use fixed HTTPS provider origins with redirects rejected. Caller input cannot choose a destination topic, provider endpoint or recipient token. The worker uses structured Supabase RPC arguments rather than concatenated SQL. Errors returned to clients omit raw provider bodies and credentials.

Account deletion obtains the caller from verified Supabase Auth identity and verified claims; it does not accept a target user ID. It requires exact deletion confirmation and recent authentication. Tests cover unauthorized callers, methods, oversized authorization, malformed/oversized bodies, stale/future authentication, the 15-minute boundary, exceptions and provider failure without false success.

YouTube synchronization authorizes a scheduler secret or verified owner. Requests use fixed YouTube API resources, bounded pagination and time/request budgets. Tests cover private/foreign content exclusion, private playlists never fetched, 50-item batching, unknown metrics remaining null, authorization exceptions, malformed responses and sanitized upstream failures.

## Residual risks and release gates

- **Previously exposed credentials:** Firebase service-account private keys and a scheduler credential appeared in earlier conversation context. Revocation/replacement of every exposed credential remains unconfirmed. A clean repository scan does not make an exposed credential safe.
- **Production state:** migration 009 and the new worker are deployed. Public-key live checks passed catalog access and denial of questions, private tables and owner/worker RPCs. The two-user integration tests ran locally, not against real production viewer accounts. Scheduler/device delivery and OAuth still require end-to-end verification.
- **Real devices:** Google OAuth and foreground/background/cold-start notification delivery and navigation were not exercised on a live Android device in this audit. Topic acceptance by FCM is not per-device delivery. No exactly-once delivery guarantee is made.
- **Retention and storage:** per-minute write limits reduce bursts but do not bound lifetime notes, quiz attempts/runs, notifications or read receipts. Establish retention, per-user storage quotas and operational monitoring. No cleanup policy should silently remove user data without an explicit product decision.
- **Database contention:** the database reviewer identifies concurrent quiz editing as a remaining source of transient database deadlocks. Such failures must roll back safely and be surfaced as retryable database operations; external notification sends must not be blindly retried. Passing the migration integration suite does not prove all concurrent lock orders are safe.
- **Credential detection:** text-pattern scanning is defense in depth. Binary/encoded credentials, arbitrary bearer secrets and files omitted by scan scope may not be recognized. Keep privileged credentials in server secret storage rather than source files.
- **Dependencies/CI:** successful tests and type checking are not a full dependency vulnerability audit. Maintain lockfiles, review dependency updates, and prefer immutable action revisions with minimal workflow permissions.
