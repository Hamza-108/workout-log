# workout-log
A simple offline iPhone workout log, built on GitHub Actions for SideStore sideloading (Vibecoded using 6.1-sol)

## Install / update

Download `WorkoutLog-unsigned.ipa` from a tested [release](https://github.com/Hamza-108/workout-log/releases), then install it through SideStore. Refresh before the free-account signing expiry (normally seven days).

**Update over the existing app with the same Apple Account and app identity. Do not uninstall: that deletes local workouts.** Keep separate workout records until the on-phone checks below pass.

The 0.3 preview adds a Live Activity extension. Preserve app extensions when SideStore signs the IPA; the extension may consume another App ID under free-account limits. Signing/install acceptance on a real phone is still unverified. No paid membership, signing credentials in GitHub, server or App Group is required by the code.

## Logging

- Make a template with ordered exercises and a set count per exercise (default 3, range 1–99). Choose kg/lb before starting; each workout keeps its original unit, exercise and planned-set snapshot.
- Planned sets appear as **Not logged** rows. Tap any row to log it; add extra sets or swipe to remove planned/logged sets. These changes affect only this workout, not the template. Empty rows never count as logged sets or appear as performed sets in History.
- Existing templates and unfinished workouts keep their old behavior until you explicitly edit a template. Editing it does not change an already-started workout.
- Log weight, positive whole-number reps and exertion/RPE 0–10. Zero weight is allowed. Tap a saved set to edit it; swipe to delete with confirmation.
- **Close** leaves the workout unfinished and resumable. Saved sets persist; text still in an unsaved editor does not.
- **Finish** asks for confirmation before moving a workout to History. Cancel keeps logging.
- Delete a finished workout from its detail screen, or swipe it in History. Confirmation names the workout/date. Templates and other workouts stay intact.

## Calendar plans and walking

The **Calendar** tab assigns one saved template or **Walking** to a date. Tap a date, then Assign to choose **This date only** or a weekly repeat from that date onward. An exact-date override wins over the weekly rule. Clear a single date without cancelling its weekly pattern; weekly edits apply from the selected date onward and keep earlier plans. Future exact-date overrides remain in place.

- **Blue / completed:** the assigned template has a finished workout on that day, or Walking was marked done.
- **Red / pending:** assigned but not completed. Future red days say **Scheduled**, not missed.
- **Neutral:** unassigned. Icons and accessible status labels accompany colours.

Tap the assigned template's **Start workout** to use the existing logger and video shortcuts. If any workout is unfinished, **Resume** it instead; a second draft is never created. Workouts started from Templates also count when their stable template ID matches the date's assignment. Finishing counts on the actual local completion day, not the date you happened to select. Walking uses **Mark walk done** / **Undo completion** for today or earlier, with no sets or tracking permissions.

Renaming a template does not break matching. Deleting a template keeps its history and assignment; missing templates show as unavailable until reassigned. Deleting a matching finished workout recalculates the day's colour. Existing older workouts have no source-template ID; the calendar does not guess matches by name. Date keys and recorded completion days remain stable across timezone changes; day/month navigation uses calendar arithmetic for DST and leap days.

Full backups include calendar rules and walking completions. Template-only JSON does not include schedules, and template names such as Monday do not create calendar events automatically. There is no system Calendar sync, reminder, GPS or step tracking.

## Exercise library and video shortcuts

Templates → **More (…) → Exercise library** manages reusable exercises with a name and optional YouTube video link. In a template, **Add exercises** opens a searchable multi-select picker; **Create new exercise** works without leaving it. Selected exercises include their videos, start with 3 sets and can be reordered or given different counts per template.

Templates and workouts keep independent copies. Renaming/deleting a library entry does not change saved templates or workouts; changing a template does not alter an already-started workout. Existing template exercise names populate the library once on upgrade. Deleting a library entry does not make it reappear on the next launch. **Exercise library → More (…) → Clear library** removes all library entries after a count/backup warning and confirmation. Templates, saved workouts, the current session and calendar are unchanged. Clearing cannot be undone without a backup; the library stays empty after restart.

An optional **Add video** field accepts HTTPS YouTube watch, short, Shorts or embed links. Links are normalized to a standard video address, preserving start timestamps while dropping tracking and playlist parameters. A small accessible play icon appears beside a linked exercise while logging. Tapping opens YouTube or the browser; the app does not fetch thumbnails, embed, autoplay or download video. Watching needs internet; logging remains offline. Start times such as `?t=90`, `?t=90s`, `?t=1m30s`, `?start=90` and `#t=1m30s` are stored as `&t=90`. Invalid or conflicting times are rejected instead of silently discarded.

**Timestamp repair:** 0.5.0 stripped timestamps when saving links. Updating cannot recover them: re-add the original timestamped URL to the exercise in each affected template (and the library for future selections). Existing workouts retain their earlier snapshots. Older builds may reject backups containing timestamped links.

## Import / export templates or a whole plan

Templates → **More (…) → Import template** accepts a JSON file **or typed/pasted plain text**. The screen shows both formats, field explanations and copyable examples. Single-template imports open the existing editor; whole-plan imports show all days before **Import all**. If an exercise has a different video from the library or another template in the file, a comparison shows both full links (including timestamps) or **No video**, and the affected templates. Invalid input/save errors show an alert and visible status; pasted input is preserved. Cancel changes nothing. All template additions and library changes save together.

```json
{
  "name": "Push day",
  "exercises": [
    {"name": "Bench press", "sets": 3},
    {"name": "Overhead press", "sets": 2}
  ]
}
```

Whole-plan format (replace the placeholder video ID with yours, or omit `videoURL`):

```json
{
  "templates": [
    {
      "name": "Monday",
      "exercises": [
        {"name": "Bench press", "sets": 3, "videoURL": "https://www.youtube.com/watch?v=XXXXXXXXXXX"}
      ]
    },
    {
      "name": "Tuesday",
      "exercises": [{"name": "Row", "sets": 3}]
    }
  ]
}
```

`name` is the template name; `exercises` is ordered. Each exercise needs a non-empty `name`, an integer `sets` from 1 to 99 and optionally `videoURL`. The old `"exercises":["Bench press","Overhead press"]` format still works with 3 sets each. Both text and files have a 25 MiB UTF-8 limit. Empty names, duplicate exercises within a template and invalid links are rejected before saving. Different valid video definitions are reviewed, not treated as malformed JSON.

Imports create new templates; they never overwrite existing ones. The batch preview warns about repeated template names: importing again can create copies. Matching exercise-library definitions are reused; omitting a video keeps that template unlinked without clearing the library video. For each different video definition, choose:

- **Reject incoming change:** use the saved definition in the new templates; keep the library unchanged.
- **Override:** use the incoming definition and update that library entry for future selections. Existing templates and workouts retain their snapshots.
- **Keep both:** keep the original and add the incoming definition as, for example, `Back Squat (variation 1)`. A unique name is chosen without case-insensitive collisions; affected imported templates use it. Actual names appear in the preview before saving.

Every conflict needs an explicit choice. Only one variant can override a given entry; choosing another Override makes the earlier choice unresolved again. Omitting a video remains an omission, not a request to erase a saved link. If the library changes after comparison, Import refuses the stale review: use **Refresh comparisons** and choose again. **Cancel import** rejects the entire import without writes. Monday/Tuesday are names, not scheduled calendar events.

**More (…) → Export templates** selects some/all templates, then **Save JSON file** or **Copy JSON**. Exports contain names, exercise order, counts and videos—not history, database IDs or app-identifying metadata. Legacy name-only templates export with 3 sets per exercise. Exports preserve template-specific video variants; disagreeing definitions appear in the import comparison. For an exact data-preserving copy including legacy metadata, use a full backup instead.

## Backups

Templates → **More (…) → Data and backups** → **Export backup** or **Import backup**. Choose a private Files destination: backups contain your workout history as **unencrypted plain-text JSON**. Files/iCloud-provider behavior still needs an on-phone check.

Import shows new/skipped counts and asks for confirmation. It adds missing records in one save:

- Same record kind + UUID + identical contents: skip.
- Same UUID with different contents: reject the entire import. No automatic overwrite or destructive restore mode.
- A different unfinished workout already exists: reject; finish/discard it before retrying.
- An empty store restores the backup's new-workout unit preference. A populated store keeps its current preference. Historical weights are never relabeled.

Export your current data before resolving conflicting copies. Keep the original backup file. Imports do not include unsaved editor text, and importing an old backup can bring back records you deleted since exporting it.

### Backup format (version 4)

```json
{"schemaVersion":4,"preferredWeightUnit":"kg","templates":[],"sessions":[]}
```

The app still imports version 1, 2 and 3 backups. Version 1 does not invent planned sets. New exports use version 4; older app versions cannot read them. Full backups include unused library exercises as well as template/session video snapshots. Restoring older backups also makes their template exercises available in the library. Identical library definitions with different IDs are reused by name during a merge; conflicting videos stop the import. Updating adds calendar tables and optional source-template/completion-day metadata without rewriting existing logged sets. Upgrade/reopen regression tests check both previous stored-field layouts.

- Optional `calendarRules`: IDs, exact/weekly scope, local `startDay`/exclusive `endDay`, kind and template ID/name snapshot. Rules with overlapping weekly intervals or duplicate exact dates are rejected, including during merges.
- Optional `walkingCompletions`: stable IDs and local `day` keys; duplicate days/conflicts abort the whole import.
- Optional `libraryExercises`: records with `id`, `name` and optional `videoURL`. Library IDs and case-insensitive names must be unique. The store-local setup marker is not exported.
- Template fields: `id` (UUID), `name`, ordered `exercises`, optional `setCounts` (one count per exercise, in the same order), optional `videoURLs` mapping exact exercise names to canonical YouTube links.
- Session fields: `id`, `startedAt`, optional/null `finishedAt`, `templateName`, ordered `exercises`, `unit` (`kg`/`lb`), ordered logged `sets`, optional ordered `plannedSets` (`id`, `exercise`). Optional `videoURLs` preserves this workout's own links. Optional `sourceTemplateID` and `completedDay` preserve calendar matching; older records stay unlinked. A logged set uses its planned row's UUID, so logging a later row first does not move it to a different slot.
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
