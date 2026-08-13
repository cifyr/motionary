import Foundation

/// Reads a failed toolchain run and says what to do about it.
///
/// The failures that stop an install are mostly nothing to do with the project,
/// and the tools bury them: a locked phone times out after two minutes and
/// comes back as "xcodebuild exited 70" under a wall of build settings, which
/// reads as a broken build rather than a phone that wants a thumb on it.
///
/// Its own file, and no `Process` in it, so the rules can be tested - the
/// installer around them cannot be, because it shells out.
enum InstallerHint {
    /// What to do about this output, or nil when the tool's failure is the
    /// project's own problem and should be shown as it is.
    static func forOutput(_ output: String) -> String? {
        // Before the profile rule below: this failure also says "provisioning
        // profile", but it is not about signing - the profile is fine and the
        // phone is refusing to hand the widget a container.
        if isStalePluginInstall(output) {
            return "The iPhone would not give the widget a container. Delete Motionary from the phone and run this again."
        }
        // A free account's signing certificate is reissued every seven days,
        // and each new one has to be trusted on the phone by hand before
        // anything signed with it will open.
        if output.contains("has not been explicitly trusted by the user") {
            return "The iPhone does not trust this certificate yet. On the phone: Settings > General > VPN & Device Management > Developer App, then trust it and run this again."
        }
        // Order matters: a locked phone also reports a timeout, and being told
        // to unlock it is more use than being told it did not answer.
        if output.contains("may need to be unlocked") || output.contains("Device is locked") {
            return "Unlock the iPhone and run this again - it has to be awake to accept a build."
        }
        if output.contains("Timed out waiting for all destinations") {
            return "The iPhone did not answer in time. Unlock it, check the cable or Wi-Fi, and run this again."
        }
        if output.contains("Unable to find a destination matching") {
            return "That iPhone is no longer connected. Plug it in, or bring it onto the same network."
        }
        if output.contains("requires a provisioning profile") || output.contains("No profiles for") {
            return "Xcode could not make a provisioning profile. Open the project in Xcode once and let it sign."
        }
        return nil
    }

    /// Whether the phone refused the widget's container because a copy of the
    /// app is already installed. It reports itself as a signature failure on
    /// the extension - "A valid provisioning profile for this executable was
    /// not found" - even though the profile is current and the same one the
    /// app itself was just accepted with; deleting the installed copy clears
    /// it. The installer retries on this rather than only explaining it.
    static func isStalePluginInstall(_ output: String) -> Bool {
        output.contains("Failed to create plugin data containers")
    }
}
