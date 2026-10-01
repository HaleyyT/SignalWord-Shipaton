import Foundation
import Observation

public struct SupporterOffer: Equatable, Sendable {
    public let price: String
    public init(price: String) { self.price = price }
}
public enum SupporterPurchaseResult: Sendable { case active, cancelled, pending }

/// Billing is deliberately independent of safety identity, contacts and delivery APIs.
@MainActor public protocol SupporterService {
    func offer() async throws -> SupporterOffer?
    func isActive() async throws -> Bool
    func purchase() async throws -> SupporterPurchaseResult
    func restore() async throws -> Bool
}

@MainActor @Observable public final class SupporterModel {
    public private(set) var offer: SupporterOffer?
    public private(set) var active = false
    public private(set) var hasStarted = false
    public private(set) var busy = false
    public private(set) var message: String?
    public private(set) var appearance: String
    private let service: any SupporterService
    private let preferences: UserDefaults
    private static let preferenceKey = "signalword.supporter.appearance"
    public init(service: any SupporterService, preferences: UserDefaults = .standard) {
        self.service = service
        self.preferences = preferences
        self.appearance = preferences.string(forKey: Self.preferenceKey) ?? "standard"
    }
    public var selectedAppearance: String { active ? appearance : "standard" }
    public func select(_ value: String) {
        guard active, ["standard", "ocean", "lavender"].contains(value) else { return }
        appearance = value
        preferences.set(value, forKey: Self.preferenceKey)
    }
    public func refresh() async {
        guard !busy else { return }
        busy = true; message = nil; hasStarted = true
        defer { busy = false }
        // Entitlement refresh is separate from products: an unavailable offering must
        // not prevent an existing customer from recovering their appearance.
        do { active = try await service.isActive() }
        catch { message = "Could not check your purchase. Safety features are still available." }
        do { offer = try await service.offer() }
        catch { offer = nil; message = "Purchases are unavailable. Try again later; safety features are unaffected." }
    }
    public func buy() async {
        guard !busy, offer != nil, !active else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            switch try await service.purchase() {
            case .active: active = true; message = "Supporter appearance unlocked. Thank you."
            case .cancelled: message = "Purchase cancelled. You have not unlocked a new purchase."
            case .pending: message = "Purchase is pending confirmation. Refresh after it is approved."
            }
        } catch { message = "Purchase could not be confirmed. Try Restore purchases before buying again." }
    }
    public func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            active = try await service.restore()
            message = active ? "Your supporter purchase is restored." : "No supporter purchase was found for this store account."
        } catch { message = "Could not restore purchases. Check your connection and try again." }
    }
}
