# Interface (version 1)

How Monorail, Loop and Keeper use Ashforde Enhancer. Everything below stays the same within an
interface version; a change of shape bumps `enhancer` in the status answer.

## What it sets up

| Piece | Where | What |
|---|---|---|
| The rule | `/etc/sudoers.d/ashforde-lid` (root:wheel, 0440, checked with `visudo -cf` first) | `<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1`, for the person who set it up only |
| The fail-safe | `/Library/LaunchDaemons/org.ashforde.enhancer.failsafe.plist` running `/Library/PrivilegedHelperTools/org.ashforde.enhancer.failsafe` every 60 s | If `pmset -g` shows `SleepDisabled 1` and no process named `Monorail`, `Loop`, `Keeper` or `Hangar` is running, runs `pmset -a disablesleep 0` |
| The lid script | `~/Library/Application Scripts/<bundle id>/ashforde-lid.sh` (0755) for `org.ashforde.monorail.appstore`, `org.ashforde.monorail`, `io.github.ashfordeou.keeper`, `io.github.ashfordeou.keeper.appstore` | `on`, `off`, `status` (below) |

The rule is the same file the downloaded apps already share, so a Mac set up by either is set up for both.

## Calling it

**Sandboxed apps** (Loop, Hangar) run the lid script with
`NSUserUnixTask(url: FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("ashforde-lid.sh"))`:

| Argument | Does | Answers |
|---|---|---|
| `status` | Nothing | One line of JSON: `{"enhancer":1,"version":"1.0.0","rule":true,"failsafe":true,"sleepDisabled":false}` |
| `on` | `sudo -n pmset -a disablesleep 1` | Exit 0, or non-zero without the rule (never a password prompt) |
| `off` | `sudo -n pmset -a disablesleep 0` | Same |

No script (the file is missing) means the Enhancer isn't set up: offer to get it.

**Downloaded apps** (Monorail, Keeper) can do the same, or call `sudo -n /usr/bin/pmset -a disablesleep 0|1`
themselves and check with `sudo -n -l /usr/bin/pmset -a disablesleep 1`.

**Sending the person to it:** open `ashforde-enhancer://install?from=<your bundle id>`. If it isn't
installed, open the download page: <https://github.com/ashfordeOU/ashforde-enhancer/releases/latest>.

**From the command line:** `"/Applications/Ashforde Enhancer.app/Contents/MacOS/AshfordeEnhancer" status|install|uninstall|version`.
`status` adds `"scripts":[…]`, the bundle ids that have the lid script.

## The apps' side of the bargain

- Use lid-closed mode only while plugged in, and stop it when the Mac gets hot, the battery is low or
  Low Power Mode comes on (each app's own safety rules).
- Turn sleep back on (`off`) when the session ends or the app quits. The fail-safe catches crashes.
- Never ask for the password in the middle of a session: if `on` fails, say why and carry on with
  ordinary Stay Awake.
