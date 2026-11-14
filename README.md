# Ashforde Enhancer

One setup so lid-closed mode in Ashforde's apps (**Glance** and **Hangar** (Keeper) from the Mac App Store,
and the downloaded **Monorail** and **Keeper**) stops asking for your password every time.

Apps from the App Store aren't allowed to change the Mac's sleep setting. Ashforde Enhancer is a small,
notarised app from outside the App Store (like Amphetamine Enhancer) that, with your password once:

- lets **you** turn sleep off and on again (`pmset -a disablesleep 0|1`) without a password, and nothing else;
- adds a **fail-safe** that turns sleep back on within a minute if none of Ashforde's apps is running;
- puts a tiny script in each Ashforde app's own scripts folder, so the apps can use it.

**Remove…** in the app takes it all away again and turns sleep back on.

How the apps use it: [docs/INTERFACE.md](docs/INTERFACE.md).

## Building

`swift test` runs the tests on any machine. `scripts/build-app.sh` builds the app on a Mac.
CI also sets it up for real on GitHub's Mac, uses it and removes it again.

## Releasing

Bump `VERSION` (and `CHANGELOG.md`) on main: **Release** builds it, signs it with Developer ID, notarises
it and publishes it. It needs the same Actions secrets as `ashfordeOU/monorail`: `MONORAIL_SIGNING_CERT`,
`MONORAIL_SIGNING_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` (and `COMMIT_SIGNING_KEY`
for signed commits). Without them nothing is published.

## Licence

[FSL-1.1-ALv2](LICENSE). © 2026 Ashforde OÜ.

## Commits

Every commit on main is signed. Push to `incoming`: **Sign and land** signs the new commits with the
`COMMIT_SIGNING_KEY` secret (the same key as Monorail's and Keeper's) and moves main. **Re-sign history**
signs anything that got onto main another way.
