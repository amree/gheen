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
bash build.sh
```

This compiles `Sources/Gheen/*.swift` into `Gheen.app`, ad-hoc signs it, and launches it. A menubar icon appears (no Dock icon). Approve the notification permission prompt on first launch.

> If notifications don't appear, move `Gheen.app` to `/Applications` and relaunch — macOS is stricter about notifications for apps run from arbitrary locations.

## Usage

1. Click the menubar icon → **Settings**.
2. Add repos to watch as `owner/repo` (e.g. `amree/myproject`).
3. Gheen polls each repo for runs you triggered. In-progress runs show in the dropdown; you get a notification when each finishes. Click a run (or its notification) to open it in the browser.
4. **Quit** from the dropdown footer.

## How it works

- Polls `gh run list -R <repo> -u <you> -L 100 --json ...` every 30s (configurable).
- Notifies on the active→completed transition, keyed by `databaseId#attempt` so reruns notify again; the first poll is a silent baseline.
- Menubar icon: idle / running / red (a failure stays red until you open the dropdown).

## MVP limitations

- **Apple Silicon only** (`-target arm64-apple-macosx13.0`). Universal binary is a future step.
- Only runs **you triggered** (`-u <you>`) — scheduled/other-user runs are excluded by design.
- On a very busy repo, a long run can fall out of the latest 100 before completing and be missed.
- Single `github.com` account.

## Layout

```
Sources/Gheen/   Swift sources (App, Monitor, GitHubClient, views, models)
Resources/       Info.plist
build.sh         compile → bundle → sign → launch
```
