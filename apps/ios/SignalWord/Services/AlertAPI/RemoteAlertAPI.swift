import Foundation

enum AlertAPIError: RetryClassifiableError {
    case networkUnavailable
    case invalidResponse
    case rejected(statusCode: Int)

    var isRetryable: Bool {
        switch self {
        case .networkUnavailable:
            return true
        case .rejected(let statusCode):
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        case .invalidResponse:
            return true
        }
    }
}

struct RemoteAlertAPI: AlertCreating {
    let baseURL: URL
    let bearerToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    let session: URLSession
    let maxAttempts: Int

    init(baseURL: URL, bearerToken: String, maxAttempts: Int = 2) {
        self.init(baseURL: baseURL, maxAttempts: maxAttempts, bearerToken: { _ in bearerToken })
    }

    init(
        baseURL: URL,
        maxAttempts: Int = 2,
        bearerToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.maxAttempts = max(1, min(maxAttempts, 3))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func createAlert(_ command: AlertCommand, location: AlertLocationSnapshot?) async throws -> CreatedAlert {
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v2/alerts"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(command.idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        urlRequest.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        urlRequest.httpBody = try encoder.encode(command.request(location: location))

        var forceRefresh = false
        for attempt in 1...maxAttempts {
            urlRequest.setValue(
                "Bearer \(try await bearerToken(forceRefresh))",
                forHTTPHeaderField: "Authorization"
            )
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch is CancellationError {
                throw AlertAPIError.networkUnavailable
            } catch is URLError {
                if attempt < maxAttempts { continue }
                throw AlertAPIError.networkUnavailable
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AlertAPIError.invalidResponse
            }
            if httpResponse.statusCode == 401, attempt < maxAttempts {
                forceRefresh = true
                continue
            }
            guard [200, 201].contains(httpResponse.statusCode) else {
                let error = AlertAPIError.rejected(statusCode: httpResponse.statusCode)
                guard error.isRetryable, attempt < maxAttempts else { throw error }
                try await Task.sleep(nanoseconds: retryDelayNanoseconds(httpResponse))
                continue
            }

            let decoder = WireDate.decoder()
            do {
                let payload = try decoder.decode(AlertCreationWireResponse.self, from: data)
                return CreatedAlert(eventID: payload.eventID, serverTriggeredAt: payload.serverTriggeredAt)
            } catch {
                throw AlertAPIError.invalidResponse
            }
        }
        throw AlertAPIError.networkUnavailable
    }

    private func retryDelayNanoseconds(_ response: HTTPURLResponse) -> UInt64 {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value) else { return 250_000_000 }
        let boundedSeconds = min(max(seconds, 0), 2)
        return UInt64(boundedSeconds * 1_000_000_000)
    }
}
