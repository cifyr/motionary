import Foundation

/// A job that takes long enough to need a screen of its own, and the steps it
/// goes through.
///
/// Without one, anything in flight fell through to the workspace — so pressing
/// Install all put you on a page inviting you to drop a clip, with a progress
/// bar underneath it and every control greyed out. The work was running fine;
/// the screen was describing a different job entirely.
///
/// Kept clear of `StudioPipeline.Stage` on purpose. The mapping between them is
/// the part that can be wrong, and a plan that names its own phases is plain
/// Foundation, so it can be covered by the unit suite the way `BundleWriter`
/// is — the studio itself cannot.
enum StudioRun: Equatable {
    case opening(String)
    case building(String)
    case installing(count: Int)

    /// What the work is doing, in this screen's own words.
    enum Phase: Equatable {
        case reading
        case rendering
        case bundling
        case installing(String)
    }

    var title: String {
        switch self {
        case .opening(let name): "Opening \(name)"
        case .building(let name): "Building \(name)"
        case .installing(let count): "Installing \(count) design\(count == 1 ? "" : "s")"
        }
    }

    var subtitle: String {
        switch self {
        case .opening:
            "Reading the clip and its layout."
        case .building:
            "The clip becomes fonts, the fonts go into the app, and the app goes onto the phone. A widget can only draw a font that was in its bundle when it was installed, which is why every design needs a compile."
        case .installing:
            "Every starred design is compiled into the app, then the app is rebuilt and installed. Nothing on the phone changes until the install finishes."
        }
    }

    /// The steps, in the order they happen. Written as what is being done
    /// rather than as stage names, because this is the one place somebody
    /// watching a four-minute build finds out what it is spending them on.
    var steps: [String] {
        switch self {
        case .opening:
            ["Read the clip"]
        case .building:
            ["Read the clip", "Render the frames into fonts", "Add the fonts to the app", "Install on the phone"]
        case .installing:
            ["Add the fonts to the app", "Regenerate the Xcode project", "Install on the phone"]
        }
    }

    /// Which step a phase belongs to. The runs pass through the same phases in
    /// different amounts — Install all renders nothing — so this is per run
    /// rather than a property of the phase.
    func step(for phase: Phase) -> Int {
        switch self {
        case .opening:
            0
        case .building:
            switch phase {
            case .reading: 0
            case .rendering: 1
            case .bundling: 2
            case .installing: 3
            }
        case .installing:
            switch phase {
            case .reading, .rendering, .bundling: 0
            case .installing(let step): step.localizedCaseInsensitiveContains("project") ? 1 : 2
            }
        }
    }
}
