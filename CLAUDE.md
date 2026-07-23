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
  MenuContentView.swift   dropdown UI (filter tabs, active / recent / error / settings / quit)
  SettingsView.swift      add/remove repos, interval picker, gh path override
Resources/
  Info.plist              CFBundleIdentifier=com.amree.gheen, LSUIElement=true
Makefile                  build / run / clean / install targets
docs/
  DESIGN.md               Full design doc + 3-round Claude↔Codex review history
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
- `isPolling` guard skips overlapping timer ticks; 20s per-process timeout kills hung `gh`
- First poll = baseline: already-finished runs recorded to `notifiedKeys`, never notified
- **Exponential backoff**: idle polls (no active runs) double the interval each cycle, capped at 10 min. Resets on dropdown open, active run detected, or Settings save
- **Event-aware rows**: PR runs show branch name (bold) + repo · workflow; non-PR runs show run display title (bold) + repo · branch · workflow. Right-aligned `timeAgo` on every row. Hover tooltip shows PR title
- **Static filter tabs**: fixed All / PR / Push / Manual segmented control, always shown; filters run list by `eventLabel`
- **Notifications**: title = conclusion emoji + run display title; body = repo · branch · workflow
- Menubar icons: `circle` idle, `circle.dotted` active, `circle.fill` red on unacked failure

## What NOT to do
- Don't add per-run `gh run view` polling — list + diff is intentionally the only mechanism
- Don't add shell interpolation to `gh` calls — always use `Process` with an argument array
- Don't prompt `gh auth logout` in tests — use a bogus gh-path override or `GH_CONFIG_DIR` pointing at an empty dir
