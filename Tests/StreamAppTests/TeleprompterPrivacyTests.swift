import Foundation
import Testing
@testable import StreamApp

struct TeleprompterPrivacyTests {
    @Test func teleprompterOptInIsIndependentOfAppVisibility() {
        var c = StudioConfiguration()
        for showApp in [false, true] {
            c.showStreamAppWindows = showApp
            c.teleprompterInCapture = false
            #expect(!visible(12, configuration: c))
            #expect(!visible(16, configuration: c)) // The separate handle is private too.
            c.teleprompterInCapture = true
            #expect(visible(12, configuration: c))
            #expect(visible(16, configuration: c))
            #expect(visible(13, configuration: c) == showApp)
            #expect(visible(11, configuration: c)) // Annotation ink remains visible.
        }
        c.excludedWindowIDs = [12]
        #expect(!visible(12, configuration: c))
    }

    @Test func applicationAndWindowExclusionsStillHideOrdinaryWindows() {
        var c = StudioConfiguration()
        c.showStreamAppWindows = true
        #expect(!visible(13, excludedApp: true, configuration: c))
        c.excludedWindowIDs = [13, 14]
        #expect(!visible(13, configuration: c))
        #expect(!visible(14, own: false, configuration: c))
        #expect(visible(15, own: false, configuration: c))
        #expect(!visible(15, own: false, excludedApp: true, configuration: c))
    }

    @Test func olderSettingsDoNotExposeTeleprompter() throws {
        let c = try JSONDecoder().decode(StudioConfiguration.self, from: Data(#"{"showStreamAppWindows":true}"#.utf8))
        #expect(!visible(12, configuration: c))
        #expect(!visible(16, configuration: c))
        #expect(c.teleprompterMode == .off)
    }

    private func visible(_ id: UInt32, own: Bool = true, excludedApp: Bool = false, configuration: StudioConfiguration) -> Bool {
        CaptureWindowPolicy.isVisible(windowID: id, isOwnWindow: own, applicationExcluded: excludedApp,
                                      configuration: configuration, annotationWindowID: 11, teleprompterWindowIDs: [12, 16])
    }
}
