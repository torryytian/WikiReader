import Testing
@testable import WikiReader

struct ReaderMenuVisibilityTests {
    typealias Menus = ReaderMenuVisibility

    @Test func startsImmersive() {
        let menus = Menus()
        #expect(!menus.top)
        #expect(!menus.isBottomShown(pinned: false))
    }

    // MARK: - Not pinned: the immersive rules

    @Test func tappingTheEdgesOpensAndClosesTheMenus() {
        var menus = Menus()
        menus.tap(.bottom, pinned: false)
        #expect(menus.isBottomShown(pinned: false))
        menus.tap(.bottom, pinned: false)
        #expect(!menus.isBottomShown(pinned: false))
        menus.tap(.top, pinned: false)
        #expect(menus.top)
        menus.tap(.top, pinned: false)
        #expect(!menus.top)
    }

    @Test func tappingTheTextOrScrollingHidesBothMenus() {
        var menus = Menus()
        menus.tap(.top, pinned: false)
        menus.tap(.bottom, pinned: false)
        menus.tap(.middle, pinned: false)   // a tap on the text, or a word looked up (which reports the middle zone)
        #expect(!menus.top && !menus.isBottomShown(pinned: false))

        menus.tap(.top, pinned: false)
        menus.tap(.bottom, pinned: false)
        menus.hide(pinned: false)           // scrolling, opening a panel
        #expect(!menus.top && !menus.isBottomShown(pinned: false))
    }

    // MARK: - Pinned: the bottom menu stays

    @Test func aPinnedMenuIsShownWithoutBeingAskedFor() {
        let menus = Menus()
        #expect(menus.isBottomShown(pinned: true))
    }

    @Test func tappingTheTextScrollingOrLookingUpAWordKeepsAPinnedMenu() {
        var menus = Menus()
        menus.pinChanged(to: true)
        menus.tap(.middle, pinned: true)
        #expect(menus.isBottomShown(pinned: true))
        menus.hide(pinned: true)
        #expect(menus.isBottomShown(pinned: true))
        for _ in 0..<3 { menus.tap(.middle, pinned: true) }
        #expect(menus.isBottomShown(pinned: true))
    }

    @Test func tappingTheBottomEdgeDoesNothingWhilePinned() {
        var menus = Menus()
        menus.pinChanged(to: true)
        menus.tap(.bottom, pinned: true)
        menus.tap(.bottom, pinned: true)
        #expect(menus.isBottomShown(pinned: true))
        // And it doesn't leave the menu hidden-in-waiting for when the pin is removed.
        #expect(menus.isBottomShown(pinned: false))
    }

    @Test func theTopBarStillFollowsTheImmersiveRulesWhilePinned() {
        var menus = Menus()
        menus.pinChanged(to: true)
        menus.tap(.top, pinned: true)
        #expect(menus.top)
        menus.tap(.middle, pinned: true)    // tapping the text puts the top bar away, the bottom menu stays
        #expect(!menus.top)
        #expect(menus.isBottomShown(pinned: true))
        menus.tap(.top, pinned: true)
        menus.hide(pinned: true)
        #expect(!menus.top)
    }

    // MARK: - Pinning and unpinning

    @Test func unpinningLeavesTheMenuUpUntilTheNextTapOrScroll() {
        var menus = Menus()
        menus.pinChanged(to: true)
        menus.pinChanged(to: false)
        #expect(menus.isBottomShown(pinned: false))   // not gone under the finger that pressed the button
        menus.tap(.middle, pinned: false)
        #expect(!menus.isBottomShown(pinned: false))
    }

    @Test func pinningWhileTheMenuIsAlreadyUpKeepsIt() {
        var menus = Menus()
        menus.tap(.bottom, pinned: false)
        menus.pinChanged(to: true)
        menus.hide(pinned: true)
        #expect(menus.isBottomShown(pinned: true))
    }

    @Test func pinningThenUnpinningThenHidingGoesBackToImmersive() {
        var menus = Menus()
        menus.pinChanged(to: true)
        menus.pinChanged(to: false)
        menus.hide(pinned: false)
        #expect(!menus.isBottomShown(pinned: false) && !menus.top)
    }
}
