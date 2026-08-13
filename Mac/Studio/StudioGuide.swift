import SwiftUI

/// Where the tutorial lives.
///
/// Three surfaces, because they answer three different questions and one
/// surface cannot: the welcome window answers "what is this and where do I
/// start" on the first launch only; the empty states answer "what do I do on
/// this screen" in place, at the moment it matters; and the guide answers "how
/// does the rest of it work" for the parts that happen on the phone, which is
/// where this is easiest to get wrong and hardest to discover.
enum StudioHelp {
    static let welcomeWindow = "welcome"
    static let guideWindow = "guide"
    /// Set once the welcome window has been shown, so it is a greeting rather
    /// than a thing to dismiss on every launch.
    static let seenWelcomeKey = "hasSeenWelcome"

    static let repository = URL(string: "https://github.com/cifyr/motionary")!
    static let installDoc = URL(string: "https://github.com/cifyr/motionary/blob/main/docs/INSTALL.md")!
    static let usageDoc = URL(string: "https://github.com/cifyr/motionary/blob/main/docs/USAGE.md")!
}

/// The first launch.
///
/// Three steps, because there are exactly three, and the last one is the one
/// people miss: a design is only half the picture until the wallpaper is set
/// behind it.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage(StudioHelp.seenWelcomeKey) private var seenWelcome = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                Text("Motionary Studio")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(StudioTheme.textBright)
                Text("Turn a video clip into an animated Home Screen.")
                    .font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .padding(.top, 34)
            .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 18) {
                step(
                    1, "film",
                    "Drop in a clip",
                    "Position it on the phone. What lands inside the dashed frame animates; the rest becomes wallpaper."
                )
                step(
                    2, "square.grid.2x2",
                    "Place your apps",
                    "Tiles sit over the animation and stay tappable. They snap to the real Home Screen grid."
                )
                step(
                    3, "iphone",
                    "Build to your phone",
                    "Studio compiles the clip into fonts, installs the app, then hands you the wallpaper to set behind it."
                )
            }
            .padding(.horizontal, 34)

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Button("Open the guide") {
                    openWindow(id: StudioHelp.guideWindow)
                }
                .buttonStyle(.studio)

                Spacer()

                Button("Start with a starter") {
                    seenWelcome = true
                    dismiss()
                }
                .buttonStyle(.studioProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 26)
        }
        .frame(width: 520, height: 412)
        .background(StudioTheme.panel)
        .tint(StudioTheme.accent)
        .onAppear { seenWelcome = true }
    }

    private func step(_ number: Int, _ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // The number carries real order - these steps only work in this
            // sequence - so it is information rather than decoration.
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioTheme.onAccent)
                .frame(width: 22, height: 22)
                .background(StudioTheme.accent, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textBright)
                    .labelStyle(.titleOnly)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The whole workflow, including the parts that happen away from the Mac.
struct GuideView: View {
    @State private var chapter: Chapter = .making

    enum Chapter: String, CaseIterable, Identifiable {
        case making = "Making a design"
        case building = "Building to your phone"
        case wallpaper = "Setting the wallpaper"
        case widget = "Placing the widget"
        case trouble = "When it looks wrong"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .making: "wand.and.stars"
            case .building: "hammer"
            case .wallpaper: "photo"
            case .widget: "square.dashed"
            case .trouble: "stethoscope"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Chapter.allCases, selection: $chapter) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(chapter.rawValue)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(StudioTheme.textBright)
                    body(for: chapter)
                    if chapter == .trouble {
                        Divider().padding(.vertical, 4)
                        Link("Full troubleshooting in the docs", destination: StudioHelp.usageDoc)
                            .font(.system(size: 11.5))
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(28)
            }
            .background(StudioTheme.libraryBackground)
        }
        .frame(minWidth: 720, minHeight: 480)
        .tint(StudioTheme.accent)
    }

    @ViewBuilder
    private func body(for chapter: Chapter) -> some View {
        switch chapter {
        case .making:
            paragraphs([
                "Drop a clip onto the library, or duplicate a starter and change it. MP4, MOV and GIF all work.",
                "Position the clip on the phone-shaped canvas. The dashed rectangle is the widget: whatever lands inside it animates and answers taps, and whatever falls outside becomes the wallpaper behind it. The two are cut from one picture, which is what makes the animation look like it fills the screen.",
                "Place app tiles wherever you want launchers. They are drawn live over the animation rather than baked into it, so they stay sharp, stay tappable, and can be changed later without rebuilding.",
                "Short, looping clips work best. The animation cycle is 30 seconds, and a loop that divides it evenly is seamless — Studio snaps to the nearest clean length and says so.",
            ])
        case .building:
            paragraphs([
                "Building compiles the clip into fonts and puts them inside the app, because a widget can only draw a font that was in its bundle when it was installed. That is also why adding a design means installing again.",
                "Star the designs you want on the phone. Starred designs are the ones compiled in, and the phone switches between them. Each costs about 29MB, and the extension has a ceiling of roughly 45MB at render time, so a handful is the practical limit.",
                "Connect the iPhone by cable, pick it in the device menu, and build. Studio regenerates the Xcode project, builds, installs and launches it.",
            ])
        case .wallpaper:
            paragraphs([
                "This is the step that makes the illusion work, and the easiest one to skip.",
                "Open Motionary on the phone and tap the save button. It writes the wallpaper to Photos.",
                "Set it in Settings → Wallpaper → Add New Wallpaper → Photos. Turn off zoom and parallax: the composition is cut to exact pixels, and any crop shifts it out of line with the widget.",
            ])
        case .widget:
            paragraphs([
                "Long-press the Home Screen, choose Edit, then Add Widget, and pick Motionary at the full-screen portrait size.",
                "The widget has to sit in the slot the design was cut for — the top one. The widget's picture and the wallpaper behind it are two halves of the same image, so a widget in the wrong place shows a seam.",
            ])
        case .trouble:
            paragraphs([
                "A black widget is almost always the fonts. They only draw if they were bundled at install time, so regenerate the project, build and install again.",
                "A seam between the widget and the wallpaper is geometry: check that zoom and parallax are off, that the widget is in the right slot, and that the design was cut for the phone you are using. Only the iPhone 17 Pro is calibrated.",
                "An animation that jumps every 30 seconds has a loop that does not divide the cycle. Rebuild it at a length Studio suggests.",
            ])
        }
    }

    private func paragraphs(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }
}

/// The menu bar.
///
/// An app without one is the clearest sign it is not really a Mac app. These
/// are only the commands that mean something here — inventing a full File menu
/// for a tool with no documents would be worse than having none.
struct StudioCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Design from Clip…") {
                NotificationCenter.default.post(name: .studioNewDesign, object: nil)
            }
            .keyboardShortcut("n")
        }

        CommandGroup(replacing: .help) {
            Button("Motionary Studio Guide") { openWindow(id: StudioHelp.guideWindow) }
                .keyboardShortcut("?", modifiers: [.command])
            Button("Welcome to Motionary Studio") { openWindow(id: StudioHelp.welcomeWindow) }
            Divider()
            Link("Installing and Signing", destination: StudioHelp.installDoc)
            Link("Usage and Troubleshooting", destination: StudioHelp.usageDoc)
            Link("Motionary on GitHub", destination: StudioHelp.repository)
        }
    }
}

extension Notification.Name {
    /// Posted by the New menu item. A notification rather than shared state
    /// because the command lives in the scene and the file picker lives in the
    /// view, and this is the narrowest thing that joins them.
    static let studioNewDesign = Notification.Name("StudioNewDesign")

    /// Asks whatever is in the detail pane to stand down and show the library.
    ///
    /// A notification rather than clearing the state directly, because the
    /// editor holds its own working copy of the design: anything that reached
    /// past it to put the pane back would write the copy the editor started
    /// from, over the newer one its autosave had already stored.
    static let studioGoHome = Notification.Name("StudioGoHome")
}
