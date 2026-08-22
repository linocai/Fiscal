import XCTest

@MainActor final class F3DMacGalleryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testCashFlowSpineInspectorEditorsAndRecoverySurfacesAreReachable() {
        let app = launchGalleryMac(["--v15-f3d-route", "cash-flow-create"])
        XCTAssertTrue(element(app, "v15.f3d.cash-flow.macos").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "v15.f3d.mac.spine").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3d.mac.inspector").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "v15.f3d.mac.editor").waitForExistence(timeout: 5))
        app.terminate()
    }

    func testMacUnknownConflictAndPartialRefreshCompileIntoInspector() {
        for (route, identifier) in [("cash-flow-unknown", "v15.f3d.mac.unknown"), ("cash-flow-conflict", "v15.f3d.mac.conflict"), ("cash-flow-partial-refresh", "v15.f3d.mac.fact-refresh")] {
            let app = launchGalleryMac(["--v15-f3d-route", route])
            XCTAssertTrue(element(app, "v15.f3d.cash-flow.macos").waitForExistence(timeout: 10))
            XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 8))
            app.terminate()
        }
    }
}
