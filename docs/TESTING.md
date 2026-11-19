# Testing

Run the credential-free application, worker and build-safety checks:

```sh
python3 scripts/test_all.py
python3 scripts/test_all.py --with-database
python3 scripts/secret_scan.py --history
```

The second command requires Docker and the PostgreSQL test image. The SQL runner creates a disposable local container; it does not target the live Supabase database. Python test modules are invoked explicitly because some database scripts have top-level execution; do not discover/import all scripts indiscriminately.

The suite covers guest/published catalog access, owner-only publishing, two-user ownership, private answer keys, server scoring, duplicate submissions, streak milestones, write rate boundaries, read receipts, account cascades, SQL-shaped content, notification authentication/visibility/timeout/receipt failures, YouTube input/upstream failures, client config key rejection and safe source packaging. Widget tests include Studio's permission failures, logout during requests, refresh coalescing and optional playlist outages, plus the viewer notification inbox and cross-account stale responses.

## Required physical release checks

Use a disposable viewer account and an independent second account. Do not share credentials with an agent or put them in test fixtures.

| Flow | Acceptance check |
|---|---|
| Guest catalog | Launch without sign-in, select channels/playlists, latest videos appear, embedded playback and YouTube fallback work. |
| Authentication | Google and email return to the intended quiz/note, including a cold app start. Owner Studio callback also returns successfully. |
| Private data | User B cannot read/edit User A's notes, attempts or receipts, using direct backend requests as well as the UI. Logout during a pending request shows no stale private content. |
| Quiz | Correct/wrong feedback, server scores, retry, once-only points/bonus, reduced motion and screen-reader announcements. |
| Notifications | Opt in, publish a genuinely new video/quiz, inspect worker status, confirm one visible alert; test foreground, background and terminated launches and exact-item navigation through sign-in. |
| Opt-out | Disable alerts offline and online, relaunch, verify pending cleanup retries. Android system notification settings provide immediate OS-level blocking. |
| Deletion | Recent sign-in and typed confirmation required; delete disposable account, verify associated private rows disappear, second user's rows remain. |
| Recovery | Airplane mode, reconnect, app resume, failed/expired session, empty playlists and backend errors remain understandable. |
| Accessibility | TalkBack, large text, contrast, focus order, reduced motion, navigation without decorative animation delays. |
| Release | Install correct-ABI signed APK; verify Play internal-track install separately, policy URLs open, app not debuggable, signing/version upgrade correct. |

Passing local tests does not verify live OAuth configuration, end-device FCM delivery, Play approval or all dependencies. Record device/model/OS/build, outcomes and failures before production release. Never substitute an FCM 'accepted' response for a device delivery test.
