# Ashforde Enhancer

One setup so lid-closed mode in Ashforde's apps (**Glance** and **Hangar** (Keeper) from the Mac App Store,
and the downloaded **Monorail** and **Keeper**) stops asking for your password every time, and so Monorail
can set fan speeds.

Apps from the App Store aren't allowed to change the Mac's sleep setting. Ashforde Enhancer is a small,
notarised app from outside the App Store (like Amphetamine Enhancer) that, with your password once:

- lets **you** turn sleep off and on again (`pmset -a disablesleep 0|1`) without a password, and nothing else;
- adds a **fail-safe** that turns sleep back on within a minute if none of Ashforde's apps is running;
- puts a tiny script in each Ashforde app's own scripts folder, so the apps can use it.

## Fan control (1.1)

Setting a fan's speed means writing to the Mac's fan controller (the SMC), and macOS only lets an
administrator do that. So 1.1 adds exactly two things:

- **One more small program**, `/Library/PrivilegedHelperTools/ashforde-fan`, owned by the system and
  signed like the app. It does three things only: read the fans (`status`), set one fan to a speed
  (`set <fan> <rpm>`), and hand every fan back to macOS (`auto`). It always keeps a speed inside that
  fan's own minimum and maximum, as the Mac reports them, and it won't touch a Mac it doesn't recognise.
- **One more rule**, `/etc/sudoers.d/ashforde-fan`, that lets **you** run that program, and nothing else,
  without a password.

Nothing else changes. Monorail decides the speeds; the Enhancer only makes them possible. The
**fail-safe** hands the fans back to macOS within a minute if Monorail stops running or stops looking after
them, and again when the Mac starts up. It only steps in when the helper set the fans, so it never undoes
another fan app's settings.

**Remove…** in the app takes it all away again: the fans go back to macOS, sleep goes back on, and the
rules, the helper and the scripts are deleted.

How the apps use it: [docs/INTERFACE.md](docs/INTERFACE.md).

## Building

`swift test` runs the tests on any machine. `scripts/build-app.sh` builds the app (and the fan helper inside
it, `Contents/MacOS/ashforde-fan`) on a Mac.
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
