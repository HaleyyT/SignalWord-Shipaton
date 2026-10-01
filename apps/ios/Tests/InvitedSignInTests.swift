import XCTest
@testable import SignalWordCore

private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DeviceCredentialStore.Session?
    func load() -> DeviceCredentialStore.Session? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ session: DeviceCredentialStore.Session) { lock.lock(); defer { lock.unlock() }; value = session }
    func clear() { lock.lock(); defer { lock.unlock() }; value = nil }
}

final class InvitedSignInTests: XCTestCase {
    private let origin = URL(string: "https://development.example.invalid")!
    private let success = Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8)
    private func manager(_ box: SessionBox, transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) -> SupabaseSessionManager {
        SupabaseSessionManager(supabaseURL: origin, publishableKey: "public", load: { box.load() }, save: { box.save($0) }, clear: { box.clear() }, transport: transport)
    }
    func testOTPContractNeverCreatesUserAndRejectsInvalidInput() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: InvitedSignIn.requestBody(email: " Invited@Example.com ", captchaToken: "proof")) as? [String: Any])
        XCTAssertEqual(body["create_user"] as? Bool, false)
        XCTAssertEqual(body["email"] as? String, "invited@example.com")
        XCTAssertEqual((body["gotrue_meta_security"] as? [String:String])?["captcha_token"], "proof")
        for email in ["", "bad", "a b@example.com"] { XCTAssertThrowsError(try InvitedSignIn.requestBody(email: email, captchaToken: "proof")) }
        for proof in ["", "bad proof"] { XCTAssertThrowsError(try InvitedSignIn.requestBody(email: "a@example.com", captchaToken: proof)) }
        for code in ["", "12345", "12345x", "１２３４５６", "12345678901"] { XCTAssertThrowsError(try InvitedSignIn.verificationBody(email: "a@example.com", code: code)) }
    }
    func testMissingIdentityCannotCreateAnonymousAccount() async {
        let m = manager(SessionBox()) { _ in XCTFail("No network call expected"); throw URLError(.badURL) }
        do { _ = try await m.accessToken(createIfMissing: true, captchaToken: "proof"); XCTFail() }
        catch { XCTAssertEqual(error as? SessionError, .verificationRequired) }
    }
    func testRequestDoesNotPersistIdentityAndVerificationSurvivesRelaunch() async throws {
        let box = SessionBox(); let payload = success
        let m = manager(box) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.url?.query)
            return (request.url?.path == "/auth/v1/otp" ? Data("{}".utf8) : payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await m.requestInvitedCode(email: "a@example.com", captchaToken: "proof")
        XCTAssertNil(box.load())
        try await m.verifyInvitedCode(email: "a@example.com", code: "123456")
        let relaunched = manager(box) { _ in XCTFail("Unexpired session must be reused"); throw URLError(.badURL) }
        let token = try await relaunched.accessToken(createIfMissing: false)
        XCTAssertEqual(token, "access")
        try await relaunched.deleteLocalSession()
        XCTAssertNil(box.load())
    }
    func testServerRejectionForExpiredReplayedOrUninvitedProofNeverSavesSession() async {
        for status in [400,401,403,422,429,500] {
            let box = SessionBox()
            let m = manager(box) { request in (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
            do { try await m.verifyInvitedCode(email: "a@example.com", code: "123456"); XCTFail() } catch {}
            XCTAssertNil(box.load())
            do { try await m.requestInvitedCode(email: "a@example.com", captchaToken: "proof"); XCTFail() } catch {}
            XCTAssertNil(box.load())
        }
    }
    func testOfflineRequestDoesNotCreateSession() async {
        let box = SessionBox(); let m = manager(box) { _ in throw URLError(.notConnectedToInternet) }
        do { try await m.requestInvitedCode(email: "a@example.com", captchaToken: "proof"); XCTFail() } catch {}
        XCTAssertNil(box.load())
    }
    func testDeletionDuringVerificationCannotRestoreCredentials() async throws {
        let box = SessionBox(); let payload = success
        let started = expectation(description: "verification started")
        let m = manager(box) { request in
            started.fulfill()
            // Deliberately ignores cancellation to simulate a late network response.
            try? await Task.sleep(nanoseconds: 200_000_000)
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let pending = Task { try await m.verifyInvitedCode(email: "a@example.com", code: "123456") }
        await fulfillment(of: [started], timeout: 2)
        try await m.deleteLocalSession()
        do { try await pending.value; XCTFail() } catch {}
        XCTAssertNil(box.load())
    }
    func testPasswordSignInUsesProtectedBodyAndPersistsOnlyTokens() async throws {
        let box = SessionBox(); let payload = success
        let m = manager(box) { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(request.url?.query, "grant_type=password")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["email"] as? String, "review@example.com")
            XCTAssertEqual(body["password"] as? String, " exact password ")
            XCTAssertEqual((body["gotrue_meta_security"] as? [String: String])?["captcha_token"], "proof")
            XCTAssertNil(body["create_user"])
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await m.signInWithPassword(email: " Review@Example.com ", password: " exact password ", captchaToken: "proof")
        XCTAssertEqual(box.load()?.accessToken, "access")
        let relaunched = manager(box) { _ in XCTFail("Reuse valid session"); throw URLError(.badURL) }
        let token = try await relaunched.accessToken(createIfMissing: false)
        XCTAssertEqual(token, "access")
    }
    func testInvalidPasswordInputNeverReachesNetwork() async {
        let m = manager(SessionBox()) { _ in XCTFail("Invalid input must not be sent"); throw URLError(.badURL) }
        for (email, password, captcha) in [("bad", "password", "proof"), ("a@example.com", "", "proof"), ("a@example.com", "password", "")] {
            do { try await m.signInWithPassword(email: email, password: password, captchaToken: captcha); XCTFail() } catch {}
        }
    }
    func testRejectedPasswordNeverCreatesSession() async {
        for status in [400, 401, 403, 422, 429, 500] {
            let box = SessionBox()
            let m = manager(box) { request in
                (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { try await m.signInWithPassword(email: "a@example.com", password: "wrong", captchaToken: "proof"); XCTFail() } catch {}
            XCTAssertNil(box.load())
        }
    }
    func testDeletionDuringPasswordSignInCannotRestoreSession() async throws {
        let box = SessionBox(); let payload = success
        let started = expectation(description: "password request started")
        let m = manager(box) { request in
            started.fulfill()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let pending = Task { try await m.signInWithPassword(email: "a@example.com", password: "password", captchaToken: "proof") }
        await fulfillment(of: [started], timeout: 2)
        try await m.deleteLocalSession()
        do { try await pending.value; XCTFail() } catch {}
        XCTAssertNil(box.load())
    }

}
