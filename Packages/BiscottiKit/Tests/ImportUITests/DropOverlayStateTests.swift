import Foundation
import Testing
@testable import ImportUI

@Suite("DropOverlayState.classify")
struct DropOverlayClassifyTests {
    @Test("empty array returns nil")
    func emptyArrayReturnsNil() {
        #expect(DropOverlayState.classify([]) == nil)
    }

    @Test("single supported")
    func singleSupported() {
        let state = DropOverlayState.classify([true])
        #expect(state == .supported(count: 1))
    }

    @Test("multiple all supported")
    func multipleAllSupported() {
        let state = DropOverlayState.classify([true, true, true])
        #expect(state == .supported(count: 3))
    }

    @Test("mixed")
    func mixed() {
        let state = DropOverlayState.classify([true, false])
        #expect(state == .mixed(supported: 1, unsupported: 1))
    }

    @Test("single unsupported")
    func singleUnsupported() {
        let state = DropOverlayState.classify([false])
        #expect(state == .unsupported(count: 1))
    }

    @Test("multiple all unsupported")
    func multipleAllUnsupported() {
        let state = DropOverlayState.classify([false, false])
        #expect(state == .unsupported(count: 2))
    }

    @Test("mixed three plus two")
    func mixedThreePlusTwo() {
        let state = DropOverlayState.classify(
            [true, true, false, true, false]
        )
        #expect(state == .mixed(supported: 3, unsupported: 2))
    }
}

@Suite("DropOverlayState.acceptsDrop")
struct DropOverlayAcceptsDropTests {
    @Test("supported accepts")
    func supportedAccepts() {
        #expect(DropOverlayState.supported(count: 1).acceptsDrop == true)
    }

    @Test("mixed accepts")
    func mixedAccepts() {
        #expect(
            DropOverlayState.mixed(supported: 2, unsupported: 1).acceptsDrop
                == true
        )
    }

    @Test("unsupported rejects")
    func unsupportedRejects() {
        #expect(
            DropOverlayState.unsupported(count: 1).acceptsDrop == false
        )
    }
}

@Suite("DropOverlayState copy properties")
struct DropOverlayCopyTests {
    // MARK: - Title

    @Test("supported single title")
    func supportedSingleTitle() {
        #expect(DropOverlayState.supported(count: 1).title == "Drop to import")
    }

    @Test("supported multiple title")
    func supportedMultipleTitle() {
        #expect(
            DropOverlayState.supported(count: 3).title
                == "Drop to import 3 files"
        )
    }

    @Test("mixed with one supported title")
    func mixedOneSupportedTitle() {
        #expect(
            DropOverlayState.mixed(supported: 1, unsupported: 2).title
                == "Drop to import"
        )
    }

    @Test("mixed with multiple supported title")
    func mixedMultipleSupportedTitle() {
        #expect(
            DropOverlayState.mixed(supported: 3, unsupported: 2).title
                == "Drop to import 3 files"
        )
    }

    @Test("unsupported title")
    func unsupportedTitle() {
        #expect(
            DropOverlayState.unsupported(count: 1).title
                == "Can\u{2019}t import this file"
        )
    }

    // MARK: - Subtitle

    @Test("supported single subtitle")
    func supportedSingleSubtitle() {
        #expect(
            DropOverlayState.supported(count: 1).subtitle
                == "Biscotti will transcribe and summarize it on your Mac."
        )
    }

    @Test("supported multiple subtitle")
    func supportedMultipleSubtitle() {
        #expect(
            DropOverlayState.supported(count: 3).subtitle
                == "Each file becomes its own meeting."
        )
    }

    @Test("mixed subtitle")
    func mixedSubtitle() {
        #expect(
            DropOverlayState.mixed(supported: 1, unsupported: 1).subtitle
                == "Each file becomes its own meeting."
        )
    }

    @Test("unsupported subtitle")
    func unsupportedSubtitle() {
        #expect(
            DropOverlayState.unsupported(count: 1).subtitle
                == "Biscotti imports audio and video recordings."
        )
    }

    // MARK: - Format line

    @Test("format line shown for single supported")
    func formatLineSingleSupported() {
        #expect(DropOverlayState.supported(count: 1).showsFormatLine == true)
    }

    @Test("format line hidden for multiple supported")
    func formatLineMultipleSupported() {
        #expect(DropOverlayState.supported(count: 3).showsFormatLine == false)
    }

    @Test("format line hidden for mixed")
    func formatLineMixed() {
        #expect(
            DropOverlayState.mixed(supported: 1, unsupported: 1)
                .showsFormatLine == false
        )
    }

    @Test("format line shown for unsupported")
    func formatLineUnsupported() {
        #expect(
            DropOverlayState.unsupported(count: 1).showsFormatLine == true
        )
    }

    // MARK: - Skip notice

    @Test("skip notice nil for supported")
    func skipNoticeNilForSupported() {
        #expect(DropOverlayState.supported(count: 1).skipNotice == nil)
    }

    @Test("skip notice nil for unsupported")
    func skipNoticeNilForUnsupported() {
        #expect(DropOverlayState.unsupported(count: 1).skipNotice == nil)
    }

    @Test("skip notice singular")
    func skipNoticeSingular() {
        let notice = DropOverlayState.mixed(supported: 3, unsupported: 1)
            .skipNotice
        #expect(notice?.count == 1)
        #expect(
            notice?.text
                == "1 file is an unsupported file type and will be skipped."
        )
    }

    @Test("skip notice plural")
    func skipNoticePlural() {
        let notice = DropOverlayState.mixed(supported: 3, unsupported: 2)
            .skipNotice
        #expect(notice?.count == 2)
        #expect(
            notice?.text
                == "2 files are unsupported file types and will be skipped."
        )
    }

    // MARK: - isNeutral

    @Test("isNeutral false for supported")
    func isNeutralFalseForSupported() {
        #expect(DropOverlayState.supported(count: 1).isNeutral == false)
    }

    @Test("isNeutral false for mixed")
    func isNeutralFalseForMixed() {
        #expect(
            DropOverlayState.mixed(supported: 1, unsupported: 1).isNeutral
                == false
        )
    }

    @Test("isNeutral true for unsupported")
    func isNeutralTrueForUnsupported() {
        #expect(DropOverlayState.unsupported(count: 1).isNeutral == true)
    }
}
