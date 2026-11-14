import XCTest
@testable import EnhancerCore

final class EnhancerTests: XCTestCase {
    func testRuleAllowsOnlyTheTwoCommandsForOneUser() throws {
        let rule = try XCTUnwrap(Enhancer.sudoersRule(user: "sam"))
        let lines = rule.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(lines, ["sam ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"])
        XCTAssertTrue(rule.hasSuffix("\n"), "sudoers files must end with a newline")
    }

    func testUserNamesThatCantGoInARule() {
        for bad in ["", "root", "-x", "a b", "a,b", "ALL", "a\nb", "é", String(repeating: "a", count: 65)] {
            XCTAssertNil(Enhancer.sudoersRule(user: bad), bad)
        }
        XCTAssertNotNil(Enhancer.sudoersRule(user: "first.last-2_x"))
    }

    func testFailsafeWatchesEveryAppAndTurnsSleepBackOn() {
        let script = Enhancer.failsafeScript()
        for name in Enhancer.watchedProcesses { XCTAssertTrue(script.contains("pgrep -x \(name)")) }
        XCTAssertTrue(script.contains("/usr/bin/pmset -a disablesleep 0"))
        XCTAssertFalse(script.contains("disablesleep 1"))
    }

    func testDaemonRunsTheFailsafeEveryMinute() {
        let plist = Enhancer.daemonPlist()
        XCTAssertTrue(plist.contains("<string>\(Enhancer.daemonLabel)</string>"))
        XCTAssertTrue(plist.contains("<string>\(Enhancer.failsafePath)</string>"))
        XCTAssertTrue(plist.contains("<integer>60</integer>"))
    }

    func testLidScriptInterface() {
        let script = Enhancer.lidScript()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("on) exec /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1"))
        XCTAssertTrue(script.contains("off) exec /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"))
        XCTAssertTrue(script.contains("\"enhancer\":\(Enhancer.interfaceVersion)"))
        XCTAssertTrue(script.contains("\\n'"), "status ends its line")
    }

    func testInstallValidatesTheRuleBeforeItGoesInPlace() throws {
        let script = try XCTUnwrap(Enhancer.installScript(user: "sam", stage: "/tmp/stage dir"))
        let visudo = try XCTUnwrap(script.range(of: "visudo -cf"))
        let install = try XCTUnwrap(script.range(of: "-m 0440 -o root -g wheel"))
        XCTAssertLessThan(visudo.lowerBound, install.lowerBound)
        XCTAssertTrue(script.hasPrefix("set -e"))
        XCTAssertTrue(script.contains("rm -f /etc/sudoers.d/keeper-awake"))
        XCTAssertNil(Enhancer.installScript(user: "sam", stage: "/tmp/it's"))
    }

    func testUninstallPutsSleepBack() {
        XCTAssertTrue(Enhancer.uninstallScript().contains("disablesleep 0"))
        XCTAssertTrue(Enhancer.uninstallScript().contains(Enhancer.ruleFile))
    }

    func testReadsPmset() {
        XCTAssertTrue(Enhancer.sleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t1\n"))
        XCTAssertFalse(Enhancer.sleepDisabled(pmsetOutput: " SleepDisabled\t\t0\n"))
        XCTAssertFalse(Enhancer.sleepDisabled(pmsetOutput: " sleep 1\n"))
    }

    func testAppleScriptQuoting() {
        XCTAssertEqual(Enhancer.appleScriptQuoted("a \"b\" \\c"), "\"a \\\"b\\\" \\\\c\"")
    }

    func testVersionMatchesTheVersionFile() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VERSION")
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(text, Enhancer.version)
    }
}
