# CURLYmax redesign checklist

- [x] Map source relationships with Graphify and inspect authentication, private data and publishing boundaries.
- [x] Section 1: native Android Google account picker, email/guest welcome, first-use guide, notification permission and automatic topic registration after grant.
- [x] Section 2: System/Light/Dark themes, bottom navigation, selected/all-channel search, YouTube/newest/oldest playlist order.
- [x] Section 3: full-page private notes with autosave, checklist insertion, retry and unsaved-change protection.
- [x] Section 4: Studio web/mobile/mac theme and guide; macOS package build script and preflight.
- [x] Section 5: viewer/Studio analysis and tests, server function tests, local SQL fixtures, secret scan/history, Android debug APK and Studio web build.
- [ ] Supply the public Google Web OAuth client ID and register Android OAuth certificate fingerprints; rebuild signed viewer and Studio builds.
- [ ] Install full Xcode, build and test the unsigned local macOS `.pkg`; sign and notarize before public Mac distribution.
- [ ] Verify live sign-in, notification receipt/taps, external policy URLs and a Play installed release on physical devices.

Light surfaces use the supplied pastel palette with dark text. Dark surfaces use
`#121820` / `#1D2833`, blue `#99C1DE`, cyan `#C5DEDD`, pink `#FAD2E1`, and text `#F0EFEB`.
Guests retain published video access; notes and quizzes require authentication.
Studio remains owner-only. No migration or destructive live-data operation is planned.
