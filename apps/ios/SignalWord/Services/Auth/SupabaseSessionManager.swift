import Foundation

enum SessionError: RetryClassifiableError {
    var isRetryable: Bool { self == .unavailable || self == .invalidResponse }
    case invalidCredentials, captchaFailed, rateLimited, sessionExpired, differentAccount

    var message: String {
        switch self {
        case .invalidCredentials: "The email or password was not accepted. Try again or use Forgot password."
        case .captchaFailed: "Verification was not accepted. Complete a new CAPTCHA and try again."
        case .rateLimited: "Too many attempts. Wait a few minutes before trying again."
        case .differentAccount: "Sign in to the same account to recover this device’s alerts and timers."
        case .sessionExpired, .verificationRequired: "Sign in again to recover your account. Server check-in timers continue while you are signed out."
        case .configuration: "Account verification is unavailable in this build. Contact support."
        case .unavailable, .invalidResponse: "The account service could not be reached or confirmed. Check your connection and retry."
        }
    }
    case verificationRequired
    case configuration
    case unavailable
    case invalidResponse
}

actor SupabaseSessionManager {
    private let supabaseURL: URL
    private let publishableKey: String
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let load: @Sendable () throws -> DeviceCredentialStore.Session?
    private let save: @Sendable (DeviceCredentialStore.Session) throws -> Void
    private let clear: @Sendable () throws -> Void
    private var generation = 0
    private var reauthenticationUserID: String?
    private func restoreRecoveryConstraint() throws {
        if let expected = try load()?.reauthenticationUserID { reauthenticationUserID = expected }
    }

    /// Retain account identity, server data and queued commands. Bind the
    /// next authenticated response to the previous identity before saving any token.
    func beginReauthentication() throws {
        guard let stored = try load(), let userID = stored.userID ?? Self.subject(stored.accessToken) else {
            throw SessionError.configuration
        }
        try save(.init(accessToken: stored.accessToken, refreshToken: stored.refreshToken,
                       expiresAt: stored.expiresAt, userID: userID, reauthenticationUserID: userID))
        reauthenticationUserID = userID
        generation += 1
        tokenTask?.cancel()
        tokenTask = nil
    }

    private static func subject(_ token: String) -> String? {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["sub"] as? String, UUID(uuidString: value) != nil else { return nil }
        return value
    }
    private let now: @Sendable () -> Date
    private var tokenTask: Task<DeviceCredentialStore.Session, Error>?

    init(
        supabaseURL: URL,
        publishableKey: String,
        session: URLSession = SupabaseSessionManager.makeSession(),
        now: @escaping @Sendable () -> Date = { Date() },
        load: @escaping @Sendable () throws -> DeviceCredentialStore.Session? = { try DeviceCredentialStore.loadSession() },
        save: @escaping @Sendable (DeviceCredentialStore.Session) throws -> Void = { try DeviceCredentialStore.saveSession($0) },
        clear: @escaping @Sendable () throws -> Void = { try DeviceCredentialStore.clear() },
        transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.send = transport ?? { try await session.data(for: $0) }
        self.load = load
        self.save = save
        self.clear = clear
        self.now = now
    }

    func accessToken(createIfMissing: Bool, forceRefresh: Bool = false, captchaToken: String? = nil) async throws -> String {
        try restoreRecoveryConstraint()
        if reauthenticationUserID != nil { throw SessionError.sessionExpired }
        if let tokenTask { return try await tokenTask.value.accessToken }
        if let stored = try load() {
            if !forceRefresh && stored.expiresAt.timeIntervalSince(now()) > 120 {
                return stored.accessToken
            }
            let requestGeneration = generation
            let task = Task { try await self.refresh(stored, generation: requestGeneration) }
            tokenTask = task
            defer { if generation == requestGeneration { tokenTask = nil } }
            return try await task.value.accessToken
        }
        guard createIfMissing else { throw SessionError.verificationRequired }
        // Missing credentials require explicit email sign-in or registration.
        // Never create an anonymous account, including from an App Intent.
        throw SessionError.verificationRequired
    }

    func requestInvitedCode(email: String, captchaToken: String, createAccount: Bool = false) async throws {
        try restoreRecoveryConstraint()
        guard tokenTask == nil, try load() == nil || reauthenticationUserID != nil else { throw SessionError.configuration }
        let requestGeneration = generation
        var request = request(path: "/auth/v1/otp")
        request.httpMethod = "POST"
        guard !createAccount || reauthenticationUserID == nil else { throw SessionError.configuration }
        request.httpBody = try InvitedSignIn.requestBody(email: email, captchaToken: captchaToken, createAccount: createAccount)
        let (data, response) = try await send(request)
        guard generation == requestGeneration, !Task.isCancelled else { throw CancellationError() }
        try Self.validate(response, data: data, refreshing: false)
    }

    func verifyInvitedCode(email: String, code: String) async throws {
        try restoreRecoveryConstraint()
        guard tokenTask == nil, try load() == nil || reauthenticationUserID != nil else { throw SessionError.configuration }
        var request = request(path: "/auth/v1/verify")
        request.httpMethod = "POST"
        request.httpBody = try InvitedSignIn.verificationBody(email: email, code: code)
        let requestGeneration = generation
        let task = Task { try await self.perform(request, fallbackRefreshToken: nil, generation: requestGeneration) }
        tokenTask = task
        defer { if generation == requestGeneration { tokenTask = nil } }
        _ = try await task.value
    }

    func signInWithPassword(email: String, password: String, captchaToken: String) async throws {
        try restoreRecoveryConstraint()
        guard tokenTask == nil, try load() == nil || reauthenticationUserID != nil else { throw SessionError.configuration }
        var components = URLComponents(url: supabaseURL.appending(path: "/auth/v1/token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        guard let url = components?.url else { throw SessionError.configuration }
        var request = request(path: "/auth/v1/token")
        request.url = url
        request.httpMethod = "POST"
        request.httpBody = try InvitedSignIn.passwordBody(email: email, password: password, captchaToken: captchaToken)
        let requestGeneration = generation
        let task = Task { try await self.perform(request, fallbackRefreshToken: nil, generation: requestGeneration) }
        tokenTask = task
        defer { if generation == requestGeneration { tokenTask = nil } }
        _ = try await task.value
    }

    func identityID() throws -> String? {
        guard let stored = try load() else { return nil }
        return stored.userID ?? Self.subject(stored.accessToken)
    }

    func sessionGeneration() -> Int { generation }

    func requireGeneration(_ expected: Int) throws {
        guard expected == generation else { throw CancellationError() }
    }

    func deleteLocalSession() throws {
        // Invalidate outstanding responses even if their transport ignores cancellation.
        // Otherwise a late refresh/signup could recreate credentials after deletion.
        generation += 1
        tokenTask?.cancel()
        tokenTask = nil
        try clear()
        reauthenticationUserID = nil
    }

    private func refresh(_ existing: DeviceCredentialStore.Session, generation: Int) async throws -> DeviceCredentialStore.Session {
        var components = URLComponents(
            url: supabaseURL.appending(path: "/auth/v1/token"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = components?.url else { throw SessionError.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": existing.refreshToken])
        return try await perform(request, fallbackRefreshToken: existing.refreshToken, generation: generation)
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: supabaseURL.appending(path: path))
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(
        _ request: URLRequest,
        fallbackRefreshToken: String?,
        generation requestGeneration: Int
    ) async throws -> DeviceCredentialStore.Session {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await send(request) }
        catch { throw SessionError.unavailable }
        guard generation == requestGeneration, !Task.isCancelled else { throw CancellationError() }
        try Self.validate(response, data: data, refreshing: fallbackRefreshToken != nil)
        let decoded: AuthResponse
        do { decoded = try JSONDecoder().decode(AuthResponse.self, from: data) }
        catch { throw SessionError.invalidResponse }
        let refreshToken = decoded.refreshToken ?? fallbackRefreshToken
        guard !decoded.accessToken.isEmpty, let refreshToken, !refreshToken.isEmpty,
              decoded.expiresIn > 0 else { throw SessionError.invalidResponse }
        let stored = DeviceCredentialStore.Session(
            accessToken: decoded.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(decoded.expiresIn)),
            userID: try decoded.user?.id ?? load()?.userID
        )
        guard generation == requestGeneration, !Task.isCancelled else { throw CancellationError() }
        if let expected = reauthenticationUserID, decoded.user?.id != expected { throw SessionError.differentAccount }
        try save(stored)
        reauthenticationUserID = nil
        return stored
    }

    private static func validate(_ response: URLResponse, data: Data, refreshing: Bool) throws {
        guard let http = response as? HTTPURLResponse else { throw SessionError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        // Match only allowlisted provider codes; never expose a response body or token.
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let code = (object?["code"] ?? object?["error_code"]) as? String
        if http.statusCode == 429 { throw SessionError.rateLimited }
        if http.statusCode >= 500 { throw SessionError.unavailable }
        if code == "captcha_failed" { throw SessionError.captchaFailed }
        if refreshing && [400, 401, 403].contains(http.statusCode) { throw SessionError.sessionExpired }
        if code == "invalid_credentials" || http.statusCode == 401 { throw SessionError.invalidCredentials }
        throw SessionError.unavailable
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

private struct AuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let user: AuthUser?
    struct AuthUser: Decodable { let id: String }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}
