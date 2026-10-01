import Foundation

/// Foreground identity verification consumes a short-lived CAPTCHA token. Session refresh
/// and alert submission must never depend on presenting a web challenge.
public enum SignupVerification {
    public static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 2048 && !token.contains(where: { $0.isWhitespace })
    }

    public static func requestBody(token: String) throws -> Data {
        guard validToken(token) else { throw ValidationError.invalidToken }
        return try JSONSerialization.data(withJSONObject: [
            "data": ["signalword_client": true],
            "gotrue_meta_security": ["captcha_token": token],
        ])
    }

    public enum ValidationError: Error { case invalidToken }
}

/// Supabase email OTP protocol. Account creation is explicit; credentials never enter URLs.
public enum InvitedSignIn {
    public static func normalizedEmail(_ email: String) throws -> String {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count <= 254, value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
            throw SignupVerification.ValidationError.invalidToken
        }
        return value
    }
    public static func requestBody(email: String, captchaToken: String, createAccount: Bool = false) throws -> Data {
        guard SignupVerification.validToken(captchaToken) else { throw SignupVerification.ValidationError.invalidToken }
        return try JSONSerialization.data(withJSONObject: [
            "email": normalizedEmail(email), "create_user": createAccount,
            "data": ["signalword_client": true],
            "gotrue_meta_security": ["captcha_token": captchaToken]
        ])
    }
    public static func passwordBody(email: String, password: String, captchaToken: String) throws -> Data {
        guard !password.isEmpty, password.utf8.count <= 4096,
              SignupVerification.validToken(captchaToken) else {
            throw SignupVerification.ValidationError.invalidToken
        }
        // Preserve the password exactly; only the email is normalized.
        return try JSONSerialization.data(withJSONObject: [
            "email": normalizedEmail(email), "password": password,
            "gotrue_meta_security": ["captcha_token": captchaToken]
        ])
    }
    public static func verificationBody(email: String, code: String) throws -> Data {
        // Accept provider-configured 6–10 digit codes; expiry/single-use is server-owned.
        guard (6...10).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw SignupVerification.ValidationError.invalidToken
        }
        return try JSONSerialization.data(withJSONObject: ["email": normalizedEmail(email), "token": code, "type": "email"])
    }
}
