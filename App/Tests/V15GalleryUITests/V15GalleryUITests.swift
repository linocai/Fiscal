import XCTest

@MainActor
final class V15GalleryUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ arguments: [String]) {
        continueAfterFailure = false
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    func testPreviewFixtureExposesStableAccessibilityOrderAndAction() {
        launch(["--v15-gallery-fixture", "preview"])
        XCTAssertTrue(app.descendants(matching: .any)["v15.gallery.ios"].waitForExistence(timeout: 4))
        let title = app.staticTexts["v15.gallery.order.title"]
        let amount = app.staticTexts["v15.gallery.order.amount"]
        let state = app.descendants(matching: .any)["v15.gallery.state.preview"]
        let action = app.buttons["确认账期调整"]
        let pagination = app.buttons.matching(identifier: "v15.gallery.order.pagination").firstMatch
        for element in [title, amount, state, action, pagination] {
            XCTAssertTrue(element.waitForExistence(timeout: 4))
        }
        XCTAssertLessThanOrEqual(title.frame.minY, amount.frame.minY)
        XCTAssertLessThanOrEqual(amount.frame.maxY, state.frame.minY)
        XCTAssertLessThanOrEqual(state.frame.minY, action.frame.minY)
        XCTAssertLessThanOrEqual(action.frame.maxY, pagination.frame.minY)
        XCTAssertTrue(app.buttons["确认账期调整"].isHittable)
    }

    func testEveryFixtureKeepsNaturalTitleWidthAndSingleLineMoney() {
        let fixtureIDs = ["loading", "empty", "service-error", "field-invalid", "disabled-reasons", "offline-readonly", "conflict", "preview", "archive-readonly", "success-receipt", "partial-progress"]
        for fixtureID in fixtureIDs {
            launch(["--v15-gallery-fixture", fixtureID])
            let title = app.staticTexts["v15.gallery.order.title"]
            let amount = app.staticTexts["v15.gallery.order.amount"]
            XCTAssertTrue(title.waitForExistence(timeout: 4), fixtureID)
            XCTAssertTrue(amount.exists, fixtureID)
            XCTAssertGreaterThan(title.frame.width, title.frame.height * 1.5, fixtureID)
            XCTAssertLessThan(title.frame.height, 110, fixtureID)
            XCTAssertGreaterThan(amount.frame.width, 180, fixtureID)
            XCTAssertLessThanOrEqual(title.frame.maxY, amount.frame.minY, fixtureID)
        }
    }

    func testRetryReloadAndDisabledReasonsRemainReachable() {
        launch(["--v15-gallery-fixture", "service-error"])
        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 4))
        app.buttons["重试"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.gallery.state.service-error"].exists)

        launch(["--v15-gallery-fixture", "conflict"])
        XCTAssertTrue(app.buttons["取最新数据重新决定"].waitForExistence(timeout: 4))
        app.buttons["取最新数据重新决定"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["v15.gallery.state.conflict"].exists)

        launch(["--v15-gallery-fixture", "disabled-reasons"])
        XCTAssertTrue(app.staticTexts["收款账户仍在加载。"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["提交报销"].isEnabled)
    }

    func testReduceMotionAndTransparencyFlagsExposeStableRenderingMode() {
        launch(["--v15-gallery-fixture", "preview", "--v15-gallery-reduce-motion", "--v15-gallery-reduce-transparency"])
        let mode = app.staticTexts["v15.gallery.rendering-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 4))
        XCTAssertEqual(mode.value as? String, "motion=reduced;transparency=reduced")
        XCTAssertEqual(app.descendants(matching: .any)["v15.gallery.decision-card"].value as? String, "motion=reduced;transparency=reduced")
    }

    func testSheetContainsServiceAndFieldErrorsAtThePointOfEntry() {
        launch(["--v15-gallery-fixture", "field-invalid", "--v15-gallery-sheet-error"])
        XCTAssertTrue(app.otherElements["v15.gallery.field-error-sheet"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["暂时无法取得数据"].exists)
        XCTAssertTrue(app.staticTexts["金额必须为两位小数。"].exists)
        XCTAssertFalse(app.buttons["保存"].isEnabled)
    }
}
