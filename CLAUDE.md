# Gheen — Claude Code context

## What this is
macOS menubar app (Apple Silicon, macOS 13+). Polls GitHub Actions runs triggered by the current `gh` user across watched repos. Notifies on completion. No auth code — delegates entirely to the `gh` CLI.

## Build
```sh
make run      # build + launch
make build    # build only
make install  # build + copy to /Applications
bash build.sh # legacy single-script alternative (builds + launches)
```
Produces `Gheen.app/` (excluded from git), ad-hoc signed. Requires `swiftc` + `codesign` (Xcode CLI tools) and `gh` authenticated.

## Language / stack
- Swift 5 language mode (`-swift-version 5`), `-target arm64-apple-macosx13.0`
- SwiftUI `MenuBarExtra` (`.window` style), `UserNotifications`, `AppKit`
- No `.xcodeproj` — single `swiftc` invocation in `build.sh` / `Makefile`. `Package.swift` exists for SourceKit/IDE type resolution only (not used to build)
- Framework flags: `-framework SwiftUI -framework AppKit -framework UserNotifications`

## File layout
```
Sources/Gheen/
  GheenApp.swift          @main App, MenuBarExtra, boots Monitor + NotificationManager
  Models.swift            Run: Codable, runKey = "databaseId#attempt", eventLabel, isPR, repoName, timeAgo
  GitHubClient.swift      actor; resolves gh path once; Process arg-array (no shell)
  Monitor.swift           @MainActor ObservableObject; poll loop, diff, notification emit, exponential backoff
  NotificationManager.swift  UNUserNotificationCenter delegate; click → NSWorkspace.open
  SettingsStore.swift     UserDefaults: repos, interval, ghPath, notifiedKeys
  CommandLog.swift        rolling ~/Library/Logs/Gheen/commands.log (last 100); serial-queue writer shared by GitHubClient + Monitor
  MenuContentView.swift   dropdown UI (filter tabs, active / recent / error / settings / quit)
  SettingsView.swift      add/remove repos, interval picker, gh path override
Resources/
  Info.plist              CFBundleIdentifier=com.amree.gheen, LSUIElement=true
Makefile                  build / run / clean / install targets
```

## Key constraints (MVP, intentional)
- Apple Silicon only — no universal binary yet
- `-u <login>` scope: only runs the authenticated user triggered (no scheduled runs)
- `-L 100`: runs beyond the latest 100 on a very busy repo may be missed
- Red menubar icon clears on dropdown-open only (no success-based auto-clear)
- Single `github.com` account

## Key design decisions
- `gh` path resolved once at startup via `zsh -lc 'command -v gh'` + candidate fallbacks; cached; user-overridable in Settings
- Notification keyed by `databaseId#attempt` so reruns fire a new notification
- Poll cursor = previous poll **start time** (not finish time) — prevents missing short runs that complete mid-request
- **Subprocess safety** (`GitHubClient.runProcess`): all `gh`/shell calls go through one helper that reads stdout/stderr via non-blocking `readabilityHandler`s (never blocks a thread on a pipe — a `gh` child inheriting stdout used to wedge `readDataToEndOfFile` forever), completes on stdout EOF or a hard timeout, SIGKILLs on timeout, and reaps on a detached task. Used by both `run()` and the login-shell path probe (both bounded)
- `isPolling` guard skips overlapping timer ticks. **Poll watchdog**: if an in-flight poll runs > `maxPollDuration` (60s) it's abandoned (generation-guarded so a resumed stale poll can't fire notifications) and a fresh poll starts — last-resort backstop so no hang can permanently wedge polling
- First poll = baseline: already-finished runs recorded to `notifiedKeys`, never notified
- **Exponential backoff**: idle polls (no active runs) double the interval each cycle, capped at 2 min (`maxBackoffInterval`). Cap kept low so a newly-started run is detected promptly — GitHub's 5000/hr limit makes idle API savings negligible. Resets on dropdown open, active run detected, or Settings save
- **Event-aware rows**: PR runs show branch name (bold) + repo · workflow; non-PR runs show run display title (bold) + repo · branch · workflow. Right-aligned `timeAgo` on every row. Hover tooltip shows PR title
- **Static filter tabs**: fixed All / PR / Push / Manual segmented control, always shown; filters run list by `eventLabel`
- **Notifications**: title = conclusion emoji + run display title; body = repo · branch · workflow
- **Leaked-event filter**: GitHub's `-u <login>` actor filter leaks runs the user didn't trigger — Dependabot version updates (event `dynamic`, actor `dependabot[bot]`) and scheduled cron runs (event `schedule`, actor = schedule owner). `listRuns` drops `event ∈ {dynamic, schedule}` so the list stays "runs I triggered". Blocklist (not allowlist) — never hides a genuinely user-triggered run
- **Command log**: `CommandLog` writes to `~/Library/Logs/Gheen/commands.log` (last 100, serial queue), opened from Settings. Records every `gh` call (with duration + exit status, and the stderr reason folded in on failure or `timeout`), plus no-gh-call events: `monitor started`, idle backoff, no repos, skipped tick, `poll watchdog — abandoning stuck poll`, and `error:` lines. Gap between timestamps = real stall
- Menubar icons: `circle` idle, `circle.dotted` active, `circle.fill` red on unacked failure

## What NOT to do
- Don't add per-run `gh run view` polling — list + diff is intentionally the only mechanism
- Don't add shell interpolation to `gh` calls — always use `Process` with an argument array
- Don't prompt `gh auth logout` in tests — use a bogus gh-path override or `GH_CONFIG_DIR` pointing at an empty dir
