# workout-log
A simple offline iPhone workout log, built on GitHub Actions for SideStore sideloading (Vibecoded using 6.1-sol)

## Install / update

Download `WorkoutLog-unsigned.ipa` from a tested [release](https://github.com/Hamza-108/workout-log/releases), then install it through SideStore. Refresh before the free-account signing expiry (normally seven days).

**Update over the existing app with the same Apple Account and app identity. Do not uninstall: that deletes local workouts.** Keep separate workout records until the on-phone checks below pass. Bundle ID stays `com.hamzabehrem.workoutlog`.

The 0.3 preview adds a Live Activity extension. Preserve app extensions when SideStore signs the IPA; the extension may consume another App ID under free-account limits. Signing/install acceptance on a real phone is still unverified. No paid membership, signing credentials in GitHub, server or App Group is required by the code.

## Logging

- Make a template with ordered exercises. Choose kg/lb before starting; each workout keeps its original unit and exercise snapshot.
- Log weight, positive whole-number reps and exertion/RPE 0–10. Zero weight is allowed. Tap a saved set to edit it; swipe to delete with confirmation.
- **Close** leaves the workout unfinished and resumable. Saved sets persist; text still in an unsaved editor does not.
- **Finish** asks for confirmation before moving a workout to History. Cancel keeps logging.
- Delete a finished workout from its detail screen, or swipe it in History. Confirmation names the workout/date. Templates and other workouts stay intact.

## Import a template

Templates → **More (…) → Import template** → select a `.json` file:

```json
{"name":"Push day","exercises":["Bench press","Overhead press","Triceps pushdown"]}
```

Review/edit the prefilled editor, then Save. Cancel creates nothing. Each saved import is a new template with a new ID; existing templates are never replaced. Empty names and duplicate exercise names are rejected.

## Backups

Templates → **More (…) → Data and backups** → **Export backup** or **Import backup**. Choose a private Files destination: backups contain your workout history as **unencrypted plain-text JSON**. Files/iCloud-provider behavior still needs an on-phone check.

Import shows new/skipped counts and asks for confirmation. It adds missing records in one save:

- Same record kind + UUID + identical contents: skip.
- Same UUID with different contents: reject the entire import. No automatic overwrite or destructive restore mode.
- A different unfinished workout already exists: reject; finish/discard it before retrying.
- An empty store restores the backup's new-workout unit preference. A populated store keeps its current preference. Historical weights are never relabeled.

Export your current data before resolving conflicting copies. Keep the original backup file. Imports do not include unsaved editor text, and importing an old backup can bring back records you deleted since exporting it.

### Backup format (version 1)

```json
{"schemaVersion":1,"preferredWeightUnit":"kg","templates":[],"sessions":[]}
```

- Template fields: `id` (UUID), `name`, ordered `exercises`.
- Session fields: `id`, `startedAt`, optional/null `finishedAt`, `templateName`, ordered `exercises`, `unit` (`kg`/`lb`), ordered `sets`.
- Set fields: `id`, `exercise`, `weight`, `reps`, `rpe`. Weights/RPE are JSON numbers, independent of keyboard locale.
- Dates use UTC ISO-8601 **millisecond precision**, e.g. `2026-01-01T12:00:00.123Z`. Conflict comparison uses that same precision.
- Input/export limit: **25 MiB**. Invalid fields, duplicate record/set IDs, empty completed workouts and multiple drafts are rejected before insertion. Workouts do not need a surviving template.

## Lock Screen resume

Starting or explicitly resuming a saved workout requests a local Live Activity reading **Session in Progress**. Tap it to reopen that exact unfinished workout (unlocking may be required). Finishing/discarding ends it only after a successful save. Disabled/unavailable Live Activities never prevent logging; in-app Resume is the fallback.

This is not a permanent notification: iOS/user settings control visibility. Activities can run for up to eight hours; an ended presentation can remain on the Lock Screen for up to four more hours unless dismissed sooner. Dismissal or expiry never finishes the saved workout. No weights or exercise names are shown on the Lock Screen.

## Build / checks

GitHub Actions on macOS runs model/persistence tests and iPhone UI workflows, builds the unsigned Release app plus widget extension, and checks IPA identity, versions, icon and extension metadata. On macOS: `xcodegen generate`, then `xcodebuild test -project WorkoutLog.xcodeproj -scheme WorkoutLog -destination 'platform=iOS Simulator,name=<available iPhone>' CODE_SIGNING_ALLOWED=NO`. Linux cannot run Xcode/XCTest.

Physical-device checks remain pending: in-place SideStore update and extension signing, Files export/import round trip, Lock Screen tap/resume/finish (including disabled Activities), and icon/accessibility appearance on iOS 26. Simulator tests/builds do not prove these.

Minimum iOS 17; Xcode 16.4 CI; no third-party runtime dependencies. The stickman icon's editable source is [`assets/icon-source.svg`](assets/icon-source.svg). This repo/builds are public: never commit credentials, real workout exports or databases.
