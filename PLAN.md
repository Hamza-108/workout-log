# Workout Log — offline templates, weight and exertion tracking

## What

A native iPhone app you can sideload with your existing SideStore installation on iOS 26. Create reusable workout templates, start a workout, record each set's weight, reps and exertion (RPE 0–10), then review past workouts. No account, server or subscription.

## Why

Keep a straightforward record of what you lifted and how hard it felt, without filling out an overcomplicated fitness app. Work from Linux without buying a Mac or paying for an Apple Developer membership.

## Decisions and scope

- Confirmed: iOS 26, SideStore already installed, free Apple Account, weight + reps + RPE per set, reusable templates.
- Setup authorized: repository, a minimal SwiftUI app, CI smoke test, unsigned IPA packaging and this saved plan.
- User approved implementing the full usable core before the first on-phone test. The physical-device milestone is deferred, not claimed complete. CI continues to verify builds, validation, storage and the full simulator workflow.
- Public repository: standard hosted macOS runner execution is free; artifact storage has separate limits. Private repositories also have included minutes, so public is a cost choice, not an absolute technical requirement.

## How

### 1. Prove building and installation before feature work

- `project.yml`: generate the Xcode project with XcodeGen rather than hand-maintaining a `.pbxproj` on Linux. Native SwiftUI; iOS 17 minimum. No third-party runtime dependencies.
- `WorkoutLog/WorkoutLogApp.swift`: clearly labelled setup screen.
- `WorkoutLogUITests/LaunchTests.swift`: launch the actual app on a simulator and assert the setup screen appears.
- `.github/workflows/ios.yml`: standard macOS runner with Xcode 16.4; find an available simulator destination by UUID, run the launch test, compile a Release device app without signing, ZIP `Payload/WorkoutLog.app` into an IPA, upload a short-lived artifact. Successful main builds publish versioned releases; PR builds never publish releases.
- Use the stable bundle ID `com.hamzabehrem.workoutlog`. No app extensions, app groups, iCloud or special entitlements, so free-account re-signing stays simple. Apple credentials are used only by SideStore, never by CI.
- Device gate: download the IPA to Files, import into SideStore, launch it on the user's phone. Only the user can confirm this physical-device/signing check.

### 2. Persist templates and workout drafts

- `WorkoutLog/Models.swift`: SwiftData `WorkoutTemplate` and `WorkoutSession` models. Use ordered Codable value arrays for exercise snapshots and logged sets; keep the initial schema small, with no third-party persistence layer.
- Template: UUID, name, ordered exercise names. Trim names, reject blank names and duplicate exercise names within one template. No global exercise catalog.
- Session: UUID, start date, optional finish date, copied template name, ordered exercise-name snapshot, fixed weight unit (`kg` or `lb`), ordered set values. Each set has UUID, exercise name, nonnegative finite weight, positive integer reps and finite RPE in the inclusive range 0–10. Whole-number RPE steps initially.
- `WorkoutLog/WorkoutLogApp.swift`: initialize the shared SwiftData container and present Templates / History navigation. Surface storage failures; never silently reset a store that cannot open.
- Keep at most one unfinished workout. Explicitly save on starting a workout, adding/editing/deleting a set, changing a template and finishing a session. A save failure must show a useful error, not a false success. Roll back and replace the editing context: simulator regression tests found that SwiftData can leave old model objects showing unsaved values after rollback. Resume an unfinished workout after app relaunch.
- Template edits or deletion must never change existing sessions: sessions keep snapshots, not live template data. Store units on each session so a new unit preference cannot relabel old weights.
- New app: no existing data to migrate. Do not wipe data on updates; later incompatible schema changes need a real migration.

### 3. Create templates and log a workout

- `WorkoutLog/TemplatesView.swift`: list/create/edit/delete templates; add, rename, reorder or remove exercises. No arbitrary exercise-count cap. Require at least one exercise to start a session. Confirm template deletion.
- `WorkoutLog/SessionView.swift`: start from a template, choose kg/lb before starting (remember the last choice), enter weight and reps, choose RPE 0–10, add sets under each exercise, correct or delete mistakes, finish the workout. Confirm destructive discard/delete actions. Prevent changing units after sets are logged; no automatic conversion in v1.
- Weight input uses locale-aware decimal parsing (including comma decimal locales); keyboard choice alone is not validation. Reject malformed, negative, NaN and infinite input. Zero weight supports bodyweight movements; reps must be positive. Show validation errors beside input.
- Persist the draft before showing it as started. Template-only changes do not affect an active session. Resume rather than silently creating a second draft.
- Use standard `NavigationStack`, `List`, forms, native move/delete controls and accessible text labels; support Dynamic Type and dark mode. No custom design system.

### 4. Review history

- `WorkoutLog/HistoryView.swift`: completed sessions newest first; show date, template snapshot, exercises and each `weight × reps @ RPE` set. Units visible, not implied.
- Exclude unfinished sessions from completed history; offer resume from the main screen. Require at least one set to finish. Confirm deletion of a completed session.
- Reuse one set-row view only if it genuinely repeats; do not add a generic repository/service abstraction.

## Tests

### Setup checks

- `LaunchTests.testSetupScreenLaunches`: app launches and clearly states it is the setup build.
- Build both simulator and physical-device targets in CI; verify ZIP integrity of the resulting IPA.
- Manual on-phone acceptance: SideStore import, launch, close, reopen; verify refresh status. Simulator success is not proof of working signing.

### Feature tests to add with the feature code

`WorkoutLogTests/ModelTests.swift` and a unit-test target in `project.yml`:

- `testSetValidation`: accepts boundary RPE 0 and 10, rejects out-of-range/nonfinite values, negative weight and nonpositive reps; zero weight valid.
- `testLocalizedWeightInput`: period and comma decimal locales, malformed input and nonfinite values.
- `testTemplateValidationAndExerciseOrder`: trimmed nonempty names, duplicate exercise rejection, order preserved.
- `testTemplateChangesDoNotRewriteSessions`: editing/deleting a template leaves draft and completed snapshots intact.
- `testPersistenceAfterReopen`: save templates, a draft and completed sets to a temporary SwiftData store, reopen and check all IDs/order/values/units.
- `testDraftLifecycle`: one draft, resume after reopen, finish requires a set, finish preserves values.
- `testUnitPreferenceDoesNotChangeOldSessions`: a later kg/lb preference affects only new sessions.

Update the UI test with a small real flow: create template → add exercises → start → log a set → relaunch/resume → finish → verify history. Manually check decimal-comma input, accessibility text sizes, airplane mode and an in-place IPA update without data loss. Do not claim tests passed until they run.

## Risks / out of scope

- SideStore free-account apps normally expire after seven days. Background refresh is not guaranteed; check expiry dates. Standard limit: three active apps including SideStore and ten App IDs per week.
- CI is the iOS compiler here: Linux cannot run Xcode or the iOS simulator. Do not promise a fixed build turnaround; simulator startup, Homebrew and runner queues vary.
- Xcode and hosted images eventually change. Xcode version is explicit; update it and re-run both build paths when the image drops that version. XcodeGen is a build-time dependency.
- Data is local only. Uninstalling the app deletes workout data. Updates must preserve app identity; there is no v1 cloud sync or backup/export UI. Do not treat real workout data as backed up. Export/import is the first follow-up before relying on it as the only long-term record.
- Out of scope: accounts, server, HealthKit, cloud sync, charts, rest timer, recommendations, exercise catalog, watch app, notes, warmup flags and App Store distribution. No volume calculation just to justify a test.

## Smallest complete version

The user approved deferring the physical install check until the core is usable. Build templates + persistent/resumable set logging + completed history, with validation and persistence tests, then provide an IPA for that first on-phone check. No unrequested fitness features.

## Acceptance checklist

- [x] Setup CI smoke test and unsigned device build pass (setup-preview).
- [ ] User installs setup IPA through existing SideStore and confirms launch.
- [x] Templates support ordered exercises and survive relaunch. (automated tests)
- [x] Weight, reps and RPE 0–10 validate and save correctly. (automated tests)
- [x] Unfinished workout survives app close/relaunch. (automated tests)
- [x] Finished history preserves values and unit after template edits. (automated tests)
- [x] Seven model/persistence tests and two UI workflow tests pass on an iPhone simulator.
- [ ] Full Release IPA build/checks complete.
- [ ] Physical-device signing, offline use, accessibility sizes and decimal keyboard verified.
- [ ] In-place IPA update preserves existing workout data.

## Reference sources

- GitHub Actions costs: https://docs.github.com/en/billing/concepts/product-billing/github-actions
- SideStore signing, refresh and limits: https://docs.sidestore.io/docs/faq
- Runner toolchains: https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md
- XcodeGen schema: https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
