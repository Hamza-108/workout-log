# Workout Log

A small native iPhone workout tracker, developed on Linux and compiled on GitHub's macOS runners. Install the unsigned IPA using SideStore, which signs it with your Apple Account.

**Current status: first usable core.** Create ordered exercise templates, log weight/reps/exertion (0–10), resume unfinished workouts and browse history. Everything is stored locally using SwiftData. See [PLAN.md](PLAN.md).

## Install on your iPhone

1. Download `WorkoutLog-unsigned.ipa` from [Releases](https://github.com/Hamza-108/workout-log/releases). Before a release exists, use a successful [Actions run](https://github.com/Hamza-108/workout-log/actions): download the `WorkoutLog-unsigned` artifact and extract its ZIP in Files. GitHub artifact downloads require signing in.
2. With your existing SideStore VPN/setup working, open SideStore → My Apps → **+** and choose the `.ipa` from Files.
3. Open **Workout Log** → create a template → add exercises → start a workout → add a set → finish → open History. Close and reopen during a workout to check Resume. CI tests this flow on a simulator; your device still needs the SideStore acceptance check.
4. Refresh SideStore and this app before the seven-day expiry. Background refresh is best effort; verify expiry dates instead of assuming refresh will always work.

No paid Apple Developer membership, jailbreak, Mac or Apple credentials in GitHub are needed. Free-account limits apply: normally three active sideloaded apps **including SideStore**, and ten App IDs per week. This app has no extensions, special entitlements or JIT requirements. Enable Developer Mode if iOS requests it; a working SideStore setup may already have this configured.

**Updates:** install the newer IPA over the existing app using the same Apple Account and app identity. Do not uninstall to update: uninstalling deletes local app data. The tracker stores data locally; no cloud sync or export is implemented. Do not use it as your only long-term record yet.

## Using the tracker

- Choose kg/lb before starting. Each session keeps its original unit.
- Templates: add/edit exercises; use Edit to reorder or swipe to remove. Editing/deleting a template never rewrites saved or active workouts.
- Add a set with weight, positive whole-number reps and RPE 0–10. Use your locale’s decimal separator; zero weight supports bodyweight movements.
- Tap a saved set to correct it; swipe to delete with confirmation. Close a workout to resume later. Finish needs at least one set.
- Saved sets persist immediately; text still being typed in an unsaved editor does not.
- History shows finished workouts. Swipe a workout to delete with confirmation.

## Build and test

- Linux: edit source, commit to a feature branch, push. GitHub Actions generates the Xcode project with XcodeGen, runs model/persistence tests and an iPhone simulator workout flow, builds for a physical iPhone, and packages an unsigned IPA.
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
