import XCTest

/// Walks to the scene library the way a person does and photographs it, so the
/// gallery can be looked at rather than only compiled.
///
/// Needs the network: the cards are the live catalogue and their previews.
final class ScenesGalleryTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func save(_ name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let folder = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let url = folder.appendingPathComponent("\(name).png")
        try screenshot.pngRepresentation.write(to: url)
        print("SHOT \(url.path)")

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheGalleryShowsMovingScenes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-welcomeSeen", "YES"]
        app.launch()

        let edit = app.buttons["Edit the spots: change an icon, fill an empty one, choose what it opens"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        app.buttons["Options"].tap()

        // Below the design's own settings, so it can start off the bottom.
        let more = app.buttons["More scenes"]
        var swipes = 0
        while !(more.exists && more.isHittable) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(more.isHittable, "More scenes never scrolled into reach")
        more.tap()

        let card = app.buttons["scene-card-Video Games"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the live catalogue did not list Video Games")

        // Past the first wrap of a short loop (4s once repeated), which is where
        // a preview used to freeze, then each card photographed at uneven gaps:
        // a loop 0.31s long can land on the same frame in two shots a loop
        // apart, so it only counts as frozen if every shot matches.
        Thread.sleep(forTimeInterval: 7)
        for name in ["Video Games", "Spidey Swing"] {
            let scene = app.buttons["scene-card-\(name)"]
            var shots = [scene.screenshot().pngRepresentation]
            for gap in [0.07, 0.19, 0.41] {
                Thread.sleep(forTimeInterval: gap)
                shots.append(scene.screenshot().pngRepresentation)
            }
            XCTAssertGreaterThan(Set(shots).count, 1, "\(name)'s preview is not moving")
        }
        try save("scenes-gallery-a")
        Thread.sleep(forTimeInterval: 0.15)
        try save("scenes-gallery-b")
        // Uneven gaps. A scene whose loop is 0.31s can land on the same frame
        // in two shots taken a loop apart, which reads as frozen when it is not.
        for (index, gap) in [0.07, 0.19, 0.41].enumerated() {
            Thread.sleep(forTimeInterval: gap)
            try save("scenes-burst-\(index + 1)")
        }

        card.tap()
        // Either, depending on whether this simulator already has the scene;
        // checked in a loop because the screen is still pushing after the tap.
        let get = app.buttons["scene-get"]
        let use = app.buttons["scene-use"]
        let deadline = Date().addingTimeInterval(10)
        while !get.exists && !use.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(get.exists || use.exists, "the scene screen offered no action")
        Thread.sleep(forTimeInterval: 3)
        try save("scenes-detail")
    }
}
