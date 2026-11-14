# Changelog

## [1.1.0] - Unreleased

### Added
- **Fan control for Monorail.** One more rule and one more small program, nothing else: `/Library/PrivilegedHelperTools/ashforde-fan` (root:wheel, 0755, signed with the app) and `/etc/sudoers.d/ashforde-fan`, which lets you run only that program's `status`, `auto` and `set <fan> <rpm>` without a password. The helper checks its arguments strictly, keeps every speed inside the fan's own range, and refuses rather than guesses on a Mac it doesn't know.
- **`ashforde-fan.sh`** in Monorail's scripts folder (`status`, `auto`, `set`), and `"fan"` in the lid script's status. Interface version 2.
- **The fail-safe looks after the fans too:** within a minute of no Ashforde app running (a crash, a force quit), or of Monorail no longer re-sending its speeds, the fans go back to macOS. Also at start-up, on setting up and on removing.

### Changed
- **Remove…** also hands the fans back to macOS and removes the helper and its rule.
- A Mac set up with 1.0 shows **Set Up Again** until the fan helper is in place.

## [1.0.0] - 2026-11-14

### Added
- **Lid-closed mode without the password** for Monorail, Signalbox, Keeper and Hangar: one rule allowing only `pmset -a disablesleep 0|1`, for you only, checked with `visudo` before it goes in place.
- **A fail-safe** that turns sleep back on within a minute if none of Ashforde's apps is running.
- **The lid script** (`on`, `off`, `status`) in each app's scripts folder, for the App Store editions.
- **Remove…** takes it all away and turns sleep back on.
- `ashforde-enhancer://install?from=<bundle id>` and a command line (`status`, `install`, `uninstall`, `version`).
