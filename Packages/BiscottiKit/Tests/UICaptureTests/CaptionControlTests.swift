import Foundation
import Testing
@testable import UICapture

/// Recognising Teams' captions panel and button.
struct CaptionControlTests {
    @Test func panelAndButtonLabels() {
        // Labels from the 2026-11-19 Teams captures.
        #expect(CaptionControl.isCaptionPanel("Live Captions"))
        #expect(CaptionControl.isCaptionPanel("Hide live captions"))
        #expect(!CaptionControl.isCaptionPanel("Live Caption, Caption Settings"))
        #expect(CaptionControl.isTurnOnButton("Captions"))
        #expect(CaptionControl.isTurnOnButton("Show Captions"))
        #expect(!CaptionControl.isTurnOnButton("Caption Settings"))
    }
}
