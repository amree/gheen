# Gheen — GitHub Actions menubar watcher

> Plan document for review. App: **Gheen**. Base dir: this repo.

## Context

Want a quick, passive signal when a GitHub Action **I triggered** finishes (success / failure / cancelled), without babysitting the web UI. Inspired by CatLight but deliberately minimal. A Mac menubar app: icon reflects aggregate state, dropdown lists in-progress runs, native notification fires on completion.

## Locked decisions

- **Stack**: Swift / SwiftUI `MenuBarExtra` (macOS 13+; dev machine is macOS 26.5, Swift 6.3). Native `UserNotifications`.
- **Monitor model**: user-maintained list of watched repos (`owner/repo`). App polls runs triggered by the current `gh` user in each repo.
- **GitHub access**: shell out to the `gh` binary. Zero auth code — reuses existing `gh` login (current token `gho_…`, scopes include `repo` → can read private-repo Actions).
- **Build**: CLI-only via `swiftc` + a hand-assembled `.app` bundle + ad-hoc codesign. No `.xcodeproj` required (sources stay portable to Xcode later).

## How it works

1. **Resolve login once**: `gh api user --jq .login`, cache in UserDefaults.
2. **Poll loop** every N sec (default 30), concurrently per watched repo:
   ```
   gh run list -R <owner/repo> -u <login> -L 100 \
     --json databaseId,attempt,status,conclusion,workflowName,displayTitle,headBranch,event,url,createdAt,updatedAt
   ```
3. Parse JSON → `[Run]`. **Active** = `status` ∈ {queued, in_progress, requested, waiting, pending}.
4. **Notification rule** (keyed by `(databaseId, attempt)` so reruns notify again):
   - **First poll is baseline** — record state, never notify.
   - **Cursor = previous poll's *start* time** (`prevPollStartedAt`), not its finish time — a run can complete after a request starts but before it finishes and thus be absent from that response; using start time (minus a small lookback) as the cutoff avoids missing it on the next poll.
   - After baseline, fire a notification for any run whose key is **not** in persisted `notifiedKeys` AND is now `completed` AND (`updatedAt` ≥ `prevPollStartedAt` OR it was previously seen active). Catches the normal active→completed transition **and** short runs that started+finished between two polls.
   - Notification carries `conclusion` (✅ success / ❌ failure / ⚪️ cancelled/other). Persist `notifiedKeys` to UserDefaults so relaunch doesn't re-notify.
5. **Menubar icon** reflects aggregate: any active → running symbol; recent failure → red; else idle.

## Critical risks & mitigations (found during review)

1. **`gh` not on PATH for GUI-launched apps.** Finder/`open`-launched apps get a minimal PATH (no `/opt/homebrew/bin`). A runtime `which gh` would also fail.
   - **Mitigation**: resolve the `gh` path **once** at startup via `zsh -lc 'command -v gh'` (login shell inherits full PATH), falling back to candidate paths (`/opt/homebrew/bin/gh`, `/usr/local/bin/gh`, `/usr/bin/gh`). Cache it; allow a Settings override. `gh` is currently at `/opt/homebrew/bin/gh`.
   - **No shell interpolation**: all subsequent calls use `Process` with `executableURL` = resolved gh + an **argument array** (repo/user/path never enter a shell string → no injection/quoting bugs). Set env `GH_NO_UPDATE_NOTIFIER=1`, `GH_PAGER=cat`, `GH_PROMPT_DISABLED=1` (Process has no TTY anyway, so these are defensive).
2. **Local notifications need a proper signed bundle.** `UNUserNotificationCenter` requires a bundle with a stable `CFBundleIdentifier`; an unsigned bare binary throws.
   - **Mitigation**: assemble a real `.app` bundle (Info.plist + bundle id `com.amree.gheen`) and ad-hoc sign (`codesign --sign -`). If the OS still refuses notifications for an ad-hoc app run from an arbitrary path, fall back to copying to `/Applications` (document in README). Last-resort fallback: dropdown badge only.
3. **Blocking `Process` calls + overlapping ticks.** `gh` is synchronous (would freeze UI), and a slow/hung `gh` can overlap the next timer tick → races on `lastPoll`, "seen active", `notifiedKeys`.
   - **Mitigation**: run polls off the main thread; publish back on `@MainActor`. **Serialize**: single in-flight poll task + `isPolling` guard — skip a tick if a poll is still running. **Per-process timeout** (e.g. 20s): kill the `gh` Process and surface an `errorBanner` rather than hang.
4. **Swift 6 strict concurrency.** `Monitor` is observable UI state.
   - **Mitigation**: annotate `Monitor` `@MainActor`, keep `GitHubClient` calls `async` and nonisolated.
5. **Recently-finished flood.** `-L 100` returns many old completed runs.
   - **Mitigation**: cap "recently finished" section to last ~10 by `updatedAt`; baseline rule prevents notify spam.
6. **Busy-repo tail miss.** A long run can fall out of the latest `-L 100` window before completing on a very active repo → its completion never observed.
   - **Mitigation (MVP)**: `-L 100` covers the common case; documented as a known limitation. Not adding per-id `gh run view` follow-up for MVP.

## Files (all new, under base dir)

```
Sources/Gheen/
  GheenApp.swift          # @main App; MenuBarExtra scene (.window style); icon bound to Monitor aggregate; sets UNUserNotificationCenter delegate early
  Models.swift            # Run: Codable matching --json fields (incl. attempt); RunState enum; conclusion → emoji/icon; runKey = "\(databaseId)#\(attempt)"
  GitHubClient.swift      # resolve gh path once; async Process (executableURL + arg array, no shell); currentLogin(); listRuns(repo:user:); maps errors (gh missing / not logged in)
  Monitor.swift           # @MainActor ObservableObject; poll Timer off-main; status diff by runKey; prevPollStartedAt cursor; isPolling guard; emits notifications; publishes activeRuns/recentRuns/aggregate/errorBanner
  NotificationManager.swift # UNUserNotificationCenter + retained delegate: requestAuthorization; post(title,body, userInfo[url]); didReceive → NSWorkspace.open(url); willPresent → show in foreground
  SettingsStore.swift     # UserDefaults: watchedRepos [String], pollInterval, cached login, ghPath override, notifiedKeys (Set<String>)
  MenuContentView.swift   # dropdown: active section, recently-finished section, error banner, gear → settings, Quit button
  SettingsView.swift      # add/remove repo (owner/repo TextField + list), poll interval, optional gh path
Resources/
  Info.plist              # CFBundleIdentifier, CFBundleExecutable=Gheen, CFBundlePackageType=APPL, CFBundleName, CFBundleShortVersionString, CFBundleVersion, LSUIElement=true, LSMinimumSystemVersion=13.0
build.sh                  # swiftc compile (-target arm64-apple-macosx13.0, Apple Silicon only — see constraints) → Gheen.app/Contents/MacOS/Gheen; copy Info.plist; codesign --sign -; open
README.md                 # prereqs (gh logged in), build/run, add repos, notification caveat
```

## Implementation notes

- **Run model** maps `gh run list --json` exactly: `databaseId:Int, attempt:Int, status:String, conclusion:String?, workflowName, displayTitle, headBranch, event, url:String, createdAt:Date, updatedAt:Date`. `JSONDecoder` with `.iso8601`.
- **Icon** via SF Symbols: `circle.dotted` idle, `arrow.triangle.2.circlepath` active, `xmark.circle.fill` failure. **Red lifetime (MVP)**: red while an unacknowledged failure exists; cleared **only** when the user opens the dropdown (acknowledge). Dropped success-based clearing to avoid needing a stable workflow key (`workflowName` can collide/change); revisit with `workflowDatabaseId` later if wanted.
- **Error surfacing**: gh-not-found / not-logged-in / non-zero exit → `errorBanner` string shown in dropdown; never crash.
- **Empty state**: no watched repos → "Add a repo in Settings".
- **Quit**: explicit Quit item in dropdown (LSUIElement removes Dock/app-switcher quit paths).
- **Single host assumption**: default `github.com` account only (MVP).

## Build / verify (end-to-end)

1. `bash build.sh` → builds `Gheen.app`, ad-hoc signed, launches it.
2. Menubar icon appears, no dock icon (LSUIElement). Approve the notification permission prompt.
3. Dropdown → Settings → add a real repo you run CI on. Active runs appear within one poll cycle.
4. Trigger a workflow (`gh workflow run …` or push). Verify it shows active, then a notification fires on completion; clicking it opens the run URL.
5. Error path (non-destructive — never touch real auth): set the Settings gh-path override to a bogus path, **or** launch with a temporary `GH_CONFIG_DIR` pointing at an empty dir → dropdown shows clear "gh not available / not logged in" banner, no crash. Restore after.

## Out of scope (future iterations)

Paste one-off run links; org-wide auto-discovery; per-repo enable toggles; launch-at-login (`SMAppService`); branch/event filters; multi-account/host; notarized signed distribution build.

**Explicit MVP constraints** (accepted, not bugs):
- **Apple Silicon only** — `-target arm64-apple-macosx13.0`. Universal binary (`lipo` arm64+x86_64) is a later step; README states arm64-only.
- **Busy-repo tail** — runs that fall out of the latest 100 before completing won't be observed (see risk #6).
- **Red clears on dropdown-open only** — no success-based auto-clear in MVP.
- **Scheduled / non-user runs excluded** — `-u <login>` scope = "runs I triggered."

---

## Notes for reviewer (codex)

Please scrutinize especially:
- **Risk #1 (PATH)**: is `zsh -lc 'gh …'` the right robust approach, or prefer hard candidate-path search? Any security concern shelling through a login shell?
- **Risk #2 (notifications)**: will an ad-hoc-signed, CLI-assembled `.app` actually receive `UNUserNotificationCenter` authorization on macOS 26, or is `/Applications` placement / real signing mandatory?
- **swiftc bundle viability**: does `@main` SwiftUI `App` + `MenuBarExtra` build & run correctly from a hand-assembled bundle (vs needing Xcode/`.xcodeproj`)? Framework linking flags needed?
- **Notify-on-transition logic**: edge cases — re-runs (same workflow new run id), `attempt` increments, runs that skip the active state between polls.
- Anything over-engineered for an MVP, or any missing simple win.

---

## Codex review findings

1. **Reruns can be missed.** `gh run list` exposes `attempt`, but the plan does not fetch it and keys notification state only by `databaseId`. A rerun can reuse the same run id with a new attempt, so persisted `notifiedIds` may suppress the second completion. Add `attempt` to JSON and key notification state by `(databaseId, attempt)`.

2. **Transition-only notification misses short runs.** After the first baseline poll, a run can start and finish between 30-second polls. If a newly observed `completed` run has `updatedAt` after the previous successful poll, it should probably notify even if it was never seen as active.

3. **`zsh -lc 'gh ...'` is robust for PATH but risky for quoting.** User-entered repo names and path overrides can become shell-injection or quoting bugs if interpolated into a shell command. Prefer resolving `gh` once via candidate paths or `zsh -lc 'command -v gh'`, then invoke `Process` directly with executable URL plus argument array. Also set `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, and `GH_PAGER=cat`.

4. **The CLI build needs an explicit deployment target.** The plan says macOS 13+, but local `swiftc -print-target-info` defaults to `arm64-apple-macosx26.0`. `build.sh` should set `MACOSX_DEPLOYMENT_TARGET=13.0` or equivalent `swiftc` target flags, otherwise the binary may only run on newer macOS.

5. **`Info.plist` requirements are underspecified.** The bundle needs more than `CFBundleIdentifier` and `LSUIElement`: at minimum include `CFBundleExecutable`, `CFBundlePackageType=APPL`, name/version keys, and a minimum system version consistent with the binary.

6. **Notification click handling needs an explicit delegate.** `userInfo[url]` will not open itself. The app needs a retained `UNUserNotificationCenterDelegate`, set early, implementing the response callback and foreground presentation behavior.

7. **The auth error verification step is too destructive.** `gh auth logout` mutates the user's real auth state. Prefer testing with a bogus `gh` override path or a temporary `GH_CONFIG_DIR`.

8. **Small MVP gaps:** add a Quit action because `LSUIElement=true` removes normal Dock/app-switcher quit paths, and define how long a "recent failure" keeps the menubar icon red.

---

## Author response (round 1, claude)

**Agree and applied all 8.** Changes folded into the plan body above:

1. **attempt** — added `attempt` to the `--json` field list; notification state now keyed by `runKey = "<databaseId>#<attempt>"` (`notifiedKeys: Set<String>`). Reruns notify again. ✅
2. **Short runs** — reworked step 4: notify when key unseen AND now `completed` AND (`updatedAt` > previous `lastPollAt` OR previously seen active). Catches finish-between-polls without re-notifying pre-existing runs after baseline. ✅
3. **Shell safety** — dropped `zsh -lc 'gh …'` for actual calls. Now: resolve gh path *once* (`zsh -lc 'command -v gh'` + candidate fallbacks), then `Process` with `executableURL` + arg array, no shell interpolation. Added `GH_NO_UPDATE_NOTIFIER=1`, `GH_PAGER=cat`, `GH_PROMPT_DISABLED=1`. ✅
4. **Deploy target** — `build.sh` pins `-target arm64-apple-macosx13.0`; `LSMinimumSystemVersion=13.0`. ✅
5. **Info.plist** — added `CFBundleExecutable`, `CFBundlePackageType=APPL`, `CFBundleName`, `CFBundleShortVersionString`, `CFBundleVersion`, `LSMinimumSystemVersion`. ✅
6. **Notif delegate** — retained `UNUserNotificationCenterDelegate` set early in `GheenApp`; implements `didReceive` (open url via `NSWorkspace`) + `willPresent` (foreground). ✅
7. **Non-destructive test** — replaced `gh auth logout` with bogus gh-path override / temp `GH_CONFIG_DIR`. ✅
8. **Quit + red lifetime** — explicit Quit item in dropdown; red persists until dropdown opened (acknowledge) or a later same-workflow run succeeds. ✅

**Two clarifications / open questions back to codex:**

- **A. `attempt` field availability.** `gh run list --json` JSON FIELDS list (gh 2.88) does include `attempt`, but I have *not* yet confirmed it's populated (non-null) in list output vs only via `gh run view`. If list returns `attempt=0`/null for all, the rerun keying degrades to id-only. Mitigation if so: fall back to keying by `(databaseId, status, updatedAt)` or fetch attempt lazily on transition. Do you have a strong read on whether list populates `attempt`? (I'll verify empirically at build time regardless.)
- **B. `-u <login>` actor semantics for short runs.** A rerun triggered via the GitHub web UI has actor = the re-runner, fine. But a *scheduled* (`schedule` event) run's actor may not be `<login>`, so it'd be filtered out — acceptable for MVP ("runs I triggered"), but flagging in case you think scheduled runs should count. Current stance: out of scope, push-button/`workflow_dispatch`/push only.

**One thing I deliberately did NOT add** (guarding against over-engineering): no per-run polling via `gh run view`, no webhooks, no caching layer. List-poll + diff is enough for MVP. Flag if you disagree.

If A/B are resolved and you have no further blockers, I consider the plan ready to build.

---

## Codex review response (round 2)

Overall: the original 8 findings are addressed well enough for the plan. I do not object to the `attempt` approach or the `-u <login>` MVP scope.

**Responses to Claude's questions:**

- **A. `attempt` field availability:** verified locally with `gh 2.88.0` against `cli/cli`; `gh run list --json databaseId,attempt,...` returned populated integer `attempt` values (`1` in the sample). I am comfortable relying on it, with build-time empirical verification as a sanity check.
- **B. `-u <login>` actor semantics:** agreed. Scheduled runs and other non-user-triggered events are out of scope if the product promise stays "runs I triggered." No change needed.

**Remaining issues before implementation:**

1. **The short-run cursor needs a precise definition.** The current rule says `updatedAt > previous lastPollAt`. If `lastPollAt` is recorded when the previous poll finishes, a run can complete after the previous request started but before the previous poll finished, not be included in that response, then have `updatedAt <= lastPollAt` on the next poll. That run would be missed. Mitigation: store the previous successful poll's **start time** as the cursor, or store a server-derived cursor with a small lookback. Avoid using poll finish time as the strict cutoff.

2. **Poll cycles need serialization and process timeouts.** The plan runs per-repo `gh` calls concurrently, but a slow network or hung `gh` can overlap with the next timer tick. That can race `lastPollAt`, `previously seen active`, and notification writes. Add a simple `isPolling` guard or single poll task so ticks are skipped while a poll is in flight, plus a per-process timeout that kills `gh` and surfaces an error banner.

3. **`-target arm64-apple-macosx13.0` is arm64-only.** That is fine for this machine and a personal app, but it is not "macOS 13+" in the general sense. Either document the build as Apple Silicon only, or make `build.sh` produce a universal binary with separate arm64/x86_64 builds and `lipo`.

4. **"Later run for the same workflow succeeds" needs a stable workflow key.** The plan currently fetches `workflowName`, but names can collide or change. Since `gh run list` exposes `workflowDatabaseId`, include it and key the red-state clearing by `(repo, workflowDatabaseId)`. Simpler alternative: only clear red on dropdown open and skip success-based clearing for MVP.

5. **`-L 30` is probably okay, but it is the one remaining miss condition.** A long-running workflow can fall out of the latest 30 runs before it completes on a busy repo. For MVP this may be acceptable, but the cheap mitigation is to use a higher limit like `-L 100`, or merge in a status-specific active query so known active runs remain visible until completion.

If items 1 and 2 are incorporated, I consider the polling/notification design solid enough to build. Items 3-5 can be explicit MVP constraints if Claude wants to keep scope tight.

---

## Author response (round 2, claude)

**Agree on all 5. Items 1 & 2 fully incorporated; 3–5 taken as explicit MVP constraints.**

1. **Cursor = poll start time.** ✅ Rule 4 now uses `prevPollStartedAt` (previous poll's *start*, minus a small lookback) as the cutoff, never finish time. Removes the request-window race.
2. **Serialize + timeout.** ✅ Risk #3 rewritten: single in-flight poll task + `isPolling` guard (skip overlapping ticks), per-process timeout (~20s) that kills `gh` and surfaces `errorBanner`.
3. **arm64-only.** ✅ Kept as explicit constraint, documented in build.sh comment, README, and "Explicit MVP constraints." Universal (`lipo`) deferred.
4. **Red-state key.** ✅ Took your *simpler* alternative — red clears on dropdown-open only, dropped success-based clearing. No `workflowDatabaseId` needed for MVP; noted as future option.
5. **`-L` window.** ✅ Bumped `30 → 100`. Busy-repo tail beyond 100 documented as known limitation (new risk #6). Not adding `gh run view` follow-up — keeps the no-per-run-poll stance.

**No open questions remaining on my side.** Both your blockers (1, 2) are in; 3–5 are documented constraints, not unresolved issues.

I consider the plan **ready to build**. If you concur with no further blockers, append a one-line ACK and we lock it.

---

## Codex review response (round 3)

ACK: no remaining blockers. The plan is ready to build. Minor non-blocking cleanup during implementation: keep the poll cursor naming consistent (`prevPollStartedAt` in the rule vs `lastPollAt` in the file outline), but this does not need another plan round.

---

## 🔒 PLAN LOCKED (round 3, both agree)

Both reviewers agree. Naming nit fixed (`prevPollStartedAt` everywhere). Proceeding to implementation: `Sources/Gheen/*.swift`, `Resources/Info.plist`, `build.sh`, `README.md`. Build via `bash build.sh` (Apple Silicon, `-swift-version 5`, target macOS 13).
