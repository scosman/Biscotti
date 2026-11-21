import Foundation
import Testing
@testable import Notifications

/// The three answers to "Live captions are off".
struct CaptionsResponseTests {
    @Test func buttonsMapToActions() {
        let info: [AnyHashable: Any] = [UserInfoKey.bundleID: "com.microsoft.teams2"]
        #expect(mapResponse(categoryID: CategoryID.captions, actionID: ActionID.turnOnCaptions, userInfo: info)
            == .turnOnCaptions(bundleID: "com.microsoft.teams2"))
        #expect(mapResponse(categoryID: CategoryID.captions, actionID: ActionID.skipCaptions, userInfo: info)
            == .skipCaptions(bundleID: "com.microsoft.teams2"))
        #expect(mapResponse(categoryID: CategoryID.captions, actionID: ActionID.noCaptions, userInfo: info)
            == .neverOfferCaptions)
    }
}
