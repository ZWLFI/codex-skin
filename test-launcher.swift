import AppKit
import Foundation

@main
struct LauncherTest {
    static let fixtureID = "com.local.codex-skin.launcher-fixture"

    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(condition(), "Launcher timed out")
    }

    static func main() throws {
        if Bundle.main.bundleIdentifier == fixtureID {
            precondition(CommandLine.arguments.contains("--remote-debugging-port=9342"))
            precondition(CommandLine.arguments.contains("--remote-debugging-address=127.0.0.1"))
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("codex-skin-launch-test-\(UUID())")
        let fixture = directory.appendingPathComponent("Fixture.app")
        let contents = fixture.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer {
            NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).forEach { _ = $0.terminate() }
            try? fm.removeItem(at: directory)
        }
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: contents.appendingPathComponent("MacOS/Fixture"))
        let plist: [String: Any] = ["CFBundleIdentifier": fixtureID, "CFBundleExecutable": "Fixture", "CFBundleName": "Skin launcher test", "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        func launch() throws -> NSRunningApplication {
            var outcome: Result<Void, Error>?
            CodexLauncher.restartWithDebugPort(applicationURL: fixture) { outcome = $0 }
            wait { outcome != nil }
            try outcome!.get()
            wait { NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).contains { $0.isFinishedLaunching } }
            return NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).first!
        }
        precondition(NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).isEmpty)
        let first = try launch()
        let second = try launch()
        precondition(first.isTerminated && first.processIdentifier != second.processIdentifier)
        _ = second.terminate()
        wait { second.isTerminated }
        let third = try launch()
        precondition(!third.isTerminated)
        _ = third.terminate()
        wait { third.isTerminated }
        print("launcher test passed: cold start, running-app restart, start after quit; debug arguments checked")
    }
}
