import AppKit

/// Apple supplies the Python interpreter used by the bundled local bridge with its developer tools.
@MainActor enum SetupSupport {
    static var toolsAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }
    static func requestToolsInstallation() throws {
        // Show Apple's own confirmation dialog only after a user presses Install.
        let process = Process()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/xcode-select")
        process.arguments = ["--install"]
        try process.run()
    }
}
