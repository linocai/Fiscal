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
    return app
}
