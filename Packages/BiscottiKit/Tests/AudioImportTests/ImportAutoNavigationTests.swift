import Foundation
import Testing
@testable import AppCore
@testable import AudioImport

@Suite("ImportAutoNavigation")
struct ImportAutoNavigationTests {
    @Test("single file, no pending, on importing -> navigate")
    func singleNoPendingImporting() {
        #expect(ImportAutoNavigation.shouldNavigate(
            batchSize: 1,
            controllerHasPendingWork: false,
            route: .importing
        ))
    }

    @Test("multi-file batch -> no navigate")
    func multiBatch() {
        #expect(!ImportAutoNavigation.shouldNavigate(
            batchSize: 3,
            controllerHasPendingWork: false,
            route: .importing
        ))
    }

    @Test("single file, pending work -> no navigate")
    func pendingWork() {
        #expect(!ImportAutoNavigation.shouldNavigate(
            batchSize: 1,
            controllerHasPendingWork: true,
            route: .importing
        ))
    }

    @Test("single file, no pending, on home -> no navigate")
    func wrongRoute() {
        #expect(!ImportAutoNavigation.shouldNavigate(
            batchSize: 1,
            controllerHasPendingWork: false,
            route: .home
        ))
    }

    @Test("single file, no pending, on meetings -> no navigate")
    func meetingsRoute() {
        #expect(!ImportAutoNavigation.shouldNavigate(
            batchSize: 1,
            controllerHasPendingWork: false,
            route: .meetings
        ))
    }
}
