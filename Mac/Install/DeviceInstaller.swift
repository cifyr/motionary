import Foundation

enum InstallerError: Error, CustomStringConvertible {
    case toolFailed(tool: String, status: Int32, output: String)
    case noDevice
    case toolMissing(String)

    var description: String {
        switch self {
        case .toolFailed(let tool, let status, let output):
            // The tail rather than the head: xcodebuild's first hundred lines
            // are settings, and the reason it stopped is always at the end.
            let tail = output.split(separator: "\n").suffix(12).joined(separator: "\n")
            return "\(InstallerHint.forOutput(output) ?? "\(tool) exited \(status)")\n\(tail)"
        case .noDevice:
            return "no iPhone is connected and paired; plug it in and trust this Mac"
        case .toolMissing(let tool):
            return "\(tool) is not installed or not on PATH"
        }
    }
}

/// One connected iPhone, as `devicectl` sees it.
struct ConnectedDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let model: String
}

/// Builds the iOS app for a device and installs it.
///
/// A design only reaches the Home Screen by being compiled into the widget
/// extension, so shipping one is a toolchain run rather than a file copy. Each
/// step reports what it is doing and, on failure, what the tool actually said -
/// a build that stops with a spinner and no reason is the thing this replaces.
struct DeviceInstaller {
    let projectRoot: URL

    private static let bundleID = "com.caden.Motionary"

    @discardableResult
    private func run(
        _ launchPath: String,
        _ arguments: [String],
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = projectRoot

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw InstallerError.toolMissing("\(launchPath) \(arguments.first ?? "")")
        }

        // Drained while it runs: xcodebuild produces more than a pipe buffer
        // holds, and waiting first deadlocks once it fills.
        var output = ""
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            let text = String(decoding: chunk, as: UTF8.self)
            output += text
            if let progress {
                for line in text.split(separator: "\n") where !line.isEmpty {
                    progress(String(line))
                }
            }
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw InstallerError.toolFailed(
                tool: (arguments.first ?? launchPath),
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }

    func connectedDevices() throws -> [ConnectedDevice] {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motionary-devices.json")
        try run("/usr/bin/xcrun", [
            "devicectl", "list", "devices", "--json-output", output.path,
        ])
        guard let data = try? Data(contentsOf: output),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else { return [] }

        return devices.compactMap { device in
            guard let properties = device["hardwareProperties"] as? [String: Any],
                  let udid = properties["udid"] as? String,
                  let platform = properties["platform"] as? String, platform == "iOS"
            else { return nil }
            let name = (device["deviceProperties"] as? [String: Any])?["name"] as? String
            return ConnectedDevice(
                id: udid,
                name: name ?? "iPhone",
                model: properties["marketingName"] as? String ?? ""
            )
        }
    }

    /// Homebrew's own bin dir, on either architecture. A shell inherits this
    /// through its profile, but a Finder/Dock launch does not - `env` then
    /// fails to find `xcodegen` even though a Terminal-launched run just did.
    private static let xcodegenFallbackPaths = [
        "/opt/homebrew/bin/xcodegen",
        "/usr/local/bin/xcodegen",
    ]

    private func xcodegenCommand() -> String {
        Self.xcodegenFallbackPaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "xcodegen"
    }

    /// The project file lists the design's fonts by name, so it has to be
    /// regenerated whenever they change - otherwise the next build, by anyone
    /// and from anywhere, fails on the previous design's filenames.
    func regenerateProject(progress: @escaping @Sendable (String) -> Void) throws {
        progress("Regenerating the project")
        try run("/usr/bin/env", [xcodegenCommand(), "generate"])
    }

    private func installBundle(deviceID: String) throws {
        try run("/usr/bin/xcrun", [
            "devicectl", "device", "install", "app",
            "--device", deviceID,
            "build/device/Build/Products/Debug-iphoneos/Motionary.app",
        ])
    }

    /// Builds for the device, installs, and launches. Returns a warning when
    /// the design landed but something after that did not.
    @discardableResult
    func installAndLaunch(
        deviceID: String,
        progress: @escaping @Sendable (String) -> Void
    ) throws -> String? {
        progress("Building for the device")
        try run("/usr/bin/xcrun", [
            "xcodebuild",
            "-project", "Motionary.xcodeproj",
            "-scheme", "Motionary",
            "-destination", "platform=iOS,id=\(deviceID)",
            "-derivedDataPath", "build/device",
            "-allowProvisioningUpdates",
            "build",
        ]) { line in
            // Roughly one useful line per phase; the rest is compiler noise.
            if line.hasPrefix("Compiling") || line.hasPrefix("Signing") || line.hasPrefix("Touching") {
                progress(String(line.prefix(90)))
            }
        }

        progress("Installing")
        do {
            try installBundle(deviceID: deviceID)
        } catch InstallerError.toolFailed(let tool, let status, let output)
                    where InstallerHint.isStalePluginInstall(output) {
            // The phone will not make the widget a container while the copy
            // already on it owns one, and says so as a signature failure on the
            // extension. Deleting that copy is the whole fix, and there is
            // nothing on the phone worth keeping - every design it holds was
            // compiled in from here.
            progress("Removing the copy already on the phone")
            do {
                try run("/usr/bin/xcrun", [
                    "devicectl", "device", "uninstall", "app",
                    "--device", deviceID, Self.bundleID,
                ])
            } catch {
                // Report the install that actually failed, not the cleanup.
                throw InstallerError.toolFailed(tool: tool, status: status, output: output)
            }
            progress("Installing again")
            try installBundle(deviceID: deviceID)
        }

        progress("Launching")
        // Not fatal. The design is already installed by this point, and a
        // locked phone refuses to open anything - reporting that as a failed
        // build would be wrong about the one thing that mattered.
        //
        // Both labs are sticky, living in the app group's defaults, so the
        // launch is also what puts a studio install back on the design it just
        // built rather than on whatever was last being diagnosed.
        do {
            try run("/usr/bin/xcrun", [
                "devicectl", "device", "process", "launch",
                "--device", deviceID,
                Self.bundleID,
                "--", "-MotionaryFontLabOff", "-MotionaryEdgeLabOff",
            ])
            return nil
        } catch {
            let locked = "\(error)".contains("Locked") || "\(error)".contains("not be, unlocked")
            return locked
                ? "Installed, but the phone was locked so the app could not be opened. Unlock it and open Motionary once."
                : "Installed, but the app would not launch: \(error)"
        }
    }
}
