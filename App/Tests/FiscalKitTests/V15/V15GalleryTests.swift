import Testing

@testable import FiscalKit

@Suite("V15 gallery shell contracts")
struct V15GalleryTests {
    @Test("all approved state families have one stable fixture ID")
    func fixtureCoverage() {
        #expect(V15GalleryFixture.allCases.count == 11)
        #expect(Set(V15GalleryFixture.allCases.map(\.id)).count == 11)
        #expect(V15GalleryFixture.resolve("preview") == .preview)
        #expect(V15GalleryFixture.resolve("future-server-state") == .preview)
    }

    @Test("fixture copy retains the non-negotiable state semantics")
    func fixtureSemantics() {
        #expect(V15GalleryFixture.preview.accessibilitySummary.contains("尚未提交"))
        #expect(V15GalleryFixture.conflict.accessibilitySummary.contains("重新决定"))
        #expect(V15GalleryFixture.archiveReadOnly.accessibilitySummary.contains("只读"))
        #expect(V15GalleryFixture.partialProgress.accessibilitySummary.contains("剩余"))
        #expect(V15GalleryFixture.disabledReasons.accessibilitySummary.contains("原因"))
    }

    @Test("gallery shell remains a fixture-only parallel composition root")
    @MainActor
    func parallelShellConstruction() {
        _ = V15GalleryShell(fixture: .fieldInvalid, density: .compact, showsFieldErrorSheet: true)
        _ = V15GalleryShell(fixture: .preview, density: .comfortable)
        #expect(V15Accessibility.largeTextYieldOrder == [
            "元信息换行", "按钮转纵向", "固定高度改为最小高度", "图标改为顶对齐", "金额不缩小、不换行、不截断"
        ])
    }
}
