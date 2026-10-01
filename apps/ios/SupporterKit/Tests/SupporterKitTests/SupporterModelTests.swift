import XCTest
@testable import SupporterKit

@MainActor final class SupporterModelTests: XCTestCase {
    final class Fake: SupporterService {
        var active = false
        var result: SupporterPurchaseResult = .active
        var fails = false
        var purchases = 0
        var restored = false
        func offer() async throws -> SupporterOffer? { if fails { throw Failure.offline }; return .init(price: "$4.99") }
        func isActive() async throws -> Bool { if fails { throw Failure.offline }; return active }
        func purchase() async throws -> SupporterPurchaseResult { purchases += 1; if fails { throw Failure.offline }; return result }
        func restore() async throws -> Bool { if fails { throw Failure.offline }; return restored }
        enum Failure: Error { case offline }
    }
    func model(_ service: Fake) -> SupporterModel {
        SupporterModel(service: service, preferences: UserDefaults(suiteName: UUID().uuidString)!)
    }
    func testPurchaseAndAppearance() async {
        let fake = Fake(); let subject = model(fake)
        subject.select("ocean")
        XCTAssertEqual(subject.selectedAppearance, "standard")
        await subject.refresh(); await subject.buy(); subject.select("ocean")
        XCTAssertTrue(subject.active)
        XCTAssertEqual(subject.selectedAppearance, "ocean")
        await subject.buy()
        XCTAssertEqual(fake.purchases, 1)
    }
    func testCancellationDoesNotUnlock() async {
        let fake = Fake(); fake.result = .cancelled; let subject = model(fake)
        await subject.refresh(); await subject.buy()
        XCTAssertFalse(subject.active)
        XCTAssertTrue(subject.message!.contains("cancelled"))
    }
    func testPendingDoesNotUnlock() async {
        let fake = Fake(); fake.result = .pending; let subject = model(fake)
        await subject.refresh(); await subject.buy()
        XCTAssertFalse(subject.active)
        XCTAssertTrue(subject.message!.contains("pending"))
    }
    func testOfflineOfferDoesNotPermitPurchase() async {
        let fake = Fake(); fake.fails = true; let subject = model(fake)
        await subject.refresh(); await subject.buy()
        XCTAssertNil(subject.offer); XCTAssertEqual(fake.purchases, 0); XCTAssertFalse(subject.busy)
    }
    func testRestoreAndRevocation() async {
        let fake = Fake(); fake.restored = true; let subject = model(fake)
        await subject.restore(); subject.select("lavender")
        XCTAssertEqual(subject.selectedAppearance, "lavender")
        fake.active = false; await subject.refresh()
        XCTAssertFalse(subject.active); XCTAssertEqual(subject.selectedAppearance, "standard")
    }
    func testRelaunchDoesNotTrustPreferencesAsEntitlement() async {
        let fake = Fake(); fake.restored = true
        let prefs = UserDefaults(suiteName: UUID().uuidString)!
        let first = SupporterModel(service: fake, preferences: prefs)
        await first.restore(); first.select("ocean")
        let relaunched = SupporterModel(service: fake, preferences: prefs)
        XCTAssertEqual(relaunched.selectedAppearance, "standard")
        await relaunched.restore()
        XCTAssertEqual(relaunched.selectedAppearance, "ocean")
    }
    func testColdLaunchRefreshRecoversSavedAppearanceWithoutRestorePurchase() async {
        let fake = Fake(); fake.active = true; fake.restored = true
        let suite = UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var current = SupporterModel(service: fake, preferences: prefs)
        await current.refresh()
        for choice in ["ocean", "lavender"] {
            current.select(choice)
            // A fresh UserDefaults instance verifies persisted preference, not
            // just the first model's in-memory selection.
            let relaunched = SupporterModel(service: fake, preferences: UserDefaults(suiteName: suite)!)
            XCTAssertEqual(relaunched.appearance, choice)
            XCTAssertFalse(relaunched.active)
            await relaunched.refresh()
            XCTAssertEqual(relaunched.selectedAppearance, choice)
            await relaunched.restore()
            XCTAssertEqual(relaunched.selectedAppearance, choice)
            XCTAssertEqual(fake.purchases, 0)
            current = relaunched
        }
        fake.active = false
        await current.refresh()
        XCTAssertEqual(current.selectedAppearance, "standard")
    }
    func testPurchaseFailureNeverUnlocksOrLeavesBusy() async {
        let fake = Fake(); let subject = model(fake)
        await subject.refresh(); fake.fails = true
        await subject.buy()
        XCTAssertFalse(subject.active); XCTAssertFalse(subject.busy)
        XCTAssertTrue(subject.message!.contains("Restore"))
    }
    func testRestoreFailureDoesNotEraseConfirmedEntitlement() async {
        let fake = Fake(); fake.restored = true; let subject = model(fake)
        await subject.restore(); fake.fails = true; await subject.restore()
        XCTAssertTrue(subject.active); XCTAssertFalse(subject.busy)
        XCTAssertTrue(subject.message!.contains("try again"))
    }
    func testReleaseRejectsTestAndSecretKeys() {
        XCTAssertFalse(RevenueCatSupporterService.validKey("test_example123", allowTestStore: false))
        XCTAssertFalse(RevenueCatSupporterService.validKey("sk_example123", allowTestStore: true))
        XCTAssertTrue(RevenueCatSupporterService.validKey("test_example123", allowTestStore: true))
        XCTAssertTrue(RevenueCatSupporterService.validKey("appl_example123", allowTestStore: false))
    }
}
