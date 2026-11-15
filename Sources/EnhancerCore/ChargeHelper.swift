import Foundation

/// Charging, since 1.2 (Monorail's charge limit): the same helper, `/Library/PrivilegedHelperTools/ashforde-fan`,
/// takes a few more subcommands, all allowed by the same rule:
///
///     ashforde-fan charge on          charging allowed (and BCLM 100 on Intel)
///     ashforde-fan charge off         charging paused (the Mac still runs from the adapter)
///     ashforde-fan charge limit <n>   Intel only: the battery's own maximum, 20–100
///     ashforde-fan adapter on|off     the adapter switched on, or off in software (the Mac runs from its battery)
///     ashforde-fan led system|green|orange   the MagSafe light
///
/// Monorail decides *when* (its governor); the helper only knows *how*, Mac by Mac. Key names as used and
/// documented by the MIT-licensed `battery` CLI (github.com/actuallymentor/battery) and bclm
/// (github.com/zackelia/bclm); AlDente (GPL-3.0) for the history of CH0B. No code from them is used.
///
/// - Pausing: `CHTE` (4 bytes, 01 00 00 00 pauses, 00 00 00 00 allows) on newer Apple silicon firmware
///   (macOS 15 and 26), else `CH0B` and `CH0C` (1 byte each, 02 pauses, 00 allows).
/// - The adapter: `CHIE` (08 off, 00 on), else `CH0J` (01 / 00), else `CH0I` (01 / 00). Reported to be
///   the only key left answering on macOS 27 firmware.
/// - Intel: `BCLM` (1 byte, the maximum charge in %).
/// - The light: `ACLC` (1 byte, 03 green, 04 orange, 00 back to the system).
///
/// A key counts only when the SMC reports it with the expected size: newer firmware keeps some old names
/// as zero-size placeholders, and writing to those would do nothing (or fail), so they're skipped.
public enum ChargeHelper {
    /// Present while the helper has changed charging (paused it, switched the adapter off, lowered
    /// BCLM). The fail-safe puts everything back while it exists and no Ashforde app is running, or
    /// when it's older than `staleMinutes` (Monorail re-sends its state every few minutes).
    public static let markerPath = "/var/db/ashforde-charge.held"
    public static let staleMinutes = 10

    public enum Charge: Equatable, Sendable {
        case on, off
        case limit(Int)
    }

    public enum Light: String, Equatable, Sendable {
        case system, green, orange
    }

    public enum Method: String, Equatable, Sendable { case chte, ch0b, bclm, none }
    public enum Adapter: String, Equatable, Sendable { case chie, ch0j, ch0i, none }

    /// The sizes each key must have to count.
    public static let sizes: [String: Int] = ["CHTE": 4, "CH0B": 1, "CH0C": 1, "CHIE": 1, "CH0J": 1, "CH0I": 1, "BCLM": 1, "ACLC": 1]

    /// `size(key)` is the SMC's size for a key, or nil when it has none.
    public static func has(_ key: String, size: (String) -> Int?) -> Bool {
        guard let expected = sizes[key], let actual = size(key) else { return false }
        return actual == expected
    }

    public static func method(size: (String) -> Int?) -> Method {
        if has("CHTE", size: size) { return .chte }
        if has("CH0B", size: size) { return .ch0b }
        if has("BCLM", size: size) { return .bclm }
        return .none
    }

    public static func adapter(size: (String) -> Int?) -> Adapter {
        if has("CHIE", size: size) { return .chie }
        if has("CH0J", size: size) { return .ch0j }
        if has("CH0I", size: size) { return .ch0i }
        return .none
    }

    /// Raw bytes for one key (written as they are, like `smc -w`).
    public struct Write: Equatable, Sendable {
        public var key: String
        public var bytes: [UInt8]
        public init(_ key: String, _ bytes: [UInt8]) {
            self.key = key
            self.bytes = bytes
        }
    }

    public enum PlanError: Error, Equatable {
        /// This Mac has no key for that (69).
        case unsupported
        /// A limit outside 20–100 (64).
        case badValue
    }

    public static func planCharge(_ charge: Charge, method: Method) -> Result<[Write], PlanError> {
        switch (charge, method) {
        case (.on, .chte): return .success([Write("CHTE", [0, 0, 0, 0])])
        case (.off, .chte): return .success([Write("CHTE", [1, 0, 0, 0])])
        case (.on, .ch0b): return .success([Write("CH0B", [0]), Write("CH0C", [0])])
        case (.off, .ch0b): return .success([Write("CH0B", [2]), Write("CH0C", [2])])
        case (.on, .bclm): return .success([Write("BCLM", [100])])
        case (.limit(let n), .bclm):
            guard (20...100).contains(n) else { return .failure(.badValue) }
            return .success([Write("BCLM", [UInt8(n)])])
        case (.on, .none): return .success([])  // Nothing to put back.
        default: return .failure(.unsupported)
        }
    }

    public static func planAdapter(on: Bool, adapter: Adapter) -> Result<[Write], PlanError> {
        switch adapter {
        case .chie: return .success([Write("CHIE", [on ? 0 : 8])])
        case .ch0j: return .success([Write("CH0J", [on ? 0 : 1])])
        case .ch0i: return .success([Write("CH0I", [on ? 0 : 1])])
        case .none: return on ? .success([]) : .failure(.unsupported)
        }
    }

    public static func planLight(_ light: Light, has: Bool) -> Result<[Write], PlanError> {
        guard has else { return light == .system ? .success([]) : .failure(.unsupported) }
        switch light {
        case .system: return .success([Write("ACLC", [0])])
        case .green: return .success([Write("ACLC", [3])])
        case .orange: return .success([Write("ACLC", [4])])
        }
    }

    /// What the keys say now.
    public struct State: Equatable, Sendable {
        public var method: Method
        public var adapter: Adapter
        public var light: Bool
        public var paused: Bool
        public var adapterOff: Bool
        public var limit: Int?
        public init(method: Method, adapter: Adapter, light: Bool, paused: Bool, adapterOff: Bool, limit: Int?) {
            self.method = method
            self.adapter = adapter
            self.light = light
            self.paused = paused
            self.adapterOff = adapterOff
            self.limit = limit
        }

        /// Nothing held back: the marker can go.
        public var isNormal: Bool { !paused && !adapterOff && (limit ?? 100) >= 100 }
    }

    /// Reads the state from raw key bytes (`read(key)` nil when unreadable).
    public static func state(size: (String) -> Int?, read: (String) -> [UInt8]?) -> State {
        let m = method(size: size), a = adapter(size: size)
        var paused = false
        switch m {
        case .chte: paused = read("CHTE")?.first == 1
        case .ch0b: paused = read("CH0B")?.first == 2 || read("CH0C")?.first == 2
        default: break
        }
        var off = false
        switch a {
        case .chie: off = read("CHIE")?.first == 8
        case .ch0j: off = read("CH0J")?.first == 1
        case .ch0i: off = read("CH0I")?.first == 1
        case .none: break
        }
        let limit = m == .bclm ? read("BCLM")?.first.map(Int.init) : nil
        return State(method: m, adapter: a, light: has("ACLC", size: size), paused: paused, adapterOff: off, limit: limit)
    }

    /// The `"charge"` part of `status`: `{"method":"chte","adapter":"chie","led":true,"paused":false,"adapterOff":false,"limit":null,"held":false}`.
    public static func statusJSON(_ s: State, held: Bool) -> String {
        "{\"method\":\"\(s.method.rawValue)\",\"adapter\":\"\(s.adapter.rawValue)\",\"led\":\(s.light),\"paused\":\(s.paused),\"adapterOff\":\(s.adapterOff),\"limit\":\(s.limit.map(String.init) ?? "null"),\"held\":\(held)}"
    }
}
