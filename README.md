# ClaudeUsageBar

A tiny macOS menu bar app that keeps all three of your Claude usage limits visible at all
times - the same numbers `/usage` prints inside Claude Code, without having to open a session
to see them.

```
5h 42% · 7d 61% · Opus 18%
```

Claude subscriptions are metered across three separate windows, and it is easy to be surprised
by the one you were not watching. ClaudeUsageBar puts all three in the menu bar, colours them
by how close each is to its cap, and refreshes them in the background, so a limit that is
about to bite is visible out of the corner of your eye rather than at the moment a request
gets refused.

> **Requires Claude Code** on the same Mac, signed in and used regularly. The app has no
> sign-in of its own - it reads the token Claude Code keeps in the login keychain, and relies
> on Claude Code to keep that token fresh. See
> [Why Claude Code is required](#why-claude-code-is-required).

## The three limits

| Row | What it meters |
| --- | --- |
| **Session (5h)** | The rolling five hour window - the one you hit first in a long working session |
| **Weekly (all models)** | The seven day window covering every model |
| **Weekly (`<model>`)** | The seven day window for the premium model your plan meters on its own (Opus, for example) |

The third row appears only if your plan meters a premium model separately; the label follows
whatever model that is, so it stays correct if your plan changes.

## Features

- All three usage windows in the menu bar at once, as `5h 42% · 7d 61% · Opus 18%`
- Percentages coloured by severity: normal below 75%, orange from 75%, red from 90%
- A dropdown with a bar per limit and, for each window, when it resets - as a wall clock time
  and a countdown
- **Compact Menu Bar Display** toggle: drops the `5h` / `7d` / model labels for a narrower
  `42% · 61% · 18%`. The choice is remembered between launches.
- Clicking any of the three bars, or **Open Usage on claude.ai**, opens the full dashboard
- A `--print` mode for reading the same figures from a terminal
- Refreshes every 60 seconds and again whenever the menu is opened
- No Dock icon, no window, no preferences file to manage, no third-party dependencies

## How it works

The readings come from `https://api.anthropic.com/api/oauth/usage`, the same account endpoint
Claude Code itself polls, so the numbers match `/usage` exactly.

Authentication reuses the OAuth access token that `claude` stores in the login keychain under
`Claude Code-credentials`. The token is **only ever read** - never written, never refreshed,
never sent anywhere other than `api.anthropic.com`. There is nothing to log in to and no
credential of its own to manage.

- The first read may raise the standard macOS keychain prompt. Choosing *Always Allow* makes
  it a one-off.
- If the token has expired, the menu bar shows `⚠︎` beside the last known numbers and the menu
  explains that running `claude` in a terminal will refresh it. Renewing tokens is left to
  Claude Code itself.
- Network hiccups do not blank the display: the last good numbers stay on screen, marked with
  `⚠︎`, and the menu carries the reason plus the time of the last successful update.
- Polling is throttled. Opening the menu triggers a refresh, so there is a 15 second floor
  between requests, and if the API ever answers `429` the app pauses for five minutes rather
  than retrying into the limit. *Refresh Now* skips the floor but not the pause.
- The app runs as an accessory (`LSUIElement`), so it has no Dock icon and no application
  window - only the menu bar item.
- Written in Swift against AppKit, in a single source file (`main.swift`).

### Why Claude Code is required

There is no account to enter, no login screen and no settings pane. Signing in happens in
Claude Code - `claude auth login`, or `/login` inside a session - which writes the OAuth token
to the login keychain. ClaudeUsageBar reads that token and nothing else.

This is an **ongoing** dependency, not a one-time setup step. OAuth access tokens expire after
a few hours. Claude Code refreshes its token when it starts; ClaudeUsageBar deliberately does
not. On a Mac where `claude` never runs, the app therefore reaches `⚠︎ Token expired` within
hours and stays there until Claude Code is run again.

That is a deliberate trade rather than an oversight. The refresh token sits in the same
keychain blob and the app could spend it, but refresh tokens commonly rotate on use: spending
one without writing the replacement back would invalidate the copy Claude Code holds and break
your actual CLI login, while writing it back would mean two processes racing for the same
credential. For a status indicator neither is worth the risk, so the app stays strictly
read-only and lets Claude Code own the token.

Removing the dependency altogether is not clean either. Its own OAuth flow would mean either
registering a client with Anthropic or reusing Claude Code's client ID, which amounts to a
third-party app impersonating Claude Code. An API key reports no subscription windows, so
there would be nothing to show. The Admin API is org-scoped, needs an admin key, and reports
different figures than these three windows.

In practice the constraint costs little: these three limits only exist for someone with a
Claude subscription who is actively spending it through Claude Code, and anyone who wants
this in their menu bar already has the CLI signed in.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools, which provide `swiftc` and `codesign`
- **Claude Code, installed on the same Mac and signed in with a Claude subscription**
  (`claude auth login`). This app has no sign-in of its own - see
  [Why Claude Code is required](#why-claude-code-is-required) below. API key users have no
  subscription limits to report.

If the command line tools are not installed yet:

```bash
xcode-select --install
```

## Installation

The repository ships the source, not a prebuilt binary, so the app bundle is assembled
locally. The whole process is four commands.

### 1. Get the source

```bash
git clone https://github.com/ainahtokyandry/claude-usage.git
cd claude-usage
```

### 2. Build the app bundle

```bash
./build.sh
```

`build.sh` creates `ClaudeUsageBar.app`, copies `Info.plist` into it, compiles `main.swift`
with `swiftc -O`, and signs the bundle ad hoc with `codesign`. The signing step is required -
an unsigned bundle will not launch on recent versions of macOS.

The equivalent by hand:

```bash
mkdir -p ClaudeUsageBar.app/Contents/MacOS
cp Info.plist ClaudeUsageBar.app/Contents/Info.plist
swiftc -O main.swift -o ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar
codesign --force --sign - ClaudeUsageBar.app
```

### 3. Run it

```bash
open ClaudeUsageBar.app
```

The three readings appear in the menu bar within a second or two. Nothing else opens, since
the app has no window and no Dock icon. If macOS asks for permission to read
`Claude Code-credentials` from your keychain, choose **Always Allow**.

To build and launch in one step:

```bash
./build.sh --run
```

### 4. Install it for everyday use

Move the bundle into your Applications folder so it lives outside the checkout:

```bash
mv ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

### 5. Launch at login

Open **System Settings > General > Login Items & Extensions**, then under **Open at Login**
press `+` and pick `ClaudeUsageBar.app`.

## Using it

Clicking the menu bar item opens the breakdown:

- A bar per limit, showing the same percentage in a fuller form
- When each window resets, as a wall clock time and a countdown
- **Refresh Now** - force an immediate update (shortcut: `r` while the menu is open)
- **Open Usage on claude.ai** - the full dashboard in a browser (`o`); clicking any of the
  three bars does the same
- **Compact Menu Bar Display** - toggle the `5h` / `7d` / model labels off for a narrower
  menu bar footprint
- **Quit ClaudeUsageBar** (`q`)

### Reading usage from a terminal

The same binary prints the three limits and exits when passed `--print`:

```bash
./ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --print
```

```
Session (5h)         ██████░░░░░░░░  42%  resets 19:05 (in 2h 11m)
Weekly (all models)  █████████░░░░░  61%  resets Sun 3 Aug, 09:00 (in 3d 4h)
Weekly (Opus)        ███░░░░░░░░░░░  18%  resets Sun 3 Aug, 09:00 (in 3d 4h)
```

It exits non-zero if the usage could not be read, so it drops straight into a shell prompt or
a status script.

## Rebuilding after a change

macOS keeps running the already-launched binary, so the app has to be stopped before it is
replaced. `build.sh` does that itself:

```bash
./build.sh --run
```

By hand: quit, rebuild, re-sign, relaunch.

```bash
pkill -x ClaudeUsageBar
swiftc -O main.swift -o ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar
codesign --force --sign - ClaudeUsageBar.app
open ClaudeUsageBar.app
```

Skipping `codesign` after a rebuild leaves the bundle in a broken state, because replacing the
executable invalidates the existing signature.

## Troubleshooting

**The menu bar shows `⚠︎` and "Not signed in".** No `Claude Code-credentials` entry was found
in the login keychain. Run `claude auth login` in a terminal, then pick *Refresh Now*.

**The menu bar shows `⚠︎` and "Token expired".** The stored access token is past its expiry.
Start `claude` in a terminal - it refreshes the token on startup - then pick *Refresh Now*. If
that does not clear it, sign in again with `claude auth login`.

**A keychain prompt keeps appearing.** Choose *Always Allow* rather than *Allow*, so the
decision is remembered for later refreshes.

**The third row is missing.** Your plan does not meter a premium model separately, so the API
reports only two windows. The other two rows work as normal.

**Nothing appears in the menu bar.** A menu bar with many items can hide the newest one on a
laptop with a notch. Quit some other menu bar apps, or use **Compact Menu Bar Display** to
shorten this one.

## Uninstalling

```bash
pkill -x ClaudeUsageBar
rm -rf /Applications/ClaudeUsageBar.app
```

If you added it as a login item, remove the entry in
**System Settings > General > Login Items & Extensions** as well.

Nothing else is left behind apart from one preference, the compact display toggle, which goes
with:

```bash
defaults delete local.claudeusagebar
```

## Project layout

```
main.swift    Entire application: keychain read, usage fetch, status item, menu, 60 second timer
Info.plist    Bundle metadata (identifier, version, LSUIElement, minimum system version)
build.sh      Assemble, compile and ad hoc sign the app bundle; --run also launches it
```

Build products (`ClaudeUsageBar.app/` and any bare `ClaudeUsageBar` executable) are not
tracked.
