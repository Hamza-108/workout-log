# Self-Hosted Leaderboard & Profile Sync API v1 (`schemaVersion: 1`)

This specification defines the platform-neutral HTTP/JSON protocol used by the **Workout Log** iOS client and any compatible Android client to sync plan-adherence streaks, 30-day relative adherence scores, personal records (PRs), and publishable workout templates with a self-hosted friend-group server.

---

## 1. Design Principles

1. **Local-First & Offline-Safe:** Clients compute all streaks, adherence scores, and PRs locally from their own database. Syncing uploads a compact summary snapshot (`SharedProfilePayload`) and downloads the group's latest snapshots (`LeaderboardResponse`).
2. **100% Platform-Neutral JSON:** Uses standard UTF-8 JSON, lowercase UUID strings (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` or uppercase RFC 4122), and UTC ISO-8601 timestamps with millisecond precision (`YYYY-MM-DDTHH:mm:ss.SSSZ`).
3. **Privacy by Default:** Raw workout history, unfinished workout drafts, unselected templates, and body-weight entries are **never** transmitted. PR sharing is opt-in (`personalRecords: []` when disabled).
4. **Bounded Payloads:** Request and response bodies must not exceed **512 KiB** (`524,288` bytes).

---

## 2. Authentication & Ownership Headers

Every request to `/api/v1/profile` and `/api/v1/leaderboard` must include:

| Header | Example | Purpose |
| :--- | :--- | :--- |
| `Authorization` | `Bearer my-secret-group-token` | Shared invite token configured on the self-hosted server for the friend group. Missing or mismatched token returns `401 Unauthorized`. |
| `X-User-ID` | `11111111-2222-4333-8444-555555555555` | Stable UUID identifying the member across syncs. |
| `X-Client-Token` | `99999999-aaaa-4bbb-8ccc-dddddddddddd` | Per-device random secret generated once by the client. On the first `PUT /api/v1/profile` for a given `X-User-ID`, the server stores `SHA-256(X-Client-Token)`. Subsequent `PUT` or `DELETE` requests for that `X-User-ID` with a different `X-Client-Token` must be rejected with `403 Forbidden`. |

---

## 3. Local Calculation Contract (iOS & Android Parity)

To ensure fair competition between iOS and Android clients:

### 3.1 Civil-Day Plan-Adherence Streak (`currentStreak`, `bestStreak`)
- Dates are evaluated as local civil days (`YYYY-MM-DD`) from the earliest scheduled rule / completion through `today`.
- **Day Status:**
  - `completed`: The day has a scheduled workout template (finished on that local day) or scheduled walking day (marked done).
  - `pending`: The day has a scheduled assignment that is not completed.
  - `unassigned`: The day has no scheduled assignment.
- **Rules:**
  1. Each `completed` day increments `runningStreak` by `1`, sets `hasCompletedInRun = true`, resets `consecutiveUnassigned = 0`, and updates `bestStreak = max(bestStreak, runningStreak)`.
  2. A past `pending` day (`day < today`) is a **missed assignment**: resets `runningStreak = 0`, `hasCompletedInRun = false`, `consecutiveUnassigned = 0`.
  3. A `pending` day on `today` (`day == today`) is **in-progress grace**: leaves `runningStreak` and `bestStreak` unchanged until completed or until tomorrow arrives.
  4. An `unassigned` day when `hasCompletedInRun == true` increments `consecutiveUnassigned` by `1`:
     - Up to **6 consecutive unassigned rest days** (`consecutiveUnassigned <= 6`) bridge the streak: if another assigned day exists within the remaining 6-day bridge window (`1...(6 - consecutiveUnassigned + 1)` days ahead), `runningStreak` increments by `1` and updates `bestStreak`.
     - If `consecutiveUnassigned > 6` (7+ unassigned days in a row with no scheduled plan), `runningStreak` expires to `0` (`hasCompletedInRun = false`).

### 3.2 30-Day Relative Plan Adherence (`adherencePercent`, `completedLast30Days`, `assignedLast30Days`)
- Evaluated over the 30 local civil days `[today - 29 days ... today]`:
  - Every `completed` day increments both `assignedLast30Days` and `completedLast30Days`.
  - Every past `pending` day (`day < today`) increments `assignedLast30Days`.
  - A `pending` day on `today` (`day == today`) is excluded from `assignedLast30Days` until completed or until tomorrow.
- `adherencePercent = assignedLast30Days > 0 ? round(completedLast30Days / assignedLast30Days * 100) : 0`.

### 3.3 Deterministic Leaderboard Ranking (`LeaderboardRanking`)
Members are ranked (1-based: `#1`, `#2`, `#3`, ...) by:
1. `currentStreak` **descending** (primary)
2. `adherencePercent` **descending** (secondary — relative 30-day plan adherence `%`)
3. `bestStreak` **descending**
4. `completedLast30Days` **descending**
5. `displayName` case-insensitive **ascending**
6. `userID` string **ascending**

---

## 4. Endpoints & JSON Schemas

### 4.1 `GET /api/v1/health`
No authentication required.

**Response (`200 OK`):**
```json
{
  "status": "ok",
  "schemaVersion": 1
}
```

### 4.2 `PUT /api/v1/profile`
Upserts the caller's profile (`userID` in body must match `X-User-ID` header) and returns the full group leaderboard.

**Request Body (`SharedProfilePayload`):**
```json
{
  "schemaVersion": 1,
  "userID": "11111111-2222-4333-8444-555555555555",
  "displayName": "Friend 3",
  "updatedAt": "2026-11-15T00:00:00.000Z",
  "currentStreak": 5,
  "bestStreak": 12,
  "adherencePercent": 100,
  "completedLast30Days": 12,
  "assignedLast30Days": 12,
  "personalRecords": [
    {
      "exercise": "Bench press",
      "weight": 105.0,
      "reps": 5,
      "rpe": 8.5,
      "unit": "kg",
      "achievedAt": "2026-11-14T18:30:00.000Z"
    }
  ],
  "publishedTemplates": [
    {
      "name": "Push day",
      "exercises": [
        {
          "name": "Bench press",
          "sets": 4,
          "videoURL": "https://www.youtube.com/watch?v=abcdefghijk&t=30"
        },
        {
          "name": "Overhead press",
          "sets": 3
        }
      ]
    }
  ]
}
```

**Validation Rules:**
- `schemaVersion` must be `1`.
- `displayName`: trimmed, non-empty, `1...40` characters.
- `updatedAt` and `achievedAt`: UTC ISO-8601 with fractional seconds (`YYYY-MM-DDTHH:mm:ss.SSSZ`).
- `currentStreak >= 0`, `bestStreak >= currentStreak`.
- `0 <= adherencePercent <= 100`, `completedLast30Days >= 0`, `assignedLast30Days >= completedLast30Days`.
- `personalRecords`: unique case-insensitive `exercise` names; finite `weight >= 0`; `reps > 0`; `0 <= rpe <= 10`; `unit` in `["kg", "lb"]`.
- `publishedTemplates`: compatible with Workout Log's `TemplatePack` format (`sets` in `1...99`, unique case-insensitive exercise names per template, optional `videoURL` normalized to `https://www.youtube.com/watch?v=<11-char-id>[&t=<seconds>]`).

**Response (`200 OK` — `LeaderboardResponse`):**
```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-15T00:00:01.120Z",
  "members": [
    {
      "schemaVersion": 1,
      "userID": "11111111-2222-4333-8444-555555555555",
      "displayName": "Friend 3",
      "updatedAt": "2026-11-15T00:00:00.000Z",
      "currentStreak": 5,
      "bestStreak": 12,
      "adherencePercent": 100,
      "completedLast30Days": 12,
      "assignedLast30Days": 12,
      "personalRecords": [],
      "publishedTemplates": []
    }
  ]
}
```

### 4.3 `GET /api/v1/leaderboard`
Returns the latest `LeaderboardResponse` for all members in the group.

### 4.4 `DELETE /api/v1/profile`
Removes the caller's profile (`X-User-ID` + matching `X-Client-Token`). Returns `200 OK` or `204 No Content`.

---

## 5. HTTP Status Codes

| Status | Meaning |
| :--- | :--- |
| `200 OK` | Request succeeded; response body is valid JSON. |
| `204 No Content` | Profile deleted. |
| `401 Unauthorized` | Missing or invalid `Authorization: Bearer <groupToken>`. |
| `403 Forbidden` | `X-Client-Token` does not match the token registered for `X-User-ID`. |
| `413 Payload Too Large` | Request body exceeds 512 KiB. |
| `422 Unprocessable Entity` | Payload failed schema or field validation. |

---

## 6. Example `curl` Verification

```bash
# Push a profile update
curl -X PUT "https://gym.example.com/api/v1/profile" \
  -H "Authorization: Bearer my-secret-group-token" \
  -H "X-User-ID: 11111111-2222-4333-8444-555555555555" \
  -H "X-Client-Token: 99999999-aaaa-4bbb-8ccc-dddddddddddd" \
  -H "Content-Type: application/json" \
  -d '{
    "schemaVersion": 1,
    "userID": "11111111-2222-4333-8444-555555555555",
    "displayName": "Friend 3",
    "updatedAt": "2026-11-15T00:00:00.000Z",
    "currentStreak": 5,
    "bestStreak": 5,
    "adherencePercent": 100,
    "completedLast30Days": 4,
    "assignedLast30Days": 4,
    "personalRecords": [],
    "publishedTemplates": []
  }'

# Fetch the group leaderboard
curl -X GET "https://gym.example.com/api/v1/leaderboard" \
  -H "Authorization: Bearer my-secret-group-token" \
  -H "X-User-ID: 11111111-2222-4333-8444-555555555555" \
  -H "X-Client-Token: 99999999-aaaa-4bbb-8ccc-dddddddddddd"
```
