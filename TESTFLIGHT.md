# Hermes Mobile TestFlight Runbook

This is the owner-only release path for Hermes Mobile. It does not describe contributor CI and it does not treat any inherited HermeX build or App Store Connect record as evidence for this app.

## Current status

Hermes Mobile is not yet signed or installed from TestFlight. Before release, the owner must provide their Apple identity through GitHub's protected repository settings, upload an internal build, and complete the physical-iPhone checks below.

The pull-request gate already covers:

- the native iOS `URLSessionWebSocketTask` talking to an authenticated Hermes `/api/ws` fixture over WSS;
- all-profile discovery, session creation, prompt submission, and streamed completion;
- the full XCTest suite;
- a generic physical-iPhone compilation with signing disabled; and
- simulator launch plus a first-run pairing screenshot.

Those checks are source and simulator evidence. They are not a signed-device or TestFlight receipt.

## 1. Create the Apple app identity

In the owner's Apple Developer and App Store Connect accounts:

1. Register the production bundle identifier `com.bkashjee.hermesmobile`, or choose another owner-controlled identifier before the first upload.
2. Create the Hermes Mobile app record with the same bundle identifier.
3. Enable only the capabilities required by the Xcode project.
4. Create an App Store Connect API key with the minimum role needed to upload builds.
5. Record the Apple Developer Team ID, API key ID, and issuer ID.

Do not reuse the original HermeX maintainer's Team ID, app record, certificates, or provisioning profiles.

## 2. Configure GitHub safely

Open the fork's **Settings → Secrets and variables → Actions** page.

Create repository variables:

- `APPLE_TEAM_ID` — the owner's Apple Developer Team ID.
- `APP_BUNDLE_ID` — normally `com.bkashjee.hermesmobile`.

Create repository or protected-environment secrets:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`

Paste the complete `.p8` key only into the GitHub secret field. Never put it in a terminal transcript, issue, pull request, artifact, or chat.

The workflows stop before checkout if any required value is missing. They also pass `DEVELOPMENT_TEAM` explicitly, so the repository's inherited signing default is never used for an owner upload.

## 3. Configure local device signing

Create `Config/Local.xcconfig` on the Mac that will run the device smoke test:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

`Config/Local.xcconfig` is gitignored. Do not edit `Config/Shared.xcconfig` or commit a personal Team ID.

Open `HermesMobile.xcodeproj`, select the Hermes Mobile scheme, choose the physical iPhone, and confirm that Xcode resolves signing for the app and its extensions.

## 4. Validate the release candidate

Use one exact commit for every check. Record its full SHA.

```zsh
git status --short
git rev-parse HEAD
xcodebuild test \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Required results:

- the worktree is clean;
- the intended commit is pushed;
- pull-request CI is green on that commit;
- the app builds and launches on the owner's iPhone; and
- no credentials appear in logs, screenshots, or artifacts.

## 5. Run the internal TestFlight upload

The `Internal TestFlight` workflow is intentionally manual and accepts only `master`.

1. Merge the reviewed release candidate only after owner approval.
2. Open **Actions → Internal TestFlight → Run workflow**.
3. Select `master`.
4. Enter `INTERNAL` in the confirmation field.
5. Leave the build number blank unless App Store Connect requires an explicit override.
6. Wait for archive, export, and upload to finish.
7. Confirm the exact version, build number, commit SHA, Team ID, and bundle identifier in the workflow receipt.
8. Wait for App Store Connect processing and add the build to the owner's internal tester group.

Do not treat a successful upload command as proof that the build is processed or installable.

## 6. Physical-iPhone acceptance

Install the exact internal build from TestFlight and verify:

- first launch respects the status bar, Dynamic Island, and home indicator;
- the camera permission prompt appears only after tapping the pairing scanner;
- QR pairing from Hermes Desktop succeeds over the owner's private HTTPS route;
- the roster shows every configured Hermes profile without exposing hidden credentials;
- an existing session resumes and streams without remounting when a sheet opens;
- a new run can be started for a non-default profile;
- steering and stopping a running session work;
- allow and deny approval responses reach the correct session;
- Skills and Memory load from the same gateway;
- a queued message remains visibly queued while offline and sends only after reconnection;
- the accent-color picker persists the chosen theme;
- dictation and Talk mode request microphone permission at the point of use; and
- force quit, relaunch, lock/unlock, Wi-Fi changes, and Desktop reconnect do not lose the saved pairing.

Record failures against the exact build number. Do not promote a different local build based on the TestFlight result.

## 7. External TestFlight

Only after the internal build passes the physical-device checklist:

1. Complete TestFlight test information, privacy details, review notes, and support contact fields.
2. Ensure the review gateway and test account are available for Beta App Review without exposing private production agents.
3. Open **Actions → External TestFlight → Run workflow** from `master`.
4. Enter `EXTERNAL_REVIEW` in the confirmation field.
5. Confirm the uploaded build is not marked internal-only.
6. Assign external groups and submit Beta App Review manually in App Store Connect.

The workflow uploads a build. It does not invite testers, submit review, or publish the app automatically.

## Stop conditions

Do not upload or promote when any of these is true:

- the source commit differs from the reviewed and tested commit;
- pull-request CI is missing or red;
- the Hermes Desktop pairing change is not available to testers;
- the phone route is plain HTTP, public without an explicit owner decision, or points to a stale backend port;
- Apple Team ID, bundle ID, signing certificate, or app record do not belong to the owner;
- the internal build has not passed the physical-iPhone checklist;
- the privacy policy or Beta App Review information is incomplete; or
- any token, password, certificate, private key, or private profile data appears in release evidence.

## Release evidence to retain

Keep a non-secret release receipt containing:

- mobile commit SHA;
- matching Hermes Desktop commit SHA;
- pull-request and CI URLs;
- App Store Connect version and build number;
- bundle identifier and Apple Team ID;
- internal installation date and device/iOS version;
- gateway route type, without its token;
- physical-device checklist result; and
- Beta App Review or external testing status.

Anything not listed in that receipt remains unverified.
