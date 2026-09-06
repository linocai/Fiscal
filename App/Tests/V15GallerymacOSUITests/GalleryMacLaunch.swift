import XCTest

@discardableResult
func launchGalleryMac(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
    let app = XCUIApplication()
    app.terminate()
    app.launchArguments = arguments
    app.launch()
    app.activate()

    let deadline = Date().addingTimeInterval(8)
    while app.state != .runningForeground, Date() < deadline {
        app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertEqual(app.state, .runningForeground, "Gallery must be foreground before UI assertions", file: file, line: line)
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 4), "Gallery must expose a window before UI assertions", file: file, line: line)
    }
    return app
}

// Keep a bounded, reproducible visual record of the exercised native surface.
extension XCTestCase {
    func attachV220(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
