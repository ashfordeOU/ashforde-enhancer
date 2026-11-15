import XCTest
@testable import EnhancerCore

final class ChargeHelperTests: XCTestCase {
    func testParsesOnlyTheChargeShapes() {
        XCTAssertEqual(FanHelper.parse(["charge", "on"]), .charge(.on))
        XCTAssertEqual(FanHelper.parse(["charge", "off"]), .charge(.off))
        XCTAssertEqual(FanHelper.parse(["charge", "limit", "80"]), .charge(.limit(80)))
        XCTAssertEqual(FanHelper.parse(["charge", "limit", "100"]), .charge(.limit(100)))
        XCTAssertEqual(FanHelper.parse(["adapter", "off"]), .adapter(on: false))
        XCTAssertEqual(FanHelper.parse(["led", "green"]), .light(.green))
        let bad: [[String]] = [["charge"], ["charge", "ON"], ["charge", "limit"], ["charge", "limit", "19"], ["charge", "limit", "101"],
                               ["charge", "limit", "080"], ["charge", "limit", "8 0"], ["charge", "on", "x"], ["adapter"], ["adapter", "maybe"],
                               ["led", "red"], ["led"], ["led", "green", "x"]]
        for args in bad { XCTAssertNil(FanHelper.parse(args), "\(args)") }
    }

    private func sizes(_ map: [String: Int]) -> (String) -> Int? { { map[$0] } }

    func testPicksTheKeysThisMacHas() {
        XCTAssertEqual(ChargeHelper.method(size: sizes(["CHTE": 4, "CH0B": 1])), .chte)
        XCTAssertEqual(ChargeHelper.method(size: sizes(["CH0B": 1, "CH0C": 1])), .ch0b)
        XCTAssertEqual(ChargeHelper.method(size: sizes(["BCLM": 1])), .bclm)
        // Zero-size placeholders (newer firmware) don't count.
        XCTAssertEqual(ChargeHelper.method(size: sizes(["CHTE": 0, "CH0B": 0])), ChargeHelper.Method.none)
        XCTAssertEqual(ChargeHelper.adapter(size: sizes(["CHIE": 1, "CH0I": 1])), .chie)
        XCTAssertEqual(ChargeHelper.adapter(size: sizes(["CH0J": 1])), .ch0j)
        XCTAssertEqual(ChargeHelper.adapter(size: sizes([:])), ChargeHelper.Adapter.none)
    }

    func testPlans() {
        XCTAssertEqual(ChargeHelper.planCharge(.off, method: .chte), .success([.init("CHTE", [1, 0, 0, 0])]))
        XCTAssertEqual(ChargeHelper.planCharge(.on, method: .chte), .success([.init("CHTE", [0, 0, 0, 0])]))
        XCTAssertEqual(ChargeHelper.planCharge(.off, method: .ch0b), .success([.init("CH0B", [2]), .init("CH0C", [2])]))
        XCTAssertEqual(ChargeHelper.planCharge(.limit(80), method: .bclm), .success([.init("BCLM", [80])]))
        XCTAssertEqual(ChargeHelper.planCharge(.on, method: .bclm), .success([.init("BCLM", [100])]))
        XCTAssertEqual(ChargeHelper.planCharge(.limit(80), method: .chte), .failure(.unsupported))
        XCTAssertEqual(ChargeHelper.planCharge(.off, method: ChargeHelper.Method.none), .failure(.unsupported))
        XCTAssertEqual(ChargeHelper.planCharge(.on, method: ChargeHelper.Method.none), .success([]))
        XCTAssertEqual(ChargeHelper.planAdapter(on: false, adapter: .chie), .success([.init("CHIE", [8])]))
        XCTAssertEqual(ChargeHelper.planAdapter(on: true, adapter: .ch0i), .success([.init("CH0I", [0])]))
        XCTAssertEqual(ChargeHelper.planAdapter(on: false, adapter: ChargeHelper.Adapter.none), .failure(.unsupported))
        XCTAssertEqual(ChargeHelper.planLight(.orange, has: true), .success([.init("ACLC", [4])]))
        XCTAssertEqual(ChargeHelper.planLight(.system, has: false), .success([]))
    }

    func testStateAndStatus() throws {
        let size = sizes(["CHTE": 4, "CHIE": 1, "ACLC": 1])
        let bytes: [String: [UInt8]] = ["CHTE": [1, 0, 0, 0], "CHIE": [0]]
        let state = ChargeHelper.state(size: size, read: { bytes[$0] })
        XCTAssertTrue(state.paused)
        XCTAssertFalse(state.adapterOff)
        XCTAssertFalse(state.isNormal)
        let json = ChargeHelper.statusJSON(state, held: true)
        XCTAssertEqual(json, "{\"method\":\"chte\",\"adapter\":\"chie\",\"led\":true,\"paused\":true,\"adapterOff\":false,\"limit\":null,\"held\":true}")
        let line = FanHelper.statusJSON(fans: [], controlled: false, charge: json)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
    }

    func testFailsafeAndRemovePutChargingBack() throws {
        let failsafe = Enhancer.failsafeScript()
        XCTAssertTrue(failsafe.contains("[ -e \(ChargeHelper.markerPath) ]"))
        XCTAssertTrue(failsafe.contains("\(FanHelper.helperPath) charge on"))
        XCTAssertTrue(failsafe.contains("\(FanHelper.helperPath) adapter on"))
        let uninstall = Enhancer.uninstallScript()
        let on = try XCTUnwrap(uninstall.range(of: "\(FanHelper.helperPath) charge on"))
        let remove = try XCTUnwrap(uninstall.range(of: "/bin/rm -f"))
        XCTAssertLessThan(on.lowerBound, remove.lowerBound)
        XCTAssertTrue(FanHelper.script().contains("charge limit \"$3\""))
        XCTAssertTrue(Enhancer.lidScript().contains("\"charge\":%s"))
    }
}
