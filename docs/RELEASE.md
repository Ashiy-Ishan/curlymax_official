# Android release guide

The viewer source is CURLYmax 1.0.0. Rebuild signed artifacts after any source change; files already in `artifacts/` may be older. Builds are release candidates for testing, not evidence of Play approval or completed device validation.

## Files to distribute

- `CURLYmax-arm64-v8a-release.apk`: modern physical Android phones, about 19 MiB.
- `CURLYmax-armeabi-v7a-release.apk`: older 32-bit ARM phones, about 17 MiB.
- `CURLYmax-x86_64-release.apk`: x86 Android devices/emulators, about 21 MiB.
- `CURLYmax-release.aab`: upload to Play Console, about 53 MiB. This is not directly installable.
- `CURLYmax-source.zip`: sanitized source, rebuilt separately by the packaging script.

The bundle version code comes from `pubspec.yaml`; each subsequent Play upload must use a higher code. Split APKs have ABI offsets. Do not mix sideloaded ABI builds and Play upgrades without checking version codes and signing certificates.

## Build again

Before building a release, add the public `GOOGLE_WEB_CLIENT_ID` to ignored `config/live.json`, create matching Google Android OAuth clients for the upload and Play signing certificates, and finish the Supabase Google provider setup in [SETUP.md](SETUP.md). The release builder now stops when the client ID is absent because the native Google button would fail. Firebase client settings, policy URLs and private upload signing must also be configured.

```sh
python3 scripts/setup_signing.py  # first machine only; never replace an existing upload key
python3 scripts/build_android.py --release
python3 scripts/build_android.py --release --format aab
python3 scripts/package_source.py
```

Keep `.signing/curlymax-upload.jks` AND `android/key.properties` backed up privately together, using encrypted storage. Both are ignored by Git and excluded from source packages. Do not send either to testers or attach them to issues. Losing the key requires Play's upload-key recovery process. Release builds fail closed when signing configuration is absent and never fall back to debug signing.

A release signed with this key cannot update an existing debug-signed installation. Do not uninstall an existing app until private data has synchronized and you understand that local data will be removed. Play App Signing can use a different distribution certificate; configure provider certificate requirements for the distributed build.

## Public repository and working APK

Use ignored `config/live.json` locally, based on `config/live.example.json`. The build compiles only supported public client settings. Supabase publishable/anon keys and Firebase Android client settings are identifiers intended for distribution; they can be extracted from an APK. RLS, verified Auth sessions and server-side authorization protect data. Obfuscation is not a way to protect a service-role key.

Never compile or commit Supabase service-role keys, database passwords, Google OAuth client secrets, Firebase service-account private keys, scheduler secrets or upload signing credentials. Store server credentials in Supabase Edge Function secrets. Revoke all previously exposed credentials; removing a file or hiding it with `.gitignore` does not revoke it. Run `python3 scripts/secret_scan.py --history` before publishing. Its scope and limitations are described in the audit.

## Privacy and account deletion pages

The static `website/` folder contains the developer identity, app homepage, privacy policy, support and account deletion instructions. The `.github/workflows/pages.yml` workflow deploys that folder on `main` when website files change. The custom-domain homepage and privacy page returned HTTP 200 without a redirect on 27 November 2026:

- https://curlymax.ashinshanaishan.me/
- https://curlymax.ashinshanaishan.me/privacy.html
- https://curlymax.ashinshanaishan.me/delete-account.html

The homepage uses the public GA4 `gtag.js` ID to measure visits; the privacy and deletion pages do not load analytics. The privacy policy discloses this. If the domain changes, update the public URL settings in ignored `config/live.json` and rebuild. The app also bundles an offline privacy-policy screen. Its deletion-request and support actions open an email draft to curlymax.dev@gmail.com; they do not automatically send mail or delete an account. The separate direct deletion action remains under Your account.

For Google OAuth branding, verify the `ashinshanaishan.me` **Domain property** in Google Search Console using the same Google account that owns or edits the OAuth project. A root-domain verification covers its subdomains. A Google verification TXT record already exists at the root domain, but DNS alone cannot show which Google account owns it. Also add `https://curlymax.ashinshanaishan.me/` as a **URL-prefix property** to check the exact homepage; it should inherit verification from the root property. If needed, choose **Google Analytics** verification only if that account also has Editor access to GA4 stream `G-LHEX5KRY9N`; the `gtag.js` snippet is in the public homepage head. Confirm the property says **Verified owner**. In Google Auth Platform → Branding, set Authorized domain to `ashinshanaishan.me`, homepage to `https://curlymax.ashinshanaishan.me/`, and privacy policy to `https://curlymax.ashinshanaishan.me/privacy.html`. Then retry branding after its stated wait and reply to Google's verification email if one was sent. The homepage and privacy URLs should not redirect to the portfolio. Google documents [homepage ownership](https://support.google.com/cloud/answer/13807376), [Authorized domain checks](https://support.google.com/cloud/answer/15548748) and [Search Console verification methods](https://support.google.com/webmasters/answer/9008080).

## Play Console checklist

1. Create the app and enroll in Play App Signing. Upload the AAB to internal testing first.
2. Complete store listing, screenshots, content rating, target audience, ads declaration, app access instructions and Data safety. Review the final SDK inventory; do not declare that the app collects no data.
3. Inventory: account email/user ID; private notes; quiz answers/scores/history; notification read status; Firebase registration/device identifiers for opt-in push; YouTube embedded-player processing and provider logs. Distinguish optional collection, purposes, retention, sharing and deletion based on actual configuration and provider policies.
4. Supply reachable policy and external account-deletion links. Verify in-app deletion with a disposable viewer and confirm ownership boundaries with a second viewer. Do not use your only owner account for destructive tests.
5. Complete the device matrix in `TESTING.md`, including Google sign-in return, push in three lifecycle states, opt-out, offline recovery and release installation.
6. For personal developer accounts subject to the new-account testing requirement, Google currently requires at least 12 testers opted in continuously for 14 days before applying for production access. Your planned 14 testers provide some margin; they must remain opted in. Follow your Console's actual eligibility requirements.
7. Review pre-launch reports and crash/ANR results before applying for production. Production submission remains the owner's final decision.

Official references checked 19 November 2026:
- https://support.google.com/googleplay/android-developer/answer/14151465
- https://support.google.com/googleplay/android-developer/answer/10144311

## Backend upgrade

Existing installations through migration 008 use the additive `supabase/migrations/202611190009_release_security.sql`, then deploy `notify-published`. Both were applied to the configured live project on 19 November 2026. Fresh installations use `supabase/install.sql`. Never rerun the fresh-install script over production data.

The notification worker now checks publication visibility immediately before sending, claims five events, bounds requests and reports receipt-persistence failures. An FCM acceptance is not proof of delivery on a phone. Do not blindly resend ambiguous sends. See the audit and verification reports for limits.
