import Foundation
import Testing
@testable import StreamApp

struct PrivacyConfigurationTests {
    @Test func defaultsAndLegacyDelayIsIgnored() throws {
        let defaults = StudioConfiguration()
        #expect(!defaults.privacyShieldEnabled)
        #expect(defaults.privacyHidesPersonalInfo)
        #expect(PrivacyTimeline.delay == 0.5)
        #expect(Int(PrivacyTimeline.delay * 48_000) * 2 == 48_000)
        #expect(Int(PrivacyTimeline.delay * 100) + 200 == 250)
        for delay in [0, 1, 2, 3, 4, 5, 99] {
            let decoded = try JSONDecoder().decode(StudioConfiguration.self,
                from: Data("{\"privacyDelaySeconds\":\(delay),\"privacyShieldEnabled\":true}".utf8))
            #expect(decoded.privacyShieldEnabled)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
            #expect(encoded["privacyDelaySeconds"] == nil)
        }
    }
    @Test func privacySettingsRoundTrip() throws {
        var config = StudioConfiguration()
        config.privacyShieldEnabled = true; config.privacyHidesPersonalInfo = false
        config.privacyCensorStyle = .striped; config.privacyCensorRed = 0.8
        let decoded = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded.privacyShieldEnabled && !decoded.privacyHidesPersonalInfo)
        #expect(decoded.privacyCensorStyle == .striped && decoded.privacyCensorRed == 0.8)
    }
}
