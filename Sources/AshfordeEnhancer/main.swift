#if os(macOS)
import AppKit
import EnhancerCore
import SwiftUI

/// Ashforde Enhancer: one setup so lid-closed mode in Ashforde's apps (Glance and Keeper from the
/// App Store, and the downloaded Monorail and Keeper) no longer asks for the password every time.
///
///     AshfordeEnhancer                  opens the window
///     AshfordeEnhancer status           one line of JSON (same shape as ashforde-lid.sh status)
///     AshfordeEnhancer install          asks for the administrator's password once, then sets everything up
///     AshfordeEnhancer uninstall        removes everything and turns sleep back on
///     AshfordeEnhancer version
enum Setup {
    struct Status: Equatable {
        var rule = false
        var failsafe = false
        var sleepDisabled = false
        var scripts: [String] = []

        var installed: Bool { rule && failsafe }

        var json: String {
            let list = scripts.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"enhancer\":\(Enhancer.interfaceVersion),\"version\":\"\(Enhancer.version)\",\"rule\":\(rule),\"failsafe\":\(failsafe),\"sleepDisabled\":\(sleepDisabled),\"scripts\":[\(list)]}"
        }
    }

    static var scriptsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Scripts", isDirectory: true)
    }

    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func status() -> Status {
        var status = Status()
        status.rule = run("/usr/bin/sudo", ["-n", "-l", Enhancer.pmset, "-a", "disablesleep", "1"]).status == 0
        status.failsafe = FileManager.default.fileExists(atPath: Enhancer.daemonPlistPath)
        status.sleepDisabled = Enhancer.sleepDisabled(pmsetOutput: run(Enhancer.pmset, ["-g"]).output)
        status.scripts = Enhancer.clients.filter {
            FileManager.default.isExecutableFile(atPath: scriptsRoot.appendingPathComponent("\($0)/\(Enhancer.lidScriptName)").path)
        }
        return status
    }

    /// The lid script into each app's scripts folder. The folder is the user's own, so no password.
    static func installScripts() throws {
        let fm = FileManager.default
        for client in Enhancer.clients {
            let folder = scriptsRoot.appendingPathComponent(client, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(Enhancer.lidScriptName)
            try Enhancer.lidScript().write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    static func removeScripts() {
        for client in Enhancer.clients {
            try? FileManager.default.removeItem(at: scriptsRoot.appendingPathComponent("\(client)/\(Enhancer.lidScriptName)"))
        }
    }

    enum Failure: LocalizedError {
        case user, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .user: return "This account's name can't go in a sudo rule."
            case .cancelled: return "Cancelled."
            case .failed(let why): return why
            }
        }
    }

    /// Runs a root shell script after the administrator's password (or Touch ID).
    static func asAdministrator(_ script: String) throws {
        let source = "do shell script \(Enhancer.appleScriptQuoted(script)) with administrator privileges"
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: source) else { throw Failure.failed("Couldn't prepare the setup.") }
        apple.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
            throw Failure.failed(error[NSAppleScript.errorMessage] as? String ?? "The setup didn't finish.")
        }
    }

    /// Writes the three files into `stage` (a folder only this user can write) and returns the root script.
    static func stage(_ stage: URL) throws -> String {
        let user = NSUserName()
        guard let rule = Enhancer.sudoersRule(user: user) else { throw Failure.user }
        try rule.write(to: stage.appendingPathComponent("rule"), atomically: true, encoding: .utf8)
        try Enhancer.failsafeScript().write(to: stage.appendingPathComponent("failsafe"), atomically: true, encoding: .utf8)
        try Enhancer.daemonPlist().write(to: stage.appendingPathComponent("daemon.plist"), atomically: true, encoding: .utf8)
        guard let script = Enhancer.installScript(user: user, stage: stage.path) else { throw Failure.user }
        return script
    }

    static func install() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ashforde-enhancer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        try asAdministrator(try stage(folder))
        try installScripts()
    }

    static func uninstall() throws {
        try asAdministrator(Enhancer.uninstallScript())
        removeScripts()
    }
}

// MARK: - Command line

let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, !command.hasPrefix("-psn") {
    switch command {
    case "status": print(Setup.status().json)
    case "version": print(Enhancer.version)
    case "stage" where arguments.count == 2:
        // For CI: stage the files and print the root script, so a test can run it with sudo.
        do {
            print(try Setup.stage(URL(fileURLWithPath: arguments[1], isDirectory: true)))
            try Setup.installScripts()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    case "print-uninstall": print(Enhancer.uninstallScript())
    case "install", "uninstall":
        do {
            try command == "install" ? Setup.install() : Setup.uninstall()
            print(Setup.status().json)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    default:
        FileHandle.standardError.write(Data("usage: AshfordeEnhancer [status|install|uninstall|version]\n".utf8))
        exit(64)
    }
    exit(0)
}

// MARK: - The window

final class Model: ObservableObject {
    @Published var status = Setup.status()
    @Published var busy = false
    @Published var message: String?
    /// The app that sent the person here (ashforde-enhancer://install?from=<bundle id>).
    @Published var from: String?

    func refresh() { status = Setup.status() }

    func perform(_ install: Bool) {
        busy = true
        message = nil
        DispatchQueue.main.async {
            do {
                try install ? Setup.install() : Setup.uninstall()
                self.message = install ? "Done. Lid-closed mode won't ask for your password any more." : "Removed. Sleep works as usual again."
            } catch Setup.Failure.cancelled {
            } catch {
                self.message = error.localizedDescription
            }
            self.busy = false
            self.refresh()
        }
    }
}

struct EnhancerView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ashforde Enhancer").font(.system(size: 20, weight: .bold))
                    Text("Lid-closed mode without the password, for Monorail, Glance and Keeper.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let from = model.from { Text("Opened from \(from).").font(.system(size: 11)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) {
                row("Permission to turn sleep off and on", model.status.rule,
                    "Only `pmset -a disablesleep 0` and `1`, only for you. Nothing else runs without your password.")
                row("Fail-safe", model.status.failsafe,
                    "Once a minute: if sleep is off and none of Ashforde's apps is running, sleep goes back on.")
                row("Ready in your apps", !model.status.scripts.isEmpty,
                    model.status.scripts.isEmpty ? "Not set up yet." : "Set up for \(model.status.scripts.count) Ashforde apps.")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            if let message = model.message { Text(message).font(.system(size: 12)) }
            HStack {
                if model.status.installed {
                    Button("Remove…") { model.perform(false) }.disabled(model.busy)
                    Spacer()
                    Button("Set Up Again") { model.perform(true) }.disabled(model.busy)
                } else {
                    Spacer()
                    Button("Set Up…") { model.perform(true) }.keyboardShortcut(.defaultAction).disabled(model.busy)
                }
            }
            Text("Your Mac asks for your password once to set this up. Version \(Enhancer.version).")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(width: 460)
    }

    private func row(_ title: String, _ ok: Bool, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(open(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Ashforde Enhancer"
        window.contentView = NSHostingView(rootView: EnhancerView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) { model.refresh() }

    /// ashforde-enhancer://install?from=<bundle id> (or ://open): show the window, ready to set up.
    @objc func open(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let parts = URLComponents(string: text)
        else { return }
        model.from = parts.queryItems?.first { $0.name == "from" }?.value
        model.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
#else
import EnhancerCore
print("Ashforde Enhancer \(Enhancer.version) runs on macOS.")
#endif
