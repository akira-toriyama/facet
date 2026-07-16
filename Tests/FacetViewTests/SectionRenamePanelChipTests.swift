import CoreGraphics
import Testing
@testable import FacetView

/// t-kywh: the alias-picker chip geometry (`chipFlowFrames`) — the ONE
/// layout the panel-height math in `show` and the button placement both
/// consume, so these pin its flow-wrap contract. Text measuring is
/// font-environment-dependent, so the assertions are STRUCTURAL (fits,
/// wraps, order, row bands) rather than pixel-exact. CI-only like the
/// other suites (CLT cannot run `swift test`).
@MainActor
struct SectionRenamePanelChipTests {

    private let chipH = SectionRenameContainerView.chipH
    private let gapY = SectionRenameContainerView.chipGapY

    @Test func emptyTitlesYieldNoFrames() {
        #expect(SectionRenamePanel.chipFlowFrames(titles: [], maxWidth: 300)
            .isEmpty)
    }

    @Test func everyFrameFitsTheContentWidth() {
        let frames = SectionRenamePanel.chipFlowFrames(
            titles: ["@web", "@work", "@a-much-longer-alias-name", "@x"],
            maxWidth: 160)
        for f in frames {
            #expect(f.minX >= 0)
            #expect(f.maxX <= 160.5)   // ±ceil slack on the min'd oversize chip
            #expect(f.height == chipH)
        }
    }

    @Test func framesWrapIntoRowBandsInOrder() {
        // Enough chips at a narrow width to force wrapping.
        let titles = (1...8).map { "@alias-\($0)" }
        let frames = SectionRenamePanel.chipFlowFrames(titles: titles,
                                                       maxWidth: 120)
        #expect(frames.count == titles.count)   // every chip gets a frame
        // y advances in whole row bands; within a band x strictly increases.
        var lastY: CGFloat = 0
        var lastMaxX: CGFloat = -1
        for f in frames {
            if f.minY > lastY {
                #expect((f.minY - lastY)
                    .truncatingRemainder(dividingBy: chipH + gapY) == 0)
                lastY = f.minY
                lastMaxX = -1
            } else {
                #expect(f.minY == lastY)
            }
            #expect(f.minX > lastMaxX)
            lastMaxX = f.maxX
        }
        #expect(lastY > 0, "narrow width must have wrapped at least once")
    }

    @Test func singleShortChipStaysOnOneRow() {
        let frames = SectionRenamePanel.chipFlowFrames(titles: ["@web"],
                                                       maxWidth: 400)
        #expect(frames.count == 1)
        #expect(frames[0].minY == 0)
        #expect(frames[0].minX == 0)
    }

    @Test func oversizeTitleIsClampedNotDropped() {
        let long = "@" + String(repeating: "x", count: 200)
        let frames = SectionRenamePanel.chipFlowFrames(titles: [long],
                                                       maxWidth: 100)
        #expect(frames.count == 1)
        #expect(frames[0].width == 100)   // min(maxWidth, …) clamp
    }
}
