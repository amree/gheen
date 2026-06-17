# Gheen

A tiny macOS menubar app that notifies you when a GitHub Actions run **you triggered** finishes (✅ success / ❌ failure / ⚪️ cancelled).

It reuses your existing `gh` CLI login — no separate auth, no tokens to manage.

## Prerequisites

- Apple Silicon Mac, macOS 13+
- [GitHub CLI](https://cli.github.com) installed and logged in:
  ```sh
  gh auth status   # should show "Logged in"
  ```
- Xcode command line tools (`swiftc`, `codesign`) — `xcode-select --install`

## Build & run

```sh
make run        # build + launch (recommended)
make build      # build only, no launch
make install    # build + copy to /Applications (useful for sharing without notarization)
make clean      # remove Gheen.app
```

Or directly: `bash build.sh` (compiles, signs, and launches in one step).

A menubar icon appears (no Dock icon). Approve the notification permission prompt on first launch.

> **No notifications?** Check System Settings → Notifications → Gheen — authorization may have been denied silently on first launch. If missing from the list, move `Gheen.app` to `/Applications` and relaunch (macOS restricts notification registration for apps in arbitrary paths). Re-approve the prompt, then quit and reopen.

> **Sharing with another Mac?** Run `make install` on the source machine, then AirDrop `/Applications/Gheen.app` to the target. On the target Mac, run `xattr -dr com.apple.quarantine /Applications/Gheen.app` once to clear the Gatekeeper quarantine flag (ad-hoc signed, not notarized). Requires `gh` installed and logged in on the target too.

## Usage

1. Click the menubar icon → **Settings**.
2. Add repos to watch as `owner/repo` (e.g. `amree/myproject`).
3. Gheen polls each repo for runs you triggered. In-progress runs show in the dropdown; you get a notification when each finishes. Click a run (or its notification) to open it in the browser.
4. Use the **All / PR / Push / Manual** filter tabs at the top of the dropdown to narrow the list by trigger type. Tabs only appear when multiple event types are present.
5. Hover over a PR row to see the PR title as a tooltip.
6. **Quit** from the dropdown footer.

## How it works

- Polls `gh run list -R <repo> -u <you> -L 100 --json ...` every 60s (configurable).
- **Exponential backoff when idle**: if no active runs are detected, the poll interval doubles each cycle (60s → 120s → 240s → … → 10 min cap). Opens back to the configured interval when you click the menubar icon or an active run appears.
- Notifies on the active→completed transition, keyed by `databaseId#attempt` so reruns notify again; the first poll is a silent baseline.
- Menubar icon: `○` idle / `◌` active / `●` red (failure stays red until you open the dropdown).
- PR rows show branch name + workflow; push/manual rows show workflow name + branch + event type. Each row shows a relative time (e.g. `5m ago`) on the right.

## MVP limitations

- **Apple Silicon only** (`-target arm64-apple-macosx13.0`). Universal binary is a future step.
- Only runs **you triggered** (`-u <you>`) — scheduled/other-user runs are excluded by design.
- On a very busy repo, a long run can fall out of the latest 100 before completing and be missed.
- Single `github.com` account.

## Layout

```
Sources/Gheen/   Swift sources (App, Monitor, GitHubClient, views, models)
Resources/       Info.plist
Makefile         build / run / clean / install targets
build.sh         compile → bundle → sign → launch (single script alternative)
```
