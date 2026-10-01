import XCTest
@testable import SignalWordCore

final class SignupVerificationTests: XCTestCase {
    func testSignupUsesSupabaseCaptchaContract() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SignupVerification.requestBody(token: "short-lived-test-token")) as? [String: Any])
        XCTAssertEqual((body["gotrue_meta_security"] as? [String: String])?["captcha_token"], "short-lived-test-token")
        XCTAssertEqual((body["data"] as? [String: Bool])?["signalword_client"], true)
    }

    func testMissingOversizedAndWhitespaceTokensAreRejected() {
        for token in ["", " ", "token\n", String(repeating: "x", count: 2049)] {
            XCTAssertThrowsError(try SignupVerification.requestBody(token: token))
        }
    }
}
