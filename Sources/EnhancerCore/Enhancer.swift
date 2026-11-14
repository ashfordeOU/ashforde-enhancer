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
public enum Enhancer {
    public static let version = "1.0.0"
    /// Bumped only when the files or the script's answers change shape.
    public static let interfaceVersion = 1
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
        "org.ashforde.monorail.appstore",  // Glance
        "org.ashforde.monorail",  // Monorail (direct; it can also call sudo itself)
        "io.github.ashfordeou.keeper",  // Keeper (direct)
        "io.github.ashfordeou.keeper.appstore",  // Hangar (Keeper's App Store edition)
    ]

    /// Process names of Ashforde's apps: while any runs, the fail-safe leaves sleep alone.
    public static let watchedProcesses = ["Monorail", "Glance", "Keeper", "Hangar"]

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
            # Ashforde Enhancer \(version): lid-closed mode for Ashforde's apps (Monorail, Glance, Keeper, Hangar).
            # Allows only turning sleep off and on again. Remove with Ashforde Enhancer, or delete this file.
            \(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1

            """
    }

    /// The fail-safe: sleep back on when it's off and no Ashforde app is running (a crash, a force quit).
    public static func failsafeScript() -> String {
        let checks = watchedProcesses.map { "/usr/bin/pgrep -x \($0) >/dev/null" }.joined(separator: " || ")
        return """
            #!/bin/sh
            # Ashforde Enhancer \(version) fail-safe: run by launchd once a minute.
            if \(pmset) -g | /usr/bin/grep -Eq '^[[:space:]]*SleepDisabled[[:space:]]+1'; then
                if ! { \(checks); }; then
                    \(pmset) -a disablesleep 0
                    /usr/bin/logger -t ashforde-enhancer "No Ashforde app running: sleep turned back on"
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
                printf '{"enhancer":\(interfaceVersion),"version":"\(version)","rule":%s,"failsafe":%s,"sleepDisabled":%s}\\n' "$rule" "$failsafe" "$disabled"
                ;;
            *) echo "usage: $0 on|off|status" >&2; exit 64 ;;
        esac

        """
    }

    /// The root part of installing, run once with the administrator's password. `stage` is a folder
    /// only this user can write, holding the three files above.
    public static func installScript(user: String, stage: String) -> String? {
        guard isValidUser(user), !stage.contains("'") else { return nil }
        return """
            set -e
            S='\(stage)'
            /usr/sbin/visudo -cf "$S/rule" >/dev/null
            /usr/bin/install -m 0440 -o root -g wheel "$S/rule" \(ruleFile)
            /bin/rm -f \(legacyRuleFile)
            /bin/mkdir -p /Library/PrivilegedHelperTools
            /usr/bin/install -m 0755 -o root -g wheel "$S/failsafe" \(failsafePath)
            /usr/bin/install -m 0644 -o root -g wheel "$S/daemon.plist" \(daemonPlistPath)
            /bin/launchctl bootout system/\(daemonLabel) 2>/dev/null || true
            /bin/launchctl bootstrap system \(daemonPlistPath)
            """
    }

    /// The root part of removing: everything off again, and sleep back on.
    public static func uninstallScript() -> String {
        """
        /bin/launchctl bootout system/\(daemonLabel) 2>/dev/null || true
        /bin/rm -f \(daemonPlistPath) \(failsafePath) \(ruleFile)
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
