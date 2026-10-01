import XCTest
@testable import SignalWordCore

final class PresentationModelsTests: XCTestCase {
    func testAlertKindAndLifecycleRemainVisibleInPresentation() {
        let test = AlertPresentationModel(
            eventID: UUID(), kind: "test", eventState: "active",
            initialDelivery: "queued", resolutionDelivery: nil, isAcknowledged: false
        )
        let real = AlertPresentationModel(
            eventID: UUID(), kind: "real", eventState: "active",
            initialDelivery: "queued", resolutionDelivery: nil, isAcknowledged: false
        )

        XCTAssertEqual(test.headline, "TEST alert active")
        XCTAssertEqual(real.headline, "REAL alert active")
        XCTAssertEqual(test.initialDelivery, .queued)
        XCTAssertTrue(test.showsInitialDelivery)
        XCTAssertFalse(AlertPresentationModel(kind: .real, lifecycle: .savedLocally).showsInitialDelivery)
    }

    func testDeliveryAndResolutionDeliveryAreIndependent() {
        let status = AlertPresentationModel(
            eventID: UUID(), kind: "real", eventState: "resolved",
            initialDelivery: "delivered", resolutionDelivery: "failed", isAcknowledged: true
        )

        XCTAssertEqual(status.headline, "REAL alert resolved")
        XCTAssertEqual(status.initialDelivery, .delivered)
        XCTAssertEqual(status.resolutionDelivery, .failed)
        XCTAssertTrue(status.isAcknowledged)
    }

    func testMissingResolutionDeliveryStaysUnknownAfterResolution() {
        let status = AlertPresentationModel(
            eventID: UUID(), kind: "real", eventState: "resolved",
            initialDelivery: "sent", resolutionDelivery: nil, isAcknowledged: false
        )

        XCTAssertEqual(status.initialDelivery, .providerAccepted)
        XCTAssertEqual(status.resolutionDelivery, .unknown)
    }

    func testUnknownWireValuesNeverBecomeSuccess() {
        let status = AlertPresentationModel(
            eventID: UUID(), kind: "future-kind", eventState: "future-state",
            initialDelivery: "future-delivery", resolutionDelivery: "future-resolution", isAcknowledged: false
        )

        XCTAssertEqual(status.headline, "Alert status unavailable")
        XCTAssertEqual(status.initialDelivery, .unknown)
        XCTAssertEqual(status.resolutionDelivery, .unknown)
        XCTAssertEqual(status.initialDelivery.title, "Delivery status unavailable")
    }

    func testEveryDocumentedDeliveryStateHasItsOwnPresentation() {
        XCTAssertEqual(AlertDeliveryDisplayState("queued"), .queued)
        XCTAssertEqual(AlertDeliveryDisplayState("sent"), .providerAccepted)
        XCTAssertEqual(AlertDeliveryDisplayState("delivered"), .delivered)
        XCTAssertEqual(AlertDeliveryDisplayState("failed"), .failed)
        XCTAssertEqual(AlertDeliveryDisplayState(nil), .unknown)
        XCTAssertNotEqual(AlertDeliveryDisplayState("sent").title, AlertDeliveryDisplayState("delivered").title)
    }

    func testUnknownAlertKindDoesNotBecomeARealAlert() {
        let status = AlertPresentationModel(
            eventID: UUID(), kind: "future-kind", eventState: "active",
            initialDelivery: nil, resolutionDelivery: nil, isAcknowledged: false
        )

        XCTAssertNil(status.kind)
        XCTAssertEqual(status.headline, "Alert active")
    }

    func testLocationFreshnessIsExplicitAndNeverImpliesTracking() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(LocationFreshnessPresentationModel(capturedAt: nil, now: now).state, .unavailable)
        XCTAssertEqual(LocationFreshnessPresentationModel(capturedAt: now.addingTimeInterval(-10), now: now).state, .live)
        XCTAssertEqual(LocationFreshnessPresentationModel(capturedAt: now.addingTimeInterval(-60), now: now).state, .recent)
        XCTAssertEqual(LocationFreshnessPresentationModel(capturedAt: now.addingTimeInterval(-180), now: now).state, .stale)
    }

    func testOptionalLocationAndShortcutReportDoNotGateManualAlertReadiness() {
        let manual = ReadinessPresentationModel.manualAlert(identityReady: true, recipientConfirmed: true)
        let tests = ReadinessPresentationModel.acknowledgedTests(count: 0)

        XCTAssertTrue(manual.isReady)
        XCTAssertFalse(tests.isReady)
        XCTAssertFalse(ReadinessPresentationModel.recipientConsent(isConfirmed: false).isReady)
        XCTAssertFalse(ReadinessPresentationModel.optionalLocation(detail: "Optional").isReady)
        XCTAssertFalse(ReadinessPresentationModel.shortcutReport(isConfigured: false).isReady)
        XCTAssertFalse(ReadinessPresentationModel.shortcutReport(isConfigured: true).isReady)
        XCTAssertFalse(ReadinessPresentationModel.lockedTestReport(count: 2).isReady)
    }

    func testTwoDistinctAcknowledgedTestsDefineRehearsalEvidence() {
        XCTAssertFalse(ReadinessPresentationModel.acknowledgedTests(count: 1).isReady)
        XCTAssertTrue(ReadinessPresentationModel.acknowledgedTests(count: 2).isReady)
        XCTAssertTrue(ReadinessPresentationModel.acknowledgedTests(count: 3).isReady)
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            ReadinessPresentationModel.distinctAcknowledgedTestCount(eventIDs: [first, first, second]),
            2
        )
    }
}
