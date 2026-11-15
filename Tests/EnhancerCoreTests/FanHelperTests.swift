import XCTest
@testable import EnhancerCore

final class FanHelperTests: XCTestCase {
    // MARK: Arguments

    func testAcceptsOnlyTheThreeShapes() {
        XCTAssertEqual(FanHelper.parse(["status"]), .status)
        XCTAssertEqual(FanHelper.parse(["auto"]), .auto)
        XCTAssertEqual(FanHelper.parse(["set", "0", "2400"]), .set(fan: 0, rpm: 2400))
        XCTAssertEqual(FanHelper.parse(["set", "9", "20000"]), .set(fan: 9, rpm: 20000))
        XCTAssertEqual(FanHelper.parse(["set", "1", "0"]), .set(fan: 1, rpm: 0))
    }

    func testRejectsEverythingElse() {
        let bad: [[String]] = [
            [], ["STATUS"], ["status", "x"], ["auto", "now"], ["set"], ["set", "0"], ["set", "0", "1200", "x"],
            ["set", "-1", "1200"], ["set", "10", "1200"], ["set", "a", "1200"], ["set", "0", "-5"], ["set", "0", "+5"],
            ["set", "0", "1e3"], ["set", "0", "0x10"], ["set", "0", "1200.5"], ["set", "0", " 1200"], ["set", "0", "1200\n"],
            ["set", "0", "20001"], ["set", "0", "123456"], ["set", "0", "01200"], ["set", "00", "1200"], ["set", "0", ""],
            ["set", "٣", "1200"], ["set", "0", "１２００"], ["reboot"], ["-h"], ["status;rm"],
        ]
        for args in bad { XCTAssertNil(FanHelper.parse(args), "\(args)") }
    }

    // MARK: Clamping

    func testClampsToTheFansOwnRange() {
        XCTAssertEqual(FanHelper.clamp(100, min: 1200, max: 5779), 1200)
        XCTAssertEqual(FanHelper.clamp(9000, min: 1200, max: 5779), 5779)
        XCTAssertEqual(FanHelper.clamp(3000, min: 1200, max: 5779), 3000)
        XCTAssertEqual(FanHelper.clamp(3000, min: 1199.6, max: 5779.4), 3000)
        XCTAssertEqual(FanHelper.clamp(0, min: 1199.6, max: 5779.4), 1200)
        XCTAssertEqual(FanHelper.clamp(9999, min: 1199.6, max: 5779.4), 5779)
    }

    func testNoSpeedWhenTheRangeMakesNoSense() {
        XCTAssertNil(FanHelper.clamp(2000, min: 3000, max: 1000))
        XCTAssertNil(FanHelper.clamp(2000, min: 0, max: 0))
        XCTAssertNil(FanHelper.clamp(2000, min: -1, max: 5000))
        XCTAssertNil(FanHelper.clamp(2000, min: 1000, max: .nan))
        XCTAssertNil(FanHelper.clamp(2000, min: 1000, max: 60000))
    }

    // MARK: Plans

    private func keys(_ list: [String]) -> (String) -> Bool { { Set(list).contains($0) } }

    func testAppleSiliconUnlocksThenForcesThenSetsTheTarget() throws {
        let has = keys(["FNum", "Ftst", "F0Md", "F0Tg", "F0Mn", "F0Mx", "F1Md", "F1Tg"])
        let writes = try FanHelper.planSet(fan: 0, rpm: 9000, fanCount: 2, range: (1200, 5779), has: has).get()
        XCTAssertEqual(writes.map(\.key), ["Ftst", "F0Md", "F0Tg"])
        XCTAssertEqual(writes.map(\.value), [1, 1, 5779], "the target is clamped to the fan's maximum")
        XCTAssertGreaterThan(writes[1].retries, 0, "the mode only sticks once thermalmonitord lets go")
    }

    func testLowercaseModeKey() throws {
        let writes = try FanHelper.planSet(fan: 1, rpm: 2000, fanCount: 2, range: (1000, 5000),
                                           has: keys(["Ftst", "F1md", "F1Tg"])).get()
        XCTAssertEqual(writes.map(\.key), ["Ftst", "F1md", "F1Tg"])
    }

    func testOlderIntelUsesTheForceMask() throws {
        let writes = try FanHelper.planSet(fan: 1, rpm: 3000, fanCount: 2, range: (2000, 6000),
                                           has: keys(["FS! ", "F1Tg"]), forcedMask: 0b01).get()
        XCTAssertEqual(writes, [FanHelper.Write("FS! ", 3), FanHelper.Write("F1Tg", 3000)])
    }

    func testIntelWithModeKeysNeedsNoUnlock() throws {
        let writes = try FanHelper.planSet(fan: 0, rpm: 3000, fanCount: 1, range: (2000, 6000), has: keys(["F0Md", "F0Tg"])).get()
        XCTAssertEqual(writes.map(\.key), ["F0Md", "F0Tg"])
    }

    func testRefusesRatherThanGuesses() {
        let has = keys(["Ftst", "F0Md", "F0Tg"])
        XCTAssertEqual(FanHelper.planSet(fan: 1, rpm: 2000, fanCount: 1, range: (1000, 5000), has: has), .failure(.noSuchFan))
        XCTAssertEqual(FanHelper.planSet(fan: 0, rpm: 2000, fanCount: 0, range: (1000, 5000), has: has), .failure(.noSuchFan))
        XCTAssertEqual(FanHelper.planSet(fan: 0, rpm: 2000, fanCount: 1, range: nil, has: has), .failure(.unknownRange))
        XCTAssertEqual(FanHelper.planSet(fan: 0, rpm: 2000, fanCount: 1, range: (5000, 1000), has: has), .failure(.unknownRange))
        XCTAssertEqual(FanHelper.planSet(fan: 0, rpm: 2000, fanCount: 1, range: (1000, 5000), has: keys(["F0Tg"])), .failure(.unsupported))
        XCTAssertEqual(FanHelper.planSet(fan: 0, rpm: 2000, fanCount: 1, range: (1000, 5000), has: keys(["F0Md"])), .failure(.unsupported))
    }

    func testAutoHandsEveryFanBackThenLocks() {
        let auto = FanHelper.planAuto(fanCount: 2, has: keys(["Ftst", "F0Md", "F1Md"]))
        XCTAssertEqual(auto.map(\.key), ["F0Md", "F1Md", "Ftst"])
        XCTAssertTrue(auto.allSatisfy { $0.value == 0 })
        XCTAssertEqual(FanHelper.planAuto(fanCount: 2, has: keys(["FS! "])), [FanHelper.Write("FS! ", 0)])
        XCTAssertEqual(FanHelper.planAuto(fanCount: 0, has: keys([])), [], "a Mac without fans has nothing to undo")
    }

    // MARK: Values

    func testEncodesAndDecodesTheFanTypes() {
        XCTAssertEqual(FanHelper.encode(2400, type: "flt ", size: 4), [0x00, 0x00, 0x16, 0x45])
        XCTAssertEqual(FanHelper.decode([0x00, 0x00, 0x16, 0x45], type: "flt "), 2400)
        XCTAssertEqual(FanHelper.encode(2400, type: "fpe2", size: 2), [0x25, 0x80])
        XCTAssertEqual(FanHelper.decode([0x25, 0x80], type: "fpe2"), 2400)
        XCTAssertEqual(FanHelper.encode(1, type: "ui8 ", size: 1), [1])
        XCTAssertEqual(FanHelper.encode(3, type: "ui16", size: 2), [0, 3])
        XCTAssertEqual(FanHelper.decode([0, 3], type: "ui16"), 3)
    }

    func testWontWriteOddValuesOrTypes() {
        XCTAssertNil(FanHelper.encode(2400, type: "flt ", size: 2), "size must match the type")
        XCTAssertNil(FanHelper.encode(-1, type: "flt ", size: 4))
        XCTAssertNil(FanHelper.encode(.infinity, type: "flt ", size: 4))
        XCTAssertNil(FanHelper.encode(256, type: "ui8 ", size: 1))
        XCTAssertNil(FanHelper.encode(1, type: "ch8*", size: 1))
        XCTAssertNil(FanHelper.decode([1], type: "flt "))
    }

    func testKeyCodes() {
        XCTAssertEqual(FanHelper.code("FNum"), 0x464E_756D)
        XCTAssertEqual(FanHelper.typeName(FanHelper.code("flt ")), "flt ")
        XCTAssertEqual(FanHelper.code("FS! "), 0x4653_2120)
    }

    func testStatusLine() throws {
        let line = FanHelper.statusJSON(fans: [FanHelper.FanState(index: 0, rpm: 1203.4, min: 1200, max: 5779, target: nil, forced: false)],
                                        controlled: false)
        XCTAssertEqual(line, "{\"helper\":2,\"version\":\"\(Enhancer.version)\",\"fans\":[{\"index\":0,\"rpm\":1203,\"min\":1200,\"max\":5779,\"target\":null,\"forced\":false}],\"controlled\":false}")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
    }

    // MARK: What gets installed

    func testFanRuleAllowsOnlyTheHelpersThreeSubcommands() throws {
        let rule = try XCTUnwrap(FanHelper.sudoersRule(user: "sam"))
        let lines = rule.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let h = FanHelper.helperPath
        XCTAssertEqual(lines, ["sam ALL=(root) NOPASSWD: \(h) status, \(h) auto, \(h) set *, \(h) charge on, \(h) charge off, \(h) charge limit *, \(h) adapter on, \(h) adapter off, \(h) led *"])
        XCTAssertTrue(rule.hasSuffix("\n"))
        XCTAssertNil(FanHelper.sudoersRule(user: "root"))
        XCTAssertNil(FanHelper.sudoersRule(user: "a b"))
    }

    func testFanScriptPassesOnlyTheHelpersShapes() {
        let script = FanHelper.script()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("status) [ $# -eq 1 ] && exec /usr/bin/sudo -n \"$H\" status"))
        XCTAssertTrue(script.contains("auto) [ $# -eq 1 ] && exec /usr/bin/sudo -n \"$H\" auto"))
        XCTAssertTrue(script.contains("set) [ $# -eq 3 ] && exec /usr/bin/sudo -n \"$H\" set \"$2\" \"$3\""))
        XCTAssertTrue(script.contains("exit 64"))
        XCTAssertFalse(script.contains("$@"), "never passes arguments through wholesale")
    }

    func testFailsafeHandsTheFansBack() {
        let script = Enhancer.failsafeScript()
        XCTAssertTrue(script.contains("[ -e \(FanHelper.markerPath) ]"), "only when the helper has the fans")
        XCTAssertTrue(script.contains("\(FanHelper.helperPath) auto"))
        XCTAssertTrue(script.contains("-mmin +\(FanHelper.staleMinutes)"), "and when the app stopped looking after them")
        XCTAssertFalse(script.contains("\(FanHelper.helperPath) set"))
    }

    func testInstallChecksBothRulesFirstAndStartsInAuto() throws {
        let script = try XCTUnwrap(Enhancer.installScript(user: "sam", stage: "/tmp/s"))
        let checkFan = try XCTUnwrap(script.range(of: "visudo -cf \"$S/fan-rule\""))
        let firstInstall = try XCTUnwrap(script.range(of: "/usr/bin/install"))
        XCTAssertLessThan(checkFan.lowerBound, firstInstall.lowerBound)
        XCTAssertTrue(script.contains("-m 0755 -o root -g wheel \"$S/fan\" \(FanHelper.helperPath)"))
        XCTAssertTrue(script.contains("-m 0440 -o root -g wheel \"$S/fan-rule\" \(FanHelper.ruleFile)"))
        XCTAssertTrue(script.contains("\(FanHelper.helperPath) auto"))
    }

    func testUninstallHandsBackThenRemovesTheHelperAndRule() throws {
        let script = Enhancer.uninstallScript()
        let auto = try XCTUnwrap(script.range(of: "\(FanHelper.helperPath) auto"))
        let remove = try XCTUnwrap(script.range(of: "/bin/rm -f"))
        XCTAssertLessThan(auto.lowerBound, remove.lowerBound)
        for path in [FanHelper.helperPath, FanHelper.ruleFile, FanHelper.markerPath] { XCTAssertTrue(script.contains(path), path) }
    }

    func testLidStatusSaysWhetherFansWork() {
        XCTAssertTrue(Enhancer.lidScript().contains("\"fan\":%s"))
    }
}
