import Foundation
import RevenueCat

@MainActor public final class RevenueCatSupporterService: SupporterService {
    public static let entitlement = "supporter"
    public static let offering = "supporter"
    public static let product = "com.signalword.supporter.appearance"
    private let apiKey: String
    private let allowTestStore: Bool
    private var package: Package?
    public init(apiKey: String, allowTestStore: Bool = false) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.allowTestStore = allowTestStore
    }
    public static func validKey(_ key: String, allowTestStore: Bool) -> Bool {
        (key.hasPrefix("appl_") || (allowTestStore && key.hasPrefix("test_"))) && key.count > 10
    }
    private func client() throws -> Purchases {
        guard Self.validKey(apiKey, allowTestStore: allowTestStore) else { throw BillingError.unconfigured }
        if !Purchases.isConfigured {
            // Use RevenueCat's separate anonymous billing ID. Never attach the safety
            // account ID, recipient addresses, phrases or locations as attributes.
            Purchases.configure(withAPIKey: apiKey)
        }
        return Purchases.shared
    }
    public func offer() async throws -> SupporterOffer? {
        let offerings = try await client().offerings()
        package = offerings.all[Self.offering]?.availablePackages.first {
            $0.storeProduct.productIdentifier == Self.product && $0.packageType == .lifetime
                && $0.storeProduct.productType == .nonConsumable
        }
        return package.map { SupporterOffer(price: $0.storeProduct.localizedPriceString) }
    }
    public func isActive() async throws -> Bool {
        let info = try await client().customerInfo()
        return info.entitlements[Self.entitlement]?.isActive == true
    }
    public func purchase() async throws -> SupporterPurchaseResult {
        guard let package else { throw BillingError.unconfigured }
        do {
            let result = try await client().purchase(package: package)
            if result.userCancelled { return .cancelled }
            return result.customerInfo.entitlements[Self.entitlement]?.isActive == true ? .active : .pending
        } catch {
            let code = (error as NSError).code
            if code == ErrorCode.purchaseCancelledError.rawValue { return .cancelled }
            if code == ErrorCode.paymentPendingError.rawValue { return .pending }
            throw error
        }
    }
    public func restore() async throws -> Bool {
        let info = try await client().restorePurchases()
        return info.entitlements[Self.entitlement]?.isActive == true
    }
    private enum BillingError: Error { case unconfigured }
}
