# Security review and owner access

The publishing dashboard is for the account listed in `private.owners`. There is no built-in owner email or password. Creating a viewer account, changing user metadata, or installing the dashboard does not grant publishing access. The dashboard checks `is_owner()`, and PostgreSQL independently checks every catalog write and owner RPC.

Viewers retain access to the published catalog, authenticated quizzes, and their own notes and attempts. Public Supabase client keys identify the project; RLS and authenticated user identities control data access. The app must communicate with the Supabase API to provide those features. Database passwords, service-role keys, OAuth secrets and Firebase service-account credentials belong in trusted server configuration only.

## Changes in this review

- Enable RLS on private owner, answer-key, notification and quiz-run tables as an additional layer behind revoked client privileges.
- Serialize answer-key edits with quiz publication and invalidate unfinished quiz runs when grading data changes.
- Reject privileged, malformed and unknown-role keys in build/launch scripts, including a second configured key.
- Reject server-only settings in client configuration. Exclude local settings, private-key files and symlinks from source archives; scan for service-account JSON and private credentials before replacing an archive.
- Keep destructive test fixtures restricted to the exact local Supabase endpoint, including when Python assertions are disabled.
- Disable Android backup and cleartext traffic in the viewer app's main manifest. The debug-only network configuration permits the local test hosts.

## Database upgrade

Existing installations should apply versioned migrations in order. The security migration is `supabase/migrations/202611070004_owner_security.sql`; it requires the quiz-feedback migration `202611060003_quiz_feedback.sql`. Do not rerun the fresh-install script over an existing database.

Keep the `private` schema out of the Data API's exposed schemas. Manage owner membership only through the trusted Supabase SQL console. Never put an owner UUID check only in Flutter: a modified client can bypass UI checks.

## Injection and authorization checks

Catalog operations use Supabase's structured query API. RPC inputs are typed parameters; content is not interpolated into executable SQL. Security-definer functions use qualified object names and an empty search path. Text containing SQL syntax is stored as content. The notification sender uses fixed Google endpoints and validates its scheduler authorization before claiming work.

`python3 scripts/test_security_scripts.py` runs isolated configuration/archive regressions with synthetic credentials. `python3 scripts/test_quiz_feedback.py` applies all migrations to a disposable offline PostgreSQL container and exercises guest, viewer and owner permissions, private answer keys, answer validation and concurrent duplicate scoring. These checks cover the exercised paths; they are not a penetration-test certification.

## Credentials already shared

Service-account private keys were previously included in conversation/IDE context. Delete those exposed keys in Google Cloud IAM and generate replacements privately if this has not already been done. Save the replacement JSON only in the Supabase Edge Function secret `FCM_SERVICE_ACCOUNT_JSON`. Deleting a downloaded JSON file alone does not revoke a key. Close private-key files before sharing IDE context. The application source and dashboard do not need those files.

Cloud project owners and people with SQL-console access remain privileged administrators. Protect those accounts with MFA, limit project/team access, and use a unique strong password and MFA for the publishing account where supported. Anyone with a compromised owner session can perform the actions that owner is authorized to perform.

See `VERIFICATION.md` and the dashboard README for the precise tests, deployment status and device checks still required.
