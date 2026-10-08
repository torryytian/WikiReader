import SwiftUI
import Testing
import UIKit
@testable import WikiReader

struct AppAppearanceTests {
    @Test func systemLeavesTheStyleUnspecified() {
        #expect(AppAppearance.system.interfaceStyle == .unspecified)
        #expect(AppAppearance.system.colorScheme == nil)
    }

    @Test func lightAndDarkMapToTheirStyles() {
        #expect(AppAppearance.light.interfaceStyle == .light)
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.interfaceStyle == .dark)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }

    @Test func storedValuesAreStable() {
        // These raw values are saved in UserDefaults (and in backups), so they must not change.
        #expect(AppAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(AppAppearance(rawValue: "dark") == .dark)
    }
}
