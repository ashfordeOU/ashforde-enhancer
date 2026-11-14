# Interface (version 2)

How Monorail, Glance and Keeper use Ashforde Enhancer. Everything below stays the same within an
interface version; a change of shape bumps `enhancer` in the status answer.

## What it sets up

| Piece | Where | What |
|---|---|---|
| The rule | `/etc/sudoers.d/ashforde-lid` (root:wheel, 0440, checked with `visudo -cf` first) | `<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1`, for the person who set it up only |
| The fail-safe | `/Library/LaunchDaemons/org.ashforde.enhancer.failsafe.plist` running `/Library/PrivilegedHelperTools/org.ashforde.enhancer.failsafe` every 60 s and at start-up | If `pmset -g` shows `SleepDisabled 1` and no process named `Monorail`, `Glance`, `Keeper` or `Hangar` is running, runs `pmset -a disablesleep 0`. If `/var/db/ashforde-fan.forced` exists and no such process is running, or it is more than 3 minutes old, runs `ashforde-fan auto` |
| The lid script | `~/Library/Application Scripts/<bundle id>/ashforde-lid.sh` (0755) for `org.ashforde.monorail.appstore`, `org.ashforde.monorail`, `io.github.ashfordeou.keeper`, `io.github.ashfordeou.keeper.appstore` | `on`, `off`, `status` (below) |
| The fan helper (1.1) | `/Library/PrivilegedHelperTools/ashforde-fan` (root:wheel, 0755, signed as `org.ashforde.enhancer.fan`) | `status`, `auto`, `set <fan> <rpm>` (below) |
| The fan rule (1.1) | `/etc/sudoers.d/ashforde-fan` (root:wheel, 0440, checked with `visudo -cf` first) | `<user> ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/ashforde-fan status, … auto, … set *` |
| The fan script (1.1) | `~/Library/Application Scripts/org.ashforde.monorail/ashforde-fan.sh` (0755), Monorail only | `status`, `auto`, `set <fan> <rpm>`, each through `sudo -n` |

The rule is the same file the downloaded apps already share, so a Mac set up by either is set up for both.

## Calling it

**Sandboxed apps** (Glance, Hangar) run the lid script with
`NSUserUnixTask(url: FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("ashforde-lid.sh"))`:

| Argument | Does | Answers |
|---|---|---|
| `status` | Nothing | One line of JSON: `{"enhancer":2,"version":"1.1.0","rule":true,"failsafe":true,"sleepDisabled":false,"fan":true}` (`fan`: the fan helper and its rule work; absent before 1.1) |
| `on` | `sudo -n pmset -a disablesleep 1` | Exit 0, or non-zero without the rule (never a password prompt) |
| `off` | `sudo -n pmset -a disablesleep 0` | Same |

No script (the file is missing) means the Enhancer isn't set up: offer to get it.

## Fans (1.1, Monorail only)

Monorail runs `ashforde-fan.sh` from its scripts folder the same way. No script means the Enhancer is
missing or older than 1.1: offer to set it up again.

| Argument | Does | Answers |
|---|---|---|
| `status` | Nothing | One line of JSON: `{"helper":1,"version":"1.1.0","fans":[{"index":0,"rpm":1203,"min":1200,"max":5779,"target":1200,"forced":false}],"controlled":false}` (`controlled`: the helper has a fan forced) |
| `set <fan> <rpm>` | Forces fan `<fan>` (0–9) to `<rpm>` (digits only, at most 20000), kept inside that fan's own `min`…`max`, and touches `/var/db/ashforde-fan.forced` | Exit 0; 64 bad arguments; 65 no such fan or no readable range; 69 not possible on this Mac; 70 the SMC refused (the fans are handed back to macOS) |
| `auto` | Every fan back to macOS, removes the marker | Exit 0 (also when there's nothing to undo); 70 if the SMC refused |

What the helper writes: on **Apple silicon**, `Ftst` = 1 (lets a fan's mode be forced), `F<n>Md` = 1
(retried for up to 10 s while macOS lets go; spelled `F<n>md` on some Macs), then `F<n>Tg` = the speed as
a float; `auto` writes every `F<n>Md` = 0 and then `Ftst` = 0. On **Intel** Macs with `F<n>Md`, the same
without `Ftst`; on older Intel Macs, the fan's bit in `FS! ` and `F<n>Tg` (fpe2), and `auto` clears `FS! `.
It never writes `F<n>Mn` (a fan's minimum), so there's nothing to restore. Any other Mac answers 69 and
nothing is written.

**The apps' side:** send `set` only when a speed changes, and again at least once a minute while you're
controlling the fans (the fail-safe takes over after 3 minutes of silence); send `auto` when you stop,
when the Mac goes to sleep and when you quit. Keep your own safety rules: full speed when anything is
critically hot, and `auto` when the temperatures can't be read.

## Lid: the downloaded apps

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
