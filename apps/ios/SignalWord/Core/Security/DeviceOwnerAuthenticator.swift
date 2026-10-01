import LocalAuthentication

enum DeviceOwnerAuthenticator {
    static func authenticateResolution() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Keep alert active"
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to resolve the active SignalWord alert."
            )
        } catch {
            return false
        }
    }
}
