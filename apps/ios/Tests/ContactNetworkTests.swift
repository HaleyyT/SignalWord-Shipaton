import Foundation
import XCTest
@testable import SignalWordCore

final class ContactNetworkTests: XCTestCase {
    func testSharedBackendFixturesDecodeForTheSender() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let network = try decoder.decode(ContactNetwork.self, from: Data(contentsOf: root.appending(path: "contracts/v2/contact-network.response.json")))
        XCTAssertEqual(network.contacts.count, 2)
        XCTAssertEqual(network.policy, .primaryThenOthers)
        let recipients = try decoder.decode([RecipientProgress].self, from: Data(contentsOf: root.appending(path: "contracts/v2/recipients.response.json")))
        XCTAssertNotNil(recipients[0].acknowledgedAt)
        XCTAssertNil(recipients[1].acknowledgedAt)
    }

    func testPoliciesRoundTripWithoutLosingTheirMeaning() throws {
        for policy in ContactRoutingPolicy.allCases {
            XCTAssertEqual(try JSONDecoder().decode(ContactRoutingPolicy.self, from: JSONEncoder().encode(policy)), policy)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ContactRoutingPolicy.self, from: Data("\"police\"".utf8)))
    }

    func testRecipientProgressKeepsDeliveryDistinctFromAcknowledgement() throws {
        let json = #"{"contactId":"82000000-0000-4000-8000-000000000001","name":"Sam","revoked":false,"scheduledAt":"2026-09-28T00:02:00Z","delivery":"queued","acknowledgedAt":"2026-09-28T00:01:00Z"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let progress = try decoder.decode(RecipientProgress.self, from: Data(json.utf8))
        XCTAssertNotNil(progress.acknowledgedAt)
        XCTAssertEqual(progress.summary(at: Date(timeIntervalSince1970: 0)), "Scheduled for escalation")
    }

    func testWithdrawalTakesPrecedenceOverPreviousDelivery() throws {
        let json = #"{"contactId":"82000000-0000-4000-8000-000000000001","name":"Sam","revoked":true,"scheduledAt":"2026-09-28T00:02:00Z","delivery":"delivered"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let progress = try decoder.decode(RecipientProgress.self, from: Data(json.utf8))
        XCTAssertEqual(progress.summary(at: Date()), "Consent withdrawn — access revoked")
    }
}
