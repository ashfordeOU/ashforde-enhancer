#if os(macOS)
import EnhancerCore
import Foundation
import IOKit

/// ashforde-fan: sets fan speeds through the SMC. Installed by Ashforde Enhancer as
/// /Library/PrivilegedHelperTools/ashforde-fan (root:wheel, 0755), run with `sudo -n` under the rule
/// in /etc/sudoers.d/ashforde-fan. It reads no environment, no files and no configuration: only its
/// own arguments, checked by `FanHelper.parse`, and the SMC.
///
///     ashforde-fan status            one line of JSON
///     ashforde-fan auto              every fan back to macOS (exit 0, also when there's nothing to undo)
///     ashforde-fan set <fan> <rpm>   one fan forced to a speed inside its own range
///     ashforde-fan charge on|off|limit <n>, adapter on|off, led system|green|orange   (1.2, see ChargeHelper)
///
/// Exit codes: 0 done, 64 usage, 65 no such fan or no readable range, 69 not possible on this Mac,
/// 70 the SMC refused a write (the fans are handed back to macOS), 77 needs root.

/// The SMC's call structure (SMCKeyData_t, 80 bytes), laid out to match the C one.
private struct KeyData {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct LimitData { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0 }
    var key: UInt32 = 0
    var version = Version()
    var limit = LimitData()
    var info = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private final class SMC {
    private let connection: io_connect_t
    private var infos: [String: KeyData.KeyInfo?] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == KERN_SUCCESS else { return nil }
        connection = c
    }

    deinit { IOServiceClose(connection) }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return r == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private func info(_ key: String) -> KeyData.KeyInfo? {
        if let cached = infos[key] { return cached }
        var input = KeyData()
        input.key = FanHelper.code(key)
        input.data8 = 9 // get key info
        let found = call(&input)?.info
        infos[key] = .some(found)
        return found
    }

    func has(_ key: String) -> Bool { info(key) != nil }

    /// A key's size in bytes, or nil when the Mac has no such key.
    func size(_ key: String) -> Int? { info(key).map { Int($0.size) } }

    /// A key's raw bytes.
    func readRaw(_ key: String) -> [UInt8]? {
        guard let info = info(key), info.size > 0 else { return nil }
        var input = KeyData()
        input.key = FanHelper.code(key)
        input.info = info
        input.data8 = 5 // read bytes
        guard let out = call(&input) else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(info.size, 32)))) }
    }

    /// Raw bytes to a key whose size matches exactly, then read back to check they stuck.
    func writeRaw(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let info = info(key), Int(info.size) == bytes.count else { return false }
        var input = KeyData()
        input.key = FanHelper.code(key)
        input.info = info
        input.data8 = 6 // write bytes
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (i, byte) in bytes.enumerated() where i < buffer.count { buffer[i] = byte }
        }
        guard call(&input) != nil else { return false }
        return readRaw(key) == bytes
    }

    func read(_ key: String) -> Double? {
        guard let info = info(key) else { return nil }
        var input = KeyData()
        input.key = FanHelper.code(key)
        input.info = info
        input.data8 = 5 // read bytes
        guard let out = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(info.size, 32)))) }
        return FanHelper.decode(bytes, type: FanHelper.typeName(info.type))
    }

    func write(_ key: String, _ value: Double) -> Bool {
        guard let info = info(key),
              let bytes = FanHelper.encode(value, type: FanHelper.typeName(info.type), size: Int(info.size)) else { return false }
        var input = KeyData()
        input.key = FanHelper.code(key)
        input.info = info
        input.data8 = 6 // write bytes
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (i, byte) in bytes.enumerated() where i < buffer.count { buffer[i] = byte }
        }
        return call(&input) != nil
    }

    /// Writes, and for a write with retries, reads back until the value sticks.
    func apply(_ write: FanHelper.Write) -> Bool {
        for attempt in 0...write.retries {
            if attempt > 0 { usleep(250_000) }
            guard self.write(write.key, write.value) else { continue }
            if write.retries == 0 { return true }
            if let now = read(write.key), abs(now - write.value) < 0.5 { return true }
        }
        return false
    }
}

private func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private var controlled: Bool { FileManager.default.fileExists(atPath: FanHelper.markerPath) }
private var chargeHeld: Bool { FileManager.default.fileExists(atPath: ChargeHelper.markerPath) }

guard let command = FanHelper.parse(Array(CommandLine.arguments.dropFirst())) else { fail(FanHelper.usage, 64) }
if command != .status && geteuid() != 0 { fail("ashforde-fan needs to run as root (through its sudo rule).", 77) }

guard let smc = SMC() else {
    if command == .status {
        let none = ChargeHelper.State(method: .none, adapter: .none, light: false, paused: false, adapterOff: false, limit: nil)
        print(FanHelper.statusJSON(fans: [], controlled: controlled, charge: ChargeHelper.statusJSON(none, held: chargeHeld)))
        exit(0)
    }
    if command == .auto { // Nothing to hand back.
        try? FileManager.default.removeItem(atPath: FanHelper.markerPath)
        exit(0)
    }
    if command == .charge(.on) || command == .adapter(on: true) || command == .light(.system) { // Nothing to put back.
        try? FileManager.default.removeItem(atPath: ChargeHelper.markerPath)
        exit(0)
    }
    fail("This Mac's fan controller (the SMC) can't be opened.", 69)
}

let fanCount = min(Int(smc.read(FanHelper.countKey) ?? 0), FanHelper.maxFans)
let has: (String) -> Bool = { smc.has($0) }
let keySize: (String) -> Int? = { smc.size($0) }

/// The charging keys as they are now.
let chargeState: () -> ChargeHelper.State = { ChargeHelper.state(size: keySize, read: { smc.readRaw($0) }) }

/// Writes a charging plan, then keeps the marker in step with the result: present while anything is
/// held back, gone once all is normal again.
let applyCharge: (Result<[ChargeHelper.Write], ChargeHelper.PlanError>, Bool) -> Never = { plan, holds in
    switch plan {
    case .failure(.unsupported): fail("This Mac doesn't let charging be changed that way.", 69)
    case .failure(.badValue): fail(FanHelper.usage, 64)
    case .success(let writes):
        // The marker first when holding, so the fail-safe knows even if this stops halfway.
        if holds { FileManager.default.createFile(atPath: ChargeHelper.markerPath, contents: Data(), attributes: [.posixPermissions: 0o644]) }
        var ok = true
        for write in writes where !smc.writeRaw(write.key, write.bytes) { ok = false }
        if chargeState().isNormal { try? FileManager.default.removeItem(atPath: ChargeHelper.markerPath) }
        if !ok { fail("The SMC didn't take the change; try again.", 70) }
        exit(0)
    }
}

/// Hands every fan back to macOS and clears the marker when that worked.
let handBack: () -> Bool = {
    var ok = true
    for write in FanHelper.planAuto(fanCount: fanCount, has: has) where !smc.apply(write) { ok = false }
    if ok { try? FileManager.default.removeItem(atPath: FanHelper.markerPath) }
    return ok
}

switch command {
case .status:
    let mask = Int(smc.read(FanHelper.forceMaskKey) ?? 0)
    var fans: [FanHelper.FanState] = []
    for i in 0..<max(0, fanCount) {
        let mode = FanHelper.modeKey(i, has: has).flatMap { smc.read($0) }
        let forced = mode.map { $0 == 1 } ?? (mask & (1 << i) != 0)
        fans.append(FanHelper.FanState(index: i, rpm: max(smc.read(FanHelper.actualKey(i)) ?? 0, 0),
                                       min: smc.read(FanHelper.minKey(i)), max: smc.read(FanHelper.maxKey(i)),
                                       target: smc.read(FanHelper.targetKey(i)), forced: forced))
    }
    print(FanHelper.statusJSON(fans: fans, controlled: controlled, charge: ChargeHelper.statusJSON(chargeState(), held: chargeHeld)))

case .auto:
    if !handBack() { fail("The SMC didn't take every change; try again.", 70) }

case .charge(let charge):
    let holds: Bool
    if case .limit(let n) = charge { holds = n < 100 } else { holds = charge == .off }
    applyCharge(ChargeHelper.planCharge(charge, method: ChargeHelper.method(size: keySize)), holds)

case .adapter(let on):
    applyCharge(ChargeHelper.planAdapter(on: on, adapter: ChargeHelper.adapter(size: keySize)), !on)

case .light(let light):
    // The light alone never holds anything back; the marker follows the charging keys.
    applyCharge(ChargeHelper.planLight(light, has: ChargeHelper.has("ACLC", size: keySize)), false)

case .set(let fan, let rpm):
    var range: (min: Double, max: Double)?
    if let lo = smc.read(FanHelper.minKey(fan)), let hi = smc.read(FanHelper.maxKey(fan)) { range = (lo, hi) }
    let plan = FanHelper.planSet(fan: fan, rpm: rpm, fanCount: fanCount, range: range, has: has,
                                 forcedMask: Int(smc.read(FanHelper.forceMaskKey) ?? 0))
    switch plan {
    case .failure(.noSuchFan): fail("This Mac has no fan \(fan).", 65)
    case .failure(.unknownRange): fail("Fan \(fan)'s speed range can't be read, so nothing was changed.", 65)
    case .failure(.unsupported): fail("Fans can't be set on this Mac.", 69)
    case .success(let writes):
        // The marker first, so the fail-safe knows to look after the fans even if this stops halfway.
        FileManager.default.createFile(atPath: FanHelper.markerPath, contents: Data(), attributes: [.posixPermissions: 0o644])
        for write in writes where !smc.apply(write) {
            _ = handBack()
            fail("The SMC didn't take \(write.key.trimmingCharacters(in: .whitespaces)); the fans are back in macOS's control.", 70)
        }
    }
}
exit(0)
#else
import EnhancerCore
import Foundation
FileHandle.standardError.write(Data("ashforde-fan runs on macOS.\n".utf8))
exit(69)
#endif
