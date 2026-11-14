# Changelog

## [1.0.0] - 2026-11-14

### Added
- **Lid-closed mode without the password** for Monorail, Signalbox, Keeper and Folio: one rule allowing only `pmset -a disablesleep 0|1`, for you only, checked with `visudo` before it goes in place.
- **A fail-safe** that turns sleep back on within a minute if none of Ashforde's apps is running.
- **The lid script** (`on`, `off`, `status`) in each app's scripts folder, for the App Store editions.
- **Remove…** takes it all away and turns sleep back on.
- `ashforde-enhancer://install?from=<bundle id>` and a command line (`status`, `install`, `uninstall`, `version`).
