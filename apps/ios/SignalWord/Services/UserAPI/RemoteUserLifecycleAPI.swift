import Foundation
import Security


struct RemoteUserLifecycleAPI: ContactNetworkServing, CheckInServing {
    let baseURL: URL
    let sessionManager: SupabaseSessionManager
    let session: URLSession

    init(baseURL: URL, sessionManager: SupabaseSessionManager) {
        self.baseURL = baseURL
        self.sessionManager = sessionManager
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func recoverCheckIn(command: UUID? = nil) async throws -> CheckInSnapshot? {
        try await send(path: "/v2/check-in", method: "GET", body: Optional<EmptyBody>.none,
            response: Optional<CheckInSnapshot>.self, query: command.map { [URLQueryItem(name: "command", value: $0.uuidString)] } ?? [])
    }

    func changeCheckIn(_ command: CheckInCommand) async throws -> CheckInSnapshot {
        struct Input: Encodable, Sendable { let action: CheckInCommand.Action; let timerId: UUID?; let minutes: Int? }
        do { return try await send(path: "/v2/check-in", method: "POST",
            body: Input(action: command.action, timerId: command.timerId, minutes: command.minutes), response: CheckInSnapshot.self,
            extraHeaders: ["Idempotency-Key": command.id.uuidString])
        } catch UserAPIError.rejected(statusCode: 409) { throw CheckInFailure.conflict }
    }

    func contactNetwork(primary: UUID? = nil, policy: ContactRoutingPolicy? = nil) async throws -> ContactNetwork {
        struct Settings: Encodable, Sendable { let primary: UUID?; let policy: ContactRoutingPolicy? }
        let updating = primary != nil || policy != nil
        return try await send(path: "/v2/contact-network", method: updating ? "PUT" : "GET",
            body: updating ? Settings(primary: primary, policy: policy) : nil, response: ContactNetwork.self)
    }

    func saveNetworkContact(contactID: UUID?, name: String, email: String) async throws -> TrustedContactProjection {
        let suffix = contactID.map { "/" + $0.uuidString.lowercased() } ?? ""
        return try await send(path: "/v2/contacts" + suffix, method: "POST",
            body: ContactInput(name: name, email: email), response: TrustedContactProjection.self)
    }

    func recipientProgress(eventID: UUID) async throws -> [RecipientProgress] {
        try await send(path: "/v2/alerts/\(eventID.uuidString.lowercased())/recipients", method: "GET",
            body: Optional<EmptyBody>.none, response: [RecipientProgress].self)
    }

    func profile(displayName: String? = nil) async throws -> ProfileProjection {
        try await send(path: "/v1/profile", method: displayName == nil ? "GET" : "PUT",
            body: displayName.map { ProfileProjection(displayName: $0) }, response: ProfileProjection.self)
    }

    func recover(key: UUID? = nil) async throws -> [AlertStatusProjection] {
        try await send(path: "/v1/alerts/recovery", method: "GET", body: Optional<EmptyBody>.none,
            response: [AlertStatusProjection].self, query: key.map { [URLQueryItem(name: "key", value: $0.uuidString)] } ?? [])
    }

    func requestInvitedCode(email: String, captchaToken: String) async throws {
        try await sessionManager.requestInvitedCode(email: email, captchaToken: captchaToken)
    }

    func verifyInvitedCode(email: String, code: String) async throws {
        try await sessionManager.verifyInvitedCode(email: email, code: code)
    }

    func signInWithPassword(email: String, password: String, captchaToken: String) async throws {
        try await sessionManager.signInWithPassword(email: email, password: password, captchaToken: captchaToken)
    }

    func requestRegistrationCode(email: String, captchaToken: String) async throws {
        try await sessionManager.requestInvitedCode(email: email, captchaToken: captchaToken, createAccount: true)
    }

    func identityID() async throws -> String? { try await sessionManager.identityID() }

    func beginReauthentication() async throws { try await sessionManager.beginReauthentication() }

    func prepareIdentity(captchaToken: String? = nil) async throws {
        _ = try await sessionManager.accessToken(createIfMissing: true, captchaToken: captchaToken)
    }

    func saveContact(name: String, email: String) async throws -> TrustedContactProjection {
        try await send(
            path: "/v1/contacts",
            method: "POST",
            body: ContactInput(name: name, email: email),
            response: TrustedContactProjection.self
        )
    }

    func getContact() async throws -> TrustedContactProjection? {
        do {
            return try await send(
                path: "/v1/contact", method: "GET", body: Optional<EmptyBody>.none,
                response: TrustedContactProjection.self
            )
        } catch UserAPIError.rejected(statusCode: 404) {
            return nil
        }
    }

    func disableContact(contactID: UUID) async throws -> Bool {
        struct Result: Decodable { let disabled: Bool }
        let result = try await send(
            path: "/v1/contacts/\(contactID.uuidString.lowercased())", method: "DELETE",
            body: Optional<EmptyBody>.none, response: Result.self
        )
        return result.disabled
    }

    func getAlertStatus(eventID: UUID) async throws -> AlertStatusProjection {
        try await send(
            path: "/v1/alerts/\(eventID.uuidString.lowercased())", method: "GET",
            body: Optional<EmptyBody>.none, response: AlertStatusProjection.self
        )
    }

    func resolve(eventID: UUID) async throws -> ResolvedAlertProjection {
        try await send(
            path: "/v1/alerts/\(eventID.uuidString.lowercased())/resolve", method: "POST",
            body: Optional<EmptyBody>.none, response: ResolvedAlertProjection.self
        )
    }

    func appendLocation(eventID: UUID, location: AlertLocationSnapshot) async throws {
        let _: LocationAcceptedProjection = try await send(
            path: "/v1/alerts/\(eventID.uuidString.lowercased())/locations", method: "POST",
            body: LocationInput(location: location), response: LocationAcceptedProjection.self
        )
    }

    func deleteAccount() async throws {
        if !UserDefaults.standard.bool(forKey: "serverDeletionConfirmed") {
            let receipt = try deletionReceiptToken()
            if (try? await deletionConfirmed(receipt)) != true {
                do {
                    let _: DeletionReceipt = try await send(
                        path: "/v1/data", method: "DELETE", body: Optional<EmptyBody>.none,
                        response: DeletionReceipt.self,
                        extraHeaders: ["X-Deletion-Receipt": receipt]
                    )
                } catch {
                    guard (try? await deletionConfirmed(receipt)) == true else { throw error }
                }
            }
            UserDefaults.standard.set(true, forKey: "serverDeletionConfirmed")
        }
        try await sessionManager.deleteLocalSession()
    }

    private func deletionReceiptToken() throws -> String {
        if let stored = UserDefaults.standard.string(forKey: "deletionReceiptToken") { return stored }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw UserAPIError.unavailable
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(token, forKey: "deletionReceiptToken")
        return token
    }

    private func deletionConfirmed(_ receipt: String) async throws -> Bool {
        let url = baseURL.deletingLastPathComponent().appending(path: "deletion-status/v1/deletions/status")
        var request = URLRequest(url: url)
        request.setValue(receipt, forHTTPHeaderField: "X-Deletion-Receipt")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UserAPIError.unavailable
        }
        return try JSONDecoder().decode(DeletionStatus.self, from: data).deleted
    }

    private func send<Body: Encodable & Sendable, Output: Decodable & Sendable>(
        path: String,
        method: String,
        body: Body?,
        response: Output.Type, query: [URLQueryItem] = [], extraHeaders: [String: String] = [:]
    ) async throws -> Output {
        let generation = await sessionManager.sessionGeneration()
        for attempt in 0...1 {
            try await sessionManager.requireGeneration(generation)
            let token = try await sessionManager.accessToken(
                createIfMissing: false,
                forceRefresh: attempt == 1
            )
            try await sessionManager.requireGeneration(generation)
            var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { components.queryItems = query }
            guard let url = components.url else { throw UserAPIError.invalidResponse }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
            for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
            }
            let data: Data
            let urlResponse: URLResponse
            do { (data, urlResponse) = try await session.data(for: request) }
            catch { throw UserAPIError.unavailable }
            try await sessionManager.requireGeneration(generation)
            guard let http = urlResponse as? HTTPURLResponse else { throw UserAPIError.invalidResponse }
            if http.statusCode == 401, attempt == 0 { continue }
            if http.statusCode == 401 { throw SessionError.sessionExpired }
            guard (200..<300).contains(http.statusCode) else {
                throw UserAPIError.rejected(statusCode: http.statusCode)
            }
            let decoder = WireDate.decoder()
            do { return try decoder.decode(response, from: data) }
            catch { throw UserAPIError.invalidResponse }
        }
        throw UserAPIError.unavailable
    }
}

private struct ContactInput: Encodable, Sendable { let name: String; let email: String }
private struct EmptyBody: Encodable, Sendable {}
private struct LocationInput: Encodable, Sendable { let location: AlertLocationSnapshot }
private struct LocationAcceptedProjection: Decodable, Sendable {
    let accepted: Bool
    let receivedAt: Date
}
private struct DeletionReceipt: Decodable, Sendable { let deletionID: UUID
    enum CodingKeys: String, CodingKey { case deletionID = "deletionId" }
}
private struct DeletionStatus: Decodable, Sendable { let deleted: Bool }
