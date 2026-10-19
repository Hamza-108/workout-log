# Workout Log

A small native iPhone workout tracker, developed on Linux and compiled on GitHub's macOS runners. Install the unsigned IPA using SideStore, which signs it with your Apple Account.

**Current status: setup / installation proof only.** The app displays a setup screen. Templates, logging and history are planned, not implemented. See [PLAN.md](PLAN.md).

## Install on your iPhone

1. Download `WorkoutLog-unsigned.ipa` from [Releases](https://github.com/Hamza-108/workout-log/releases). Before a release exists, use a successful [Actions run](https://github.com/Hamza-108/workout-log/actions): download the `WorkoutLog-unsigned` artifact and extract its ZIP in Files. GitHub artifact downloads require signing in.
2. With your existing SideStore VPN/setup working, open SideStore → My Apps → **+** and choose the `.ipa` from Files.
3. Open **Workout Log**. The setup build should say **Ready to log your workouts**. This is the device acceptance check; CI alone cannot verify your Apple Account or SideStore installation.
4. Refresh SideStore and this app before the seven-day expiry. Background refresh is best effort; verify expiry dates instead of assuming refresh will always work.

No paid Apple Developer membership, jailbreak, Mac or Apple credentials in GitHub are needed. Free-account limits apply: normally three active sideloaded apps **including SideStore**, and ten App IDs per week. This app has no extensions, special entitlements or JIT requirements. Enable Developer Mode if iOS requests it; a working SideStore setup may already have this configured.

**Updates:** install the newer IPA over the existing app using the same Apple Account and app identity. Do not uninstall to update: uninstalling deletes local app data. The planned tracker stores data locally; no cloud backup or export exists in this setup build.

## Build and test

- Linux: edit source, commit to a feature branch, push. GitHub Actions generates the Xcode project with XcodeGen, runs an iPhone simulator launch test, builds for a physical iPhone, and packages an unsigned IPA.
- macOS with Xcode 16.4 and XcodeGen: `xcodegen generate`, then `xcodebuild test -project WorkoutLog.xcodeproj -scheme WorkoutLog -destination 'platform=iOS Simulator,name=<available iPhone>' CODE_SIGNING_ALLOWED=NO`. Find available destinations with `xcodebuild -project WorkoutLog.xcodeproj -scheme WorkoutLog -showdestinations`.
- Workflow: [`.github/workflows/ios.yml`](.github/workflows/ios.yml). Manual runs become available on the Actions page once the workflow is merged into the default branch. Branch pushes and PRs build before merge.
- Successful `main` builds publish a versioned GitHub Release. Stable download URL once the first main release is published: `https://github.com/Hamza-108/workout-log/releases/latest/download/WorkoutLog-unsigned.ipa`.

Deployment target: iOS 17+. Your iOS 26 phone can run apps built with an earlier supported SDK. Bundle identifier: `com.hamzabehrem.workoutlog`; keep it stable across updates. No third-party app dependencies. XcodeGen is a build-time tool only.

## Cost and privacy

This repository and its source/builds are **public**. Standard GitHub-hosted Actions runner execution is free for public repos; private repos also have an included quota, but macOS usage consumes it quickly. Artifact storage has separate allowances; retention here is short. Never put credentials, signing keys or personal workout databases in this repo. Actual workout data will stay in the app's private on-device storage.

## References

- [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [SideStore FAQ and free-account limits](https://docs.sidestore.io/docs/faq)
- [GitHub macOS 15 runner software](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
- [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
