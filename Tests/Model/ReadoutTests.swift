import CoreGraphics
import XCTest

/// A readout says something about right now, on top of an animation that is
/// frozen and never reloads. What matters is which sources force a reload and
/// which do not, because the widget's reload budget is small and the animation
/// depends on not spending it.
final class ReadoutTests: XCTestCase {
    private func readout(_ source: PlacedReadout.Source) -> PlacedReadout {
        PlacedReadout(source: source, center: CGPoint(x: 100, y: 200))
    }

    /// The three that draw themselves from the clock. If any of these ever asks
    /// for an interval, a design of nothing but a countdown starts spending
    /// reloads it does not need.
    func testTheClockSourcesNeedNoReload() {
        for source in [PlacedReadout.Source.time, .date, .countdown] {
            XCTAssertEqual(source.refresh, .wallClock, "\(source.title) should draw itself")
            XCTAssertNil(source.refresh.seconds, "\(source.title) must not ask for an interval")
        }
    }

    func testTheGatheredSourcesAskForAnInterval() {
        XCTAssertEqual(PlacedReadout.Source.weather.refresh, .interval(30 * 60))
        XCTAssertEqual(PlacedReadout.Source.steps.refresh, .interval(60 * 60))
        XCTAssertEqual(PlacedReadout.Source.calendar.refresh, .interval(60 * 60))
        XCTAssertEqual(PlacedReadout.Source.battery.refresh, .onUnlock)
    }

    /// The whole point of asking per element: a design that only counts down
    /// keeps the never-reload behaviour the animation was built on.
    func testADesignOfClockSourcesAsksForNothing() {
        let design = [readout(.countdown), readout(.time), readout(.date)]
        XCTAssertNil(design.soonestRefresh)
    }

    /// One expensive readout sets the pace for the widget, so the soonest wins.
    func testTheSoonestCadenceWins() {
        let design = [readout(.steps), readout(.weather), readout(.countdown)]
        XCTAssertEqual(design.soonestRefresh, 30 * 60)
    }

    /// A widget extension cannot show a permission prompt, so the app has to
    /// know which ones to ask for before the widget needs them.
    func testOnlyTheGatheredSourcesNeedPermission() {
        let design = [readout(.steps), readout(.weather), readout(.battery), readout(.countdown)]
        XCTAssertEqual(design.permissionSources, [.steps, .weather])
    }

    func testBatteryAndTheClockNeedNoPermission() {
        for source in [PlacedReadout.Source.battery, .time, .date, .countdown] {
            XCTAssertFalse(source.needsPermission, "\(source.title) should not need asking")
        }
    }

    /// The centre is the anchor because the text has no authored width: a value
    /// going from "9" to "10" must not shift the readout sideways.
    func testTheRectIsCentredOnThePlacedPoint() {
        var subject = readout(.steps)
        subject.pointSize = 50
        XCTAssertEqual(subject.rect.midX, 100, accuracy: 0.001)
        XCTAssertEqual(subject.rect.midY, 200, accuracy: 0.001)
    }

    /// Raw values are in the document. Renaming a case would orphan every
    /// design that used it, so they are pinned here.
    func testTheStoredNamesDoNotDrift() {
        XCTAssertEqual(
            PlacedReadout.Source.allCases.map(\.rawValue),
            ["time", "date", "countdown", "battery", "steps", "weather", "calendar"]
        )
    }

    func testAReadoutSurvivesARoundTrip() throws {
        var subject = readout(.countdown)
        subject.targetDate = Date(timeIntervalSince1970: 1_800_000_000)
        subject.label = "Portugal"
        subject.prefix = "in "
        let data = try JSONEncoder().encode(subject)
        XCTAssertEqual(try JSONDecoder().decode(PlacedReadout.self, from: data), subject)
    }

    /// A design written before readouts existed has no key at all, and a
    /// non-optional would fail the whole decode rather than default to none.
    func testADocumentWithoutReadoutsStillDecodes() throws {
        let json = #"{"battery":"87%"}"#
        let values = try JSONDecoder().decode(ReadoutValues.self, from: Data(json.utf8))
        XCTAssertEqual(values.battery, "87%")
        XCTAssertNil(values.steps)
        XCTAssertNil(values.gatheredAt)
    }

    /// Never gathered is not the same as gathered long ago, but both are
    /// reasons to doubt what is on screen.
    func testValuesAreStaleUntilGathered() {
        XCTAssertTrue(ReadoutValues.empty.isStale())
        var fresh = ReadoutValues.empty
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        fresh.gatheredAt = now
        XCTAssertFalse(fresh.isStale(now: now.addingTimeInterval(60)))
        XCTAssertTrue(fresh.isStale(now: now.addingTimeInterval(60 * 60 * 3)))
    }

    func testAValueIsOnlyReadBackForItsOwnSource() {
        var values = ReadoutValues.empty
        values.steps = "8,432"
        XCTAssertEqual(values.text(for: .steps), "8,432")
        XCTAssertNil(values.text(for: .weather))
        // The clock sources draw themselves, so carrying a value for one would
        // be a value nothing reads.
        XCTAssertNil(values.text(for: .countdown))
    }
}

/// Steps and weather were removed because neither could work: HealthKit needs
/// an entitlement this app does not carry, and WeatherKit needs one that also
/// has to be enabled on the App ID. Both silently showed nothing.
final class RetiredReadoutTests: XCTestCase {
    func testTheDeadSourcesAreNoLongerOffered() {
        XCTAssertFalse(PlacedReadout.Source.offered.contains(.steps))
        XCTAssertFalse(PlacedReadout.Source.offered.contains(.weather))
    }

    func testEverythingElseIsStillOffered() {
        XCTAssertEqual(
            PlacedReadout.Source.offered,
            [.time, .date, .countdown, .battery, .calendar]
        )
    }

    /// The cases stay in the enum on purpose. Removing them would orphan every
    /// document that placed one, and the store drops a design it cannot decode
    /// rather than reporting it - so they would vanish from the library.
    ///
    /// Round-tripped rather than hand-written: `PlacedReadout` decodes without
    /// defaults, so a fixture typed by hand tests the fixture.
    func testADesignThatPlacedARetiredReadoutStillDecodes() throws {
        for source: PlacedReadout.Source in [.steps, .weather] {
            let stored = PlacedReadout(source: source, center: CGPoint(x: 10, y: 10))
            let data = try JSONEncoder().encode(stored)
            let read = try JSONDecoder().decode(PlacedReadout.self, from: data)
            XCTAssertEqual(read.source, source, "a placed \(source.rawValue) must still open")
        }
    }

    /// And nothing asks for a permission it no longer uses.
    func testNoHealthOrLocationPermissionIsDeclared() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let text = try String(contentsOf: plist, encoding: .utf8)
        XCTAssertFalse(text.contains("NSHealthShareUsageDescription"))
        XCTAssertFalse(text.contains("NSLocationWhenInUseUsageDescription"))
        XCTAssertTrue(text.contains("NSCalendarsUsageDescription"), "the calendar readout is still here")
    }
}
