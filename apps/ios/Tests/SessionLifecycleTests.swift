import Foundation
import XCTest
@testable import SignalWordCore

final class SessionLifecycleTests: XCTestCase {
    private let origin = URL(string: "https://example.invalid")!
    private let now = Date(timeIntervalSince1970: 1_000)

    func testMissingIdentityRequiresCaptchaWithoutNetworkRequest() async throws {
        let store = MemoryCredentials()
        let manager = makeManager(store) { _ in XCTFail("Signup must not run without proof"); throw URLError(.badURL) }
        do { _ = try await manager.accessToken(createIfMissing: true); XCTFail("Expected verification") }
        catch let error as SessionError { XCTAssertEqual(error, .verificationRequired) }
        XCTAssertNil(store.value)
    }

    func testUnavailableCredentialsNeverCreateAnotherIdentity() async throws {
        let manager = SupabaseSessionManager(supabaseURL: origin, publishableKey: "public-test-key",
            load: { throw KeychainError.invalidSession }, transport: { _ in
                XCTFail("Unreadable credentials must not trigger signup"); throw URLError(.badURL)
            })
        do { _ = try await manager.accessToken(createIfMissing: true, captchaToken: "proof"); XCTFail("Expected Keychain error") }
        catch is KeychainError { }
    }

    func testValidStoredSessionNeedsNeitherCaptchaNorNetwork() async throws {
        let store = MemoryCredentials(session(expiry: now.addingTimeInterval(600)))
        let manager = makeManager(store) { _ in XCTFail("A valid session needs no request"); throw URLError(.badURL) }
        let token = try await manager.accessToken(createIfMissing: false)
        XCTAssertEqual(token, "old-access")
    }

    func testInvitedVerificationSavesSession() async throws {
        let store = MemoryCredentials()
        let manager = makeManager(store) { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/verify")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            XCTAssertEqual(body?["type"] as? String, "email")
            return self.response(request)
        }
        try await manager.verifyInvitedCode(email: "a@example.com", code: "123456")
        let token = try await manager.accessToken(createIfMissing: false)
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(store.value?.refreshToken, "new-refresh")
        XCTAssertEqual(store.value?.expiresAt, now.addingTimeInterval(3600))
    }

    func testRefreshPreservesIdentityAndDoesNotSendCaptcha() async throws {
        let store = MemoryCredentials(session(expiry: now))
        let manager = makeManager(store) { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
            XCTAssertEqual(body, ["refresh_token": "old-refresh"])
            return self.response(request)
        }
        let token = try await manager.accessToken(createIfMissing: true)
        XCTAssertEqual(token, "new-access")
    }

    func testRejectedRefreshDoesNotFallBackToSignupOrEraseCredentials() async throws {
        let initial = session(expiry: now)
        let store = MemoryCredentials(initial)
        let manager = makeManager(store) { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            return self.response(request, status: 401)
        }
        do { _ = try await manager.accessToken(createIfMissing: true); XCTFail("Expected rejection") }
        catch let error as SessionError { XCTAssertEqual(error, .sessionExpired) }
        XCTAssertEqual(store.value, initial)
    }

    func testMalformedResponseIsRetryClassifiedWithoutErasingCredentials() async throws {
        let initial = session(expiry: now)
        let store = MemoryCredentials(initial)
        let manager = makeManager(store) { request in
            (Data("not-json".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await manager.accessToken(createIfMissing: false); XCTFail("Expected invalid response") }
        catch let error as SessionError { XCTAssertEqual(error, .invalidResponse); XCTAssertTrue(error.isRetryable) }
        XCTAssertEqual(store.value, initial)
    }

    func testDeletionPreventsLateSignupAndRefreshFromRestoringCredentials() async throws {
        for initial in [nil, session(expiry: now)] {
            let store = MemoryCredentials(initial)
            let transport = SuspendedTransport()
            let manager = makeManager(store) { request in await transport.send(request) }
            let request = Task {
                if initial == nil { try await manager.verifyInvitedCode(email: "a@example.com", code: "123456") }
                else { _ = try await manager.accessToken(createIfMissing: false) }
            }
            await transport.waitUntilStarted()
            try await manager.deleteLocalSession()
            XCTAssertNil(store.value)
            // Deliberately ignore cancellation to model a response already in flight.
            await transport.finish()
            do { _ = try await request.value; XCTFail("A deleted generation cannot succeed") }
            catch is CancellationError { }
            XCTAssertNil(store.value, "Late auth must not resurrect a deleted device session")
        }
    }

    func testNewSignupSurvivesCompletionOfAnOlderDeletedRefresh() async throws {
        let store = MemoryCredentials(session(expiry: now))
        let oldTransport = SuspendedTransport()
        let newTransport = SuspendedTransport()
        let manager = makeManager(store) { request in
            if request.url?.path == "/auth/v1/token" { return await oldTransport.send(request) }
            return await newTransport.send(request)
        }
        let oldRequest = Task { try await manager.accessToken(createIfMissing: false) }
        await oldTransport.waitUntilStarted()
        try await manager.deleteLocalSession()
        let newRequest = Task { try await manager.verifyInvitedCode(email: "a@example.com", code: "123456") }
        await newTransport.waitUntilStarted()
        await oldTransport.finish()
        do { _ = try await oldRequest.value; XCTFail("Old refresh must be invalidated") }
        catch is CancellationError { }
        XCTAssertNil(store.value)
        await newTransport.finish()
        try await newRequest.value
        let token = try await manager.accessToken(createIfMissing: false)
        XCTAssertEqual(store.value?.accessToken, token, "A deliberate new signup must remain usable")
    }

    func testSignOutInvalidatesOldAPIResponsesAndAllowsExistingAccountLogin() async throws {
        let store = MemoryCredentials(session(expiry: now.addingTimeInterval(600)))
        let manager = makeManager(store) { self.response($0) }
        let version = await manager.sessionGeneration()
        try await manager.deleteLocalSession()
        do { try await manager.requireGeneration(version); XCTFail("Old account response must be discarded") }
        catch is CancellationError { }
        XCTAssertNil(store.value)
        try await manager.signInWithPassword(email: "another@example.test", password: "fixture-password", captchaToken: "proof")
        XCTAssertNotNil(store.value)
        do { try await manager.requireGeneration(version); XCTFail("Re-login must not revive the previous generation") }
        catch is CancellationError { }
    }

    func testPasswordErrorsAreActionableAndNeverSaveCredentials() async throws {
        for (code, status, expected) in [("invalid_credentials", 400, SessionError.invalidCredentials),
            ("captcha_failed", 400, .captchaFailed), ("over_request_rate_limit", 429, .rateLimited),
            ("unexpected_failure", 503, .unavailable)] {
            let store = MemoryCredentials()
            let manager = makeManager(store) { request in
                (try JSONSerialization.data(withJSONObject: ["error_code": code]),
                 HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { try await manager.signInWithPassword(email: "a@example.test", password: "fixture", captchaToken: "proof"); XCTFail("Expected classified rejection") }
            catch let error as SessionError { XCTAssertEqual(error, expected) }
            XCTAssertNil(store.value)
        }
    }

    func testOnlyExplicitRegistrationMayCreateAnAccount() async throws {
        for create in [false, true] {
            let manager = makeManager(MemoryCredentials()) { request in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(body["create_user"] as? Bool, create)
                XCTAssertNotNil(body["gotrue_meta_security"])
                return self.response(request)
            }
            try await manager.requestInvitedCode(email: "a@example.test", captchaToken: "proof", createAccount: create)
        }
    }

    func testRecoveryRejectsAccountSwitchEvenAfterRelaunch() async throws {
        let owner = "10000000-0000-4000-8000-000000000001"
        let initial = DeviceCredentialStore.Session(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now, userID: owner)
        let store = MemoryCredentials(initial)
        let first = makeManager(store) { self.response($0) }
        try await first.beginReauthentication()
        XCTAssertEqual(store.value?.reauthenticationUserID, owner)
        let relaunched = makeManager(store) { request in
            (Data(#"{"access_token":"other","refresh_token":"other-refresh","expires_in":3600,"user":{"id":"20000000-0000-4000-8000-000000000002"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { try await relaunched.signInWithPassword(email: "other@example.test", password: "fixture", captchaToken: "proof"); XCTFail("Must not switch") }
        catch let error as SessionError { XCTAssertEqual(error, .differentAccount) }
        XCTAssertEqual(store.value?.accessToken, "old-access")
        do { _ = try await relaunched.accessToken(createIfMissing: false); XCTFail("Actions remain suspended") }
        catch let error as SessionError { XCTAssertEqual(error, .sessionExpired) }
    }

    func testRecoveryOfSameIdentityClearsConstraintAndPreservesUID() async throws {
        let owner = "10000000-0000-4000-8000-000000000001"
        let store = MemoryCredentials(.init(accessToken: "old", refreshToken: "old-refresh", expiresAt: now, userID: owner))
        let manager = makeManager(store) { request in
            (Data(#"{"access_token":"renewed","refresh_token":"new-refresh","expires_in":3600,"user":{"id":"10000000-0000-4000-8000-000000000001"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await manager.beginReauthentication()
        try await manager.verifyInvitedCode(email: "a@example.test", code: "123456")
        XCTAssertEqual(store.value?.userID, owner)
        XCTAssertNil(store.value?.reauthenticationUserID)
        let token = try await manager.accessToken(createIfMissing: false)
        XCTAssertEqual(token, "renewed")
    }

    private func makeManager(_ store: MemoryCredentials,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) -> SupabaseSessionManager {
        let now = now
        return SupabaseSessionManager(supabaseURL: origin, publishableKey: "public-test-key", now: { now },
            load: { store.value }, save: { store.value = $0 }, clear: { store.value = nil }, transport: transport)
    }
    private func session(expiry: Date) -> DeviceCredentialStore.Session {
        .init(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: expiry)
    }
    private func response(_ request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

// The production adapter uses Keychain; this locked store makes concurrent test
// access deterministic without reading or modifying the developer's credentials.
private final class MemoryCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DeviceCredentialStore.Session?
    init(_ value: DeviceCredentialStore.Session? = nil) { stored = value }
    var value: DeviceCredentialStore.Session? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private actor SuspendedTransport {
    private var response: CheckedContinuation<(Data, URLResponse), Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var request: URLRequest?
    func send(_ request: URLRequest) async -> (Data, URLResponse) {
        self.request = request
        started?.resume(); started = nil
        return await withCheckedContinuation { response = $0 }
    }
    func waitUntilStarted() async {
        if request != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        let data = Data(#"{"access_token":"late-access","refresh_token":"late-refresh","expires_in":3600}"#.utf8)
        response?.resume(returning: (data, HTTPURLResponse(url: request!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        response = nil
    }
}
