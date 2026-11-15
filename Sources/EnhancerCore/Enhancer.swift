import Foundation

/// Everything the Enhancer writes, as plain text, so it can be checked on any machine. The app only
/// runs these with the administrator's password; nothing here touches the system by itself.
///
/// What it sets up (see docs/INTERFACE.md):
/// 1. `/etc/sudoers.d/ashforde-lid`: lets the person who installed it run exactly
///    `/usr/bin/pmset -a disablesleep 0` and `… 1` without a password. Nothing else.
/// 2. A fail-safe (a launch daemon that checks once a minute): if sleep is disabled and none of
///    Ashforde's apps is running, it turns sleep back on.
/// 3. `ashforde-lid.sh` in each Ashforde app's own scripts folder
///    (`~/Library/Application Scripts/<bundle id>/`), which sandboxed apps may run (NSUserUnixTask).
/// 4. Since 1.1, fan control for Monorail (see `FanHelper`): a small program,
///    `/Library/PrivilegedHelperTools/ashforde-fan`, a second rule allowing only that program's
///    `status`, `auto` and `set`, and `ashforde-fan.sh` in Monorail's scripts folder. The fail-safe
///    also hands the fans back to macOS when no Ashforde app is looking after them.
/// 5. Since 1.2, the charge limit for Monorail (see `ChargeHelper`): the same helper and rule also take
///    `charge`, `adapter` and `led`; the fail-safe puts normal charging back when no Ashforde app is
///    looking after it, and Remove does too.
public enum Enhancer {
    public static let version = "1.2.0"
    /// Bumped only when the files or the script's answers change shape.
    /// 2 (1.1): the fan helper, the fan script, and `"fan"` in the lid script's status.
    /// 3 (1.2): charge, adapter and led through the same script, and `"charge"` in both statuses.
    public static let interfaceVersion = 3
    public static let bundleID = "org.ashforde.enhancer"
    public static let urlScheme = "ashforde-enhancer"

    public static let ruleFile = "/etc/sudoers.d/ashforde-lid"
    /// Keeper's older file, replaced by the shared one.
    public static let legacyRuleFile = "/etc/sudoers.d/keeper-awake"
    public static let pmset = "/usr/bin/pmset"
    public static let daemonLabel = "org.ashforde.enhancer.failsafe"
    public static let daemonPlistPath = "/Library/LaunchDaemons/org.ashforde.enhancer.failsafe.plist"
    public static let failsafePath = "/Library/PrivilegedHelperTools/org.ashforde.enhancer.failsafe"
    public static let lidScriptName = "ashforde-lid.sh"

    /// The apps that use it: their scripts folders get the lid script.
    public static let clients = [
        "org.ashforde.monorail.appstore",  // Signalbox
        "org.ashforde.monorail",  // Monorail (direct; it can also call sudo itself)
        "io.github.ashfordeou.keeper",  // Keeper (direct)
        "io.github.ashfordeou.keeper.appstore",  // Hangar (Keeper's App Store edition)
    ]

    /// Process names of Ashforde's apps: while any runs, the fail-safe leaves sleep alone.
    public static let watchedProcesses = ["Monorail", "Signalbox", "Keeper", "Hangar"]

    /// A macOS short user name we're willing to put in a sudoers rule.
    public static func isValidUser(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, name != "root", name.uppercased() != "ALL" else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
            && !name.hasPrefix("-")
    }

    /// The rule: this one user, root, two exact commands, no password.
    public static func sudoersRule(user: String) -> String? {
        guard isValidUser(user) else { return nil }
        return """
            # Ashforde Enhancer \(version): lid-closed mode for Ashforde's apps (Monorail, Signalbox, Keeper, Hangar).
            # Allows only turning sleep off and on again. Remove with Ashforde Enhancer, or delete this file.
            \(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1

            """
    }

    /// The fail-safe: sleep back on when it's off and no Ashforde app is running (a crash, a force quit).
    /// Fans back to macOS when the helper has one forced and no Ashforde app is running, or the app
    /// has stopped re-sending its speeds (the marker is older than `FanHelper.staleMinutes`). Runs at
    /// boot too (RunAtLoad), and the marker survives a restart, so a crash mid-control is caught there.
    public static func failsafeScript() -> String {
        let checks = watchedProcesses.map { "/usr/bin/pgrep -x \($0) >/dev/null" }.joined(separator: " || ")
        let fan = FanHelper.helperPath, marker = FanHelper.markerPath, held = ChargeHelper.markerPath
        return """
            #!/bin/sh
            # Ashforde Enhancer \(version) fail-safe: run by launchd once a minute.
            running=false
            if { \(checks); }; then running=true; fi
            if \(pmset) -g | /usr/bin/grep -Eq '^[[:space:]]*SleepDisabled[[:space:]]+1'; then
                if [ "$running" = false ]; then
                    \(pmset) -a disablesleep 0
                    /usr/bin/logger -t ashforde-enhancer "No Ashforde app running: sleep turned back on"
                fi
            fi
            if [ -e \(marker) ] && [ -x \(fan) ]; then
                if [ "$running" = false ] || /usr/bin/find \(marker) -mmin +\(FanHelper.staleMinutes) | /usr/bin/grep -q .; then
                    \(fan) auto >/dev/null 2>&1
                    /usr/bin/logger -t ashforde-enhancer "No Ashforde app looking after the fans: macOS controls them again"
                fi
            fi
            if [ -e \(held) ] && [ -x \(fan) ]; then
                if [ "$running" = false ] || /usr/bin/find \(held) -mmin +\(ChargeHelper.staleMinutes) | /usr/bin/grep -q .; then
                    \(fan) adapter on >/dev/null 2>&1
                    \(fan) charge on >/dev/null 2>&1
                    \(fan) led system >/dev/null 2>&1
                    /bin/rm -f \(held)
                    /usr/bin/logger -t ashforde-enhancer "No Ashforde app looking after charging: normal charging is back"
                fi
            fi
            exit 0

            """
    }

    public static func daemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>\(failsafePath)</string>
            </array>
            <key>StartInterval</key>
            <integer>60</integer>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>

        """
    }

    /// The script each app runs: `on`, `off` or `status` (one line of JSON).
    public static func lidScript() -> String {
        """
        #!/bin/sh
        # Ashforde Enhancer \(version) lid script (interface \(interfaceVersion)). Usage: ashforde-lid.sh on|off|status
        case "$1" in
            on) exec /usr/bin/sudo -n \(pmset) -a disablesleep 1 ;;
            off) exec /usr/bin/sudo -n \(pmset) -a disablesleep 0 ;;
            status)
                rule=false; failsafe=false; disabled=false
                /usr/bin/sudo -n -l \(pmset) -a disablesleep 1 >/dev/null 2>&1 && rule=true
                [ -f \(daemonPlistPath) ] && failsafe=true
                \(pmset) -g | /usr/bin/grep -Eq '^[[:space:]]*SleepDisabled[[:space:]]+1' && disabled=true
                fan=false; charge=false
                [ -x \(FanHelper.helperPath) ] && /usr/bin/sudo -n -l \(FanHelper.helperPath) status >/dev/null 2>&1 && fan=true
                [ -x \(FanHelper.helperPath) ] && /usr/bin/sudo -n -l \(FanHelper.helperPath) charge on >/dev/null 2>&1 && charge=true
                printf '{"enhancer":\(interfaceVersion),"version":"\(version)","rule":%s,"failsafe":%s,"sleepDisabled":%s,"fan":%s,"charge":%s}\\n' "$rule" "$failsafe" "$disabled" "$fan" "$charge"
                ;;
            *) echo "usage: $0 on|off|status" >&2; exit 64 ;;
        esac

        """
    }

    /// The root part of installing, run once with the administrator's password. `stage` is a folder
    /// only this user can write, holding the files above: `rule`, `failsafe`, `daemon.plist`, and
    /// since 1.1 `fan-rule` and `fan` (the helper, from the app bundle). Both rules are checked with
    /// `visudo` before anything goes in place; the fans start in macOS's own control.
    public static func installScript(user: String, stage: String) -> String? {
        guard isValidUser(user), !stage.contains("'") else { return nil }
        return """
            set -e
            S='\(stage)'
            /usr/sbin/visudo -cf "$S/rule" >/dev/null
            /usr/sbin/visudo -cf "$S/fan-rule" >/dev/null
            /usr/bin/install -m 0440 -o root -g wheel "$S/rule" \(ruleFile)
            /bin/rm -f \(legacyRuleFile)
            /bin/mkdir -p /Library/PrivilegedHelperTools
            /usr/bin/install -m 0755 -o root -g wheel "$S/fan" \(FanHelper.helperPath)
            /usr/bin/install -m 0440 -o root -g wheel "$S/fan-rule" \(FanHelper.ruleFile)
            \(FanHelper.helperPath) auto >/dev/null 2>&1 || true
            \(FanHelper.helperPath) adapter on >/dev/null 2>&1 || true
            \(FanHelper.helperPath) charge on >/dev/null 2>&1 || true
            /usr/bin/install -m 0755 -o root -g wheel "$S/failsafe" \(failsafePath)
            /usr/bin/install -m 0644 -o root -g wheel "$S/daemon.plist" \(daemonPlistPath)
            /bin/launchctl bootout system/\(daemonLabel) 2>/dev/null || true
            /bin/launchctl bootstrap system \(daemonPlistPath)
            """
    }

    /// The root part of removing: everything off again, fans back to macOS, and sleep back on.
    public static func uninstallScript() -> String {
        """
        /bin/launchctl bootout system/\(daemonLabel) 2>/dev/null || true
        [ -x \(FanHelper.helperPath) ] && \(FanHelper.helperPath) auto >/dev/null 2>&1 || true
        [ -x \(FanHelper.helperPath) ] && \(FanHelper.helperPath) adapter on >/dev/null 2>&1 || true
        [ -x \(FanHelper.helperPath) ] && \(FanHelper.helperPath) charge on >/dev/null 2>&1 || true
        [ -x \(FanHelper.helperPath) ] && \(FanHelper.helperPath) led system >/dev/null 2>&1 || true
        /bin/rm -f \(daemonPlistPath) \(failsafePath) \(ruleFile) \(FanHelper.ruleFile) \(FanHelper.helperPath) \(FanHelper.markerPath) \(ChargeHelper.markerPath)
        \(pmset) -a disablesleep 0
        """
    }

    /// `pmset -g` says SleepDisabled 1 while sleep is off.
    public static func sleepDisabled(pmsetOutput: String) -> Bool {
        pmsetOutput.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.count >= 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
    }

    /// AppleScript string literal for `do shell script`.
    public static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
