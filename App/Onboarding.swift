import SwiftUI
import os

/// What a new phone is told, and whether it has been told yet.
///
/// The app is a window onto a Home Screen, and the Home Screen only looks
/// right after three things happen outside the app: the wallpaper is set, the
/// widget is placed, and zoom is turned off. None of that can be done for the
/// person, so the first launch says it once, and the guide keeps saying it for
/// as long as anyone wants to read it again.
enum Onboarding {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "Onboarding")

    static let welcomeSeenKey = "welcomeSeen"

    /// The app's own defaults rather than the group's: the widget has no use
    /// for this, and keeping it out of the group keeps the group about designs.
    static func needsWelcome(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: welcomeSeenKey)
    }

    static func markWelcomeSeen(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: welcomeSeenKey)
        logger.info("welcome seen")
    }

    /// The way back for someone who skipped it, from the options sheet.
    static func resetWelcome(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: welcomeSeenKey)
        logger.info("welcome reset")
    }
}

/// The steps between installing the app and a Home Screen that moves, in the
/// order they have to happen. One list, read by the welcome and by the guide,
/// so the two cannot drift apart.
enum SetupGuide {
    struct Step: Identifiable, Equatable, Sendable {
        let id: String
        let symbol: String
        let title: String
        let body: String
    }

    static let steps: [Step] = [
        Step(
            id: "welcome",
            symbol: "sparkles",
            title: "Your Home Screen, moving",
            body: """
            A Motionary design is a widget that plays and a wallpaper that \
            carries the rest of the picture. Set up together, they read as one \
            scene that fills the whole phone.
            """
        ),
        Step(
            id: "save",
            symbol: "square.and.arrow.down",
            title: "Save the wallpaper",
            body: """
            Swipe sideways to pick a design, then tap the save button in the \
            corner. Motionary asks once to add pictures to Photos - that is \
            the only permission it needs.
            """
        ),
        Step(
            id: "wallpaper",
            symbol: "photo.on.rectangle.angled",
            title: "Set it as your wallpaper",
            body: """
            In Settings, open Wallpaper and add a new one from Photos. Set it \
            for the Home Screen, and turn off Perspective Zoom so the picture \
            stays exactly where the widget expects it.
            """
        ),
        Step(
            id: "widget",
            symbol: "rectangle.portrait.on.rectangle.portrait.angled",
            title: "Place the widget",
            body: """
            Touch and hold the Home Screen, tap Edit, then Add Widget. Choose \
            Motionary and drop the tall widget at the top of a page - it lines \
            up with the wallpaper underneath it.
            """
        ),
        Step(
            id: "spots",
            symbol: "square.grid.2x2",
            title: "Make it yours",
            body: """
            Tap the grid button to change what each spot opens - the app, its \
            icon, or a link. Swipe between designs any time; the widget \
            follows whatever the app is showing.
            """
        ),
    ]

    /// The things that surprise people after the setup is done. Kept apart
    /// from the steps because they are not steps: nothing here has to happen.
    static let notes: [Step] = [
        Step(
            id: "hop",
            symbol: "arrow.up.forward.app",
            title: "Tapping an icon passes through Motionary",
            body: """
            A widget cannot open another app on its own, so every tap opens \
            Motionary for a moment and Motionary opens the app. That flash is \
            how it works, not something going wrong.
            """
        ),
        Step(
            id: "loop",
            symbol: "clock.arrow.2.circlepath",
            title: "The animation keeps time with the clock",
            body: """
            The widget and the app both play from the wall clock, so opening \
            the app continues the loop rather than restarting it. A short \
            pause every so often is the loop wrapping around.
            """
        ),
        Step(
            id: "mac",
            symbol: "desktopcomputer",
            title: "New designs come from a Mac",
            body: """
            Designs are made in Motionary Studio on macOS and sent to the phone \
            over the local network, or opened from a .motionary file. The \
            designs built into this app are ready to use as they are.
            """
        ),
    ]
}

// MARK: - Welcome

/// The first-launch walkthrough: the guide's steps, one per page.
struct WelcomeView: View {
    let onFinish: () -> Void

    @State private var page = 0
    private let steps = SetupGuide.steps

    var body: some View {
        ZStack {
            Color.emberDark.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Motionary").emberLabel()
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.callout)
                        .foregroundStyle(Color.emberSubtitle)
                        .accessibilityLabel("Skip the welcome")
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)

                TabView(selection: $page) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { position, step in
                        WelcomePage(step: step, number: position + 1)
                            .tag(position)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                PageMarks(count: steps.count, index: page)
                    .padding(.bottom, 24)

                Button(action: advance) {
                    Text(isLast ? "Get started" : "Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.emberAccent)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: page)
    }

    private var isLast: Bool { page == steps.count - 1 }

    private func advance() {
        if isLast {
            finish()
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
        }
    }

    private func finish() {
        Onboarding.markWelcomeSeen()
        onFinish()
    }
}

private struct WelcomePage: View {
    let step: SetupGuide.Step
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: step.symbol)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Color.emberAccent)
                .frame(height: 72)
                .accessibilityHidden(true)
            Text("Step \(number)")
                .emberLabel()
                .padding(.top, 28)
            // Tight and heavy, the display end of the scheme's ladder as
            // closely as the system face reaches - the same setting as the
            // empty state, so the welcome and the app read as one thing.
            Text(step.title)
                .font(.system(size: 34, weight: .black))
                .tracking(-0.6)
                .foregroundStyle(Color.emberTitle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Rectangle()
                .fill(Color.emberLine)
                .frame(width: 120, height: 1)
                .padding(.vertical, 18)
            Text(step.body)
                .font(.system(size: 17))
                .lineSpacing(4)
                .foregroundStyle(Color.emberSubtitle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
    }
}

/// Which page is showing. Square marks rather than dots: the scheme has no
/// radius between none and a full pill, and the home screen's dots already
/// mean "which design".
private struct PageMarks: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { position in
                Rectangle()
                    .fill(position == index ? Color.emberAccent : Color.emberLine)
                    .frame(width: position == index ? 22 : 8, height: 3)
                    .animation(.easeInOut(duration: 0.2), value: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1) of \(count)")
    }
}

// MARK: - Guide

/// The same steps as a page to come back to, with the notes under them.
struct SetupGuideView: View {
    var body: some View {
        List {
            Section {
                ForEach(Array(SetupGuide.steps.enumerated()), id: \.element.id) { position, step in
                    GuideRow(step: step, mark: "\(position + 1)")
                }
            } header: {
                Text("Setting up").emberLabel()
            }

            Section {
                ForEach(SetupGuide.notes) { note in
                    GuideRow(step: note, mark: nil)
                }
            } header: {
                Text("Good to know").emberLabel()
            }
        }
        .navigationTitle("How to set it up")
        .navigationBarTitleDisplayMode(.inline)
        .emberSheet()
    }
}

private struct GuideRow: View {
    let step: SetupGuide.Step
    /// A number for a step, nothing for a note.
    let mark: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let mark {
                    Text(mark)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.emberAccent)
                } else {
                    Image(systemName: step.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.emberAccent)
                        .frame(width: 26, height: 26)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.emberTitle)
                Text(step.body)
                    .font(.subheadline)
                    .foregroundStyle(Color.emberSubtitle)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - About

/// Version, credit, and the two things a store listing has to be able to point
/// at from inside the app: how it treats data, and who to write to.
struct AboutView: View {
    static let supportAddress = "caden@cadenwarren.com"
    /// `site/`, on Vercel. The store listing points at the same two pages.
    static let siteURL = URL(string: "https://motionary-app.vercel.app")!

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("iPhone / WidgetKit").emberLabel()
                    Text("MOTIONARY")
                        .font(.system(size: 32, weight: .black))
                        .tracking(-0.6)
                        .foregroundStyle(Color.emberTitle)
                    Text("Animated Home Screen widgets, with your apps on them.")
                        .font(.subheadline)
                        .foregroundStyle(Color.emberSubtitle)
                    Text("Version \(version)")
                        .font(.footnote)
                        .foregroundStyle(Color.emberDesc)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("""
                Motionary has no account, no analytics and no advertising. \
                Nothing about you or your phone is collected or sent anywhere.

                Photos is asked for add-only access, so the wallpaper can be \
                saved for you to set. Local network access is asked for only \
                when a design is being sent from Motionary Studio on a Mac.

                Searching for an icon sends the words you type to Iconify's \
                public API and nothing else; the icons it returns are kept on \
                the phone so the widget never touches the network.
                """)
                .font(.subheadline)
                .foregroundStyle(Color.emberSubtitle)
            } header: {
                Text("Privacy").emberLabel()
            }

            Section {
                Text("""
                The timer-font animation technique originates with Bryce \
                Bostwick's WidgetAnimation, published under the MIT licence; \
                the shaping template here derives from it.

                Icons are searched through Iconify, which gathers open-source \
                icon sets under their own licences. Third-party app names and \
                marks remain the property of their owners.
                """)
                .font(.subheadline)
                .foregroundStyle(Color.emberSubtitle)
            } header: {
                Text("Acknowledgements").emberLabel()
            }

            Section {
                Link(destination: Self.siteURL) {
                    Label("Setup help online", systemImage: "questionmark.circle")
                }
                Link(destination: Self.siteURL.appendingPathComponent("privacy")) {
                    Label("Privacy policy", systemImage: "hand.raised")
                }
                if let subject = "Motionary \(version)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "mailto:\(Self.supportAddress)?subject=\(subject)") {
                    Link(destination: url) {
                        Label("Write to the developer", systemImage: "envelope")
                    }
                }
            } header: {
                Text("Support").emberLabel()
            } footer: {
                Text("Questions, a design that will not line up, or a phone that is not on the list yet.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .emberSheet()
    }
}
