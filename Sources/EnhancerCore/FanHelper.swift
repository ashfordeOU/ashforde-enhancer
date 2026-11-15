import Foundation

/// The fan helper: a small program, `/Library/PrivilegedHelperTools/ashforde-fan`, that sets fan
/// speeds through the SMC. Writing to the SMC needs root, so one more rule
/// (`/etc/sudoers.d/ashforde-fan`) lets the person who installed the Enhancer run exactly this
/// program, with exactly three subcommands, without a password:
///
///     ashforde-fan status            one line of JSON: each fan's speed, range and mode
///     ashforde-fan auto              every fan back to macOS's own control
///     ashforde-fan set <fan> <rpm>   one fan to a fixed speed, kept inside that fan's own range
///
/// Everything that decides *what* to write lives here, as plain values, so it can be checked on any
/// machine. The helper itself only reads keys, follows the plan and writes the bytes.
public enum FanHelper {
    public static let name = "ashforde-fan"
    public static let helperPath = "/Library/PrivilegedHelperTools/ashforde-fan"
    public static let ruleFile = "/etc/sudoers.d/ashforde-fan"
    /// Present while a fan is under the helper's control. The fail-safe only steps in while it exists,
    /// so it never undoes another fan app's settings, and it survives a restart so it's caught at boot.
    public static let markerPath = "/var/db/ashforde-fan.forced"
    /// The marker is touched on every `set`; apps re-send their speeds at least once a minute. Older
    /// than this many minutes means the app has stopped looking after the fans (hung), so the fail-safe
    /// hands them back to macOS.
    public static let staleMinutes = 3
    public static let scriptName = "ashforde-fan.sh"
    /// Only the downloaded Monorail controls fans; the others never get the fan script.
    public static let clients = ["org.ashforde.monorail"]

    public static let maxFans = 10
    public static let maxRPM = 20_000

    // MARK: Arguments

    public enum Command: Equatable, Sendable {
        case status
        case auto
        case set(fan: Int, rpm: Int)
        /// Since 1.2: charging (see `ChargeHelper`).
        case charge(ChargeHelper.Charge)
        case adapter(on: Bool)
        case light(ChargeHelper.Light)
    }

    /// Strict: exactly one of the three shapes, plain ASCII digits only (no signs, spaces, hex or
    /// leading zeros beyond "0"), a fan index 0–9 and a speed of at most 20,000 rpm. Anything else is nil.
    public static func parse(_ arguments: [String]) -> Command? {
        switch arguments.count {
        case 1 where arguments[0] == "status": return .status
        case 1 where arguments[0] == "auto": return .auto
        case 3 where arguments[0] == "set":
            guard let fan = number(arguments[1], maxDigits: 1), fan < maxFans,
                  let rpm = number(arguments[2], maxDigits: 5), rpm <= maxRPM else { return nil }
            return .set(fan: fan, rpm: rpm)
        case 2 where arguments[0] == "charge" && arguments[1] == "on": return .charge(.on)
        case 2 where arguments[0] == "charge" && arguments[1] == "off": return .charge(.off)
        case 3 where arguments[0] == "charge" && arguments[1] == "limit":
            guard let n = number(arguments[2], maxDigits: 3), (20...100).contains(n) else { return nil }
            return .charge(.limit(n))
        case 2 where arguments[0] == "adapter" && arguments[1] == "on": return .adapter(on: true)
        case 2 where arguments[0] == "adapter" && arguments[1] == "off": return .adapter(on: false)
        case 2 where arguments[0] == "led":
            return ChargeHelper.Light(rawValue: arguments[1]).map { .light($0) }
        default: return nil
        }
    }

    private static func number(_ text: String, maxDigits: Int) -> Int? {
        guard !text.isEmpty, text.utf8.count <= maxDigits, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        guard text == "0" || !text.hasPrefix("0") else { return nil }
        return Int(text)
    }

    public static let usage = "usage: ashforde-fan status | auto | set <fan 0-9> <rpm> | charge on|off|limit <20-100> | adapter on|off | led system|green|orange"

    /// A requested speed kept inside the fan's own range (as the SMC reports it). Nil when the range
    /// doesn't make sense, so nothing is written.
    public static func clamp(_ rpm: Int, min: Double, max: Double) -> Int? {
        guard min.isFinite, max.isFinite, min >= 0, max > 0, max >= min, max <= Double(maxRPM) else { return nil }
        let low = Int(min.rounded(.up)), high = Int(max.rounded(.down))
        guard high >= low else { return nil }
        return Swift.min(Swift.max(rpm, low), high)
    }

    // MARK: SMC keys

    public static func actualKey(_ fan: Int) -> String { "F\(fan)Ac" }
    public static func minKey(_ fan: Int) -> String { "F\(fan)Mn" }
    public static func maxKey(_ fan: Int) -> String { "F\(fan)Mx" }
    public static func targetKey(_ fan: Int) -> String { "F\(fan)Tg" }
    public static let countKey = "FNum"
    /// Apple silicon: writing 1 here lets a fan's mode be forced (thermalmonitord lets go of it).
    public static let unlockKey = "Ftst"
    /// Older Intel Macs: a bit per fan; a set bit means forced.
    public static let forceMaskKey = "FS! "

    /// The fan's mode key, as this Mac spells it (`F0Md` on most, `F0md` on some), if it has one.
    public static func modeKey(_ fan: Int, has: (String) -> Bool) -> String? {
        ["F\(fan)Md", "F\(fan)md"].first(where: has)
    }

    /// One value written to one key. `retries` > 0 means write, read back and try again (a quarter
    /// of a second apart) until the value sticks: on Apple silicon a fan's mode only takes once
    /// thermalmonitord has let go, which can take a few seconds after the unlock.
    public struct Write: Equatable, Sendable {
        public var key: String
        public var value: Double
        public var retries: Int
        public init(_ key: String, _ value: Double, retries: Int = 0) {
            self.key = key
            self.value = value
            self.retries = retries
        }
    }

    public enum PlanError: Error, Equatable {
        /// No such fan on this Mac.
        case noSuchFan
        /// The fan's range can't be read, so there's no safe speed to clamp to.
        case unknownRange
        /// This Mac has no way to force a fan that the helper knows (it writes nothing rather than guess).
        case unsupported
    }

    /// What to write for `set`: unlock (Apple silicon), force the fan's mode, then its target.
    /// - Parameters:
    ///   - fanCount: FNum.
    ///   - range: the fan's min and max from F<n>Mn and F<n>Mx.
    ///   - has: whether the SMC has a key.
    ///   - forcedMask: FS! now (older Intel Macs only).
    public static func planSet(fan: Int, rpm: Int, fanCount: Int, range: (min: Double, max: Double)?,
                               has: (String) -> Bool, forcedMask: Int = 0) -> Result<[Write], PlanError> {
        guard fan >= 0, fan < Swift.min(fanCount, maxFans) else { return .failure(.noSuchFan) }
        guard let range, let speed = clamp(rpm, min: range.min, max: range.max) else { return .failure(.unknownRange) }
        guard has(targetKey(fan)) else { return .failure(.unsupported) }
        var writes: [Write] = []
        let unlock = has(unlockKey)
        if unlock { writes.append(Write(unlockKey, 1)) }
        if let mode = modeKey(fan, has: has) {
            writes.append(Write(mode, 1, retries: unlock ? 40 : 4))
        } else if has(forceMaskKey) {
            writes.append(Write(forceMaskKey, Double(forcedMask | (1 << fan))))
        } else {
            return .failure(.unsupported)
        }
        writes.append(Write(targetKey(fan), Double(speed)))
        return .success(writes)
    }

    /// What to write for `auto`: every fan's mode back to 0, the Intel mask cleared, then the lock back.
    /// Nothing to write (no fans, or a Mac without these keys) is a plan too: an empty one.
    public static func planAuto(fanCount: Int, has: (String) -> Bool) -> [Write] {
        var writes: [Write] = []
        for fan in 0..<Swift.max(0, Swift.min(fanCount, maxFans)) {
            if let mode = modeKey(fan, has: has) { writes.append(Write(mode, 0, retries: 4)) }
        }
        if has(forceMaskKey) { writes.append(Write(forceMaskKey, 0)) }
        if has(unlockKey) { writes.append(Write(unlockKey, 0)) }
        return writes
    }

    // MARK: SMC values

    /// A key's type as the SMC names it ("flt ", "fpe2", "ui8 "…), from its four-character code.
    public static func typeName(_ code: UInt32) -> String {
        String(decoding: [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)], as: UTF8.self)
    }

    /// A four-character key or type name as the SMC's 32-bit code.
    public static func code(_ name: String) -> UInt32 {
        name.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The bytes for a value of a given SMC type, or nil for a type (or size) the helper won't write.
    public static func encode(_ value: Double, type: String, size: Int) -> [UInt8]? {
        guard value.isFinite, value >= 0 else { return nil }
        switch (type, size) {
        case ("flt ", 4):
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
        case ("fpe2", 2):
            guard value * 4 <= Double(UInt16.max) else { return nil }
            let raw = UInt16(value * 4)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case ("ui8 ", 1):
            guard value <= 255 else { return nil }
            return [UInt8(value)]
        case ("ui16", 2):
            guard value <= Double(UInt16.max) else { return nil }
            let raw = UInt16(value)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case ("ui32", 4):
            guard value <= Double(UInt32.max) else { return nil }
            let raw = UInt32(value)
            return [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
        default:
            return nil
        }
    }

    /// A value read from the SMC, for the types fans use.
    public static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ":
            guard bytes.count >= 1 else { return nil }
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    // MARK: Status

    public struct FanState: Equatable, Sendable {
        public var index: Int
        public var rpm: Double
        public var min: Double?
        public var max: Double?
        public var target: Double?
        public var forced: Bool
        public init(index: Int, rpm: Double, min: Double?, max: Double?, target: Double?, forced: Bool) {
            self.index = index
            self.rpm = rpm
            self.min = min
            self.max = max
            self.target = target
            self.forced = forced
        }
    }

    /// `status`'s one line: `{"helper":2,"version":"1.2.0","fans":[{"index":0,"rpm":1200,"min":1200,"max":5779,"target":1200,"forced":false}],"controlled":false,"charge":{…}}`.
    /// `controlled` is the marker: the helper has a fan forced right now. `charge` (1.2) is `ChargeHelper.statusJSON`.
    public static func statusJSON(fans: [FanState], controlled: Bool, charge: String? = nil) -> String {
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "null" }
            return String(Int(value.rounded()))
        }
        let list = fans.map {
            "{\"index\":\($0.index),\"rpm\":\(number($0.rpm)),\"min\":\(number($0.min)),\"max\":\(number($0.max)),\"target\":\(number($0.target)),\"forced\":\($0.forced)}"
        }.joined(separator: ",")
        let chargePart = charge.map { ",\"charge\":" + $0 } ?? ""
        return "{\"helper\":\(helperInterface),\"version\":\"\(Enhancer.version)\",\"fans\":[\(list)],\"controlled\":\(controlled)\(chargePart)}"
    }

    /// Bumped only when the helper's subcommands or answers change shape.
    /// 2 (1.2): charge, adapter and led, and `"charge"` in `status`.
    public static let helperInterface = 2

    // MARK: What the Enhancer installs

    /// The second rule: this one user, root, this one program with its three subcommands, no password.
    /// The program checks its own arguments strictly (`parse`), so the `set *` wildcard can't reach
    /// anything but a fan speed.
    public static func sudoersRule(user: String) -> String? {
        guard Enhancer.isValidUser(user) else { return nil }
        return """
            # Ashforde Enhancer \(Enhancer.version): fan control and the charge limit for Monorail.
            # Allows only the helper's status, auto, set, charge, adapter and led. Remove with Ashforde Enhancer, or delete this file.
            \(user) ALL=(root) NOPASSWD: \(helperPath) status, \(helperPath) auto, \(helperPath) set *, \(helperPath) charge on, \(helperPath) charge off, \(helperPath) charge limit *, \(helperPath) adapter on, \(helperPath) adapter off, \(helperPath) led *

            """
    }

    /// The script Monorail runs from its scripts folder (NSUserUnixTask), passing only the shapes the
    /// helper accepts. Never asks for a password (`sudo -n`).
    public static func script() -> String {
        """
        #!/bin/sh
        # Ashforde Enhancer \(Enhancer.version) fan and charge script (interface \(Enhancer.interfaceVersion)).
        # Usage: ashforde-fan.sh status|auto|set <fan> <rpm>|charge on|off|limit <n>|adapter on|off|led system|green|orange
        H=\(helperPath)
        [ -x "$H" ] || { echo "The helper isn't installed." >&2; exit 69; }
        case "$1" in
            status) [ $# -eq 1 ] && exec /usr/bin/sudo -n "$H" status ;;
            auto) [ $# -eq 1 ] && exec /usr/bin/sudo -n "$H" auto ;;
            set) [ $# -eq 3 ] && exec /usr/bin/sudo -n "$H" set "$2" "$3" ;;
            charge)
                case "$2" in
                    on|off) [ $# -eq 2 ] && exec /usr/bin/sudo -n "$H" charge "$2" ;;
                    limit) [ $# -eq 3 ] && exec /usr/bin/sudo -n "$H" charge limit "$3" ;;
                esac ;;
            adapter) [ $# -eq 2 ] && case "$2" in on|off) exec /usr/bin/sudo -n "$H" adapter "$2" ;; esac ;;
            led) [ $# -eq 2 ] && case "$2" in system|green|orange) exec /usr/bin/sudo -n "$H" led "$2" ;; esac ;;
        esac
        echo "usage: $0 status|auto|set <fan> <rpm>|charge on|off|limit <n>|adapter on|off|led system|green|orange" >&2
        exit 64

        """
    }
}
