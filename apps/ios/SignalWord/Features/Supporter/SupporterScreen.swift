import SwiftUI
import SupporterKit

struct SupporterScreen: View {
    @Bindable var model: SupporterModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Make it yours").font(.largeTitle.bold())
                Text("An optional, one-time purchase unlocks Ocean and Lavender accents and a supporter card. No subscription.")
                Text("All safety features stay free. Purchasing does not change alert priority, delivery, or access to help.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.active {
                    Label("SignalWord supporter", systemImage: "heart.circle.fill")
                        .font(.title2.bold()).foregroundStyle(accent)
                        .padding().frame(maxWidth: .infinity).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                    Text("Appearance").font(.headline)
                    ForEach(["standard", "ocean", "lavender"], id: \.self) { choice in
                        Button { model.select(choice) } label: {
                            HStack {
                                Text(choice.capitalized)
                                Spacer()
                                if model.selectedAppearance == choice {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("supporter.appearance." + choice)
                        .accessibilityAddTraits(model.selectedAppearance == choice ? [.isSelected] : [])
                    }
                } else if let offer = model.offer {
                    Button("Unlock appearance · \(offer.price)") { Task { await model.buy() } }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                        .accessibilityIdentifier("supporter.buy")
                } else {
                    Text("Purchases are not available right now. You can continue using SignalWord.")
                }
                if model.busy { ProgressView("Checking with the store…") }
                if let message = model.message { Text(message).accessibilityIdentifier("supporter.message") }
                Button("Restore purchases") { Task { await model.restore() } }
                    .disabled(model.busy).accessibilityIdentifier("supporter.restore")
                Button("Refresh purchase status") { Task { await model.refresh() } }.disabled(model.busy)
                Text("Purchases use your store account and RevenueCat. Your safety account and contact details are not sent to RevenueCat. Deleting your safety account does not refund a store purchase.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Privacy and purchase information", destination: URL(string: "https://www.signalword.app/privacy")!)
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .navigationTitle("Supporter appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await model.refresh() }
    }
    private var accent: Color {
        SignalWordAccent(appearance: model.selectedAppearance).link
    }
}


@MainActor enum SupporterComposition {
    static func makeModel() -> SupporterModel {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return SupporterModel(service: PreviewBilling(), preferences: UserDefaults(suiteName: "SignalWord.SupporterUITests")!)
        }
        #endif
        return SupporterModel(service: RevenueCatSupporterService(
            apiKey: Bundle.main.object(forInfoDictionaryKey: "SignalWordRevenueCatAPIKey") as? String ?? "",
            allowTestStore: {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }()))
    }
}
#if DEBUG && targetEnvironment(simulator)
/// A deterministic UI fixture, never compiled into a device or Release build.
@MainActor private final class PreviewBilling: SupporterService {
    private let preferences = UserDefaults(suiteName: "SignalWord.SupporterUITests")!
    private var purchased: Bool {
        get { preferences.bool(forKey: "fixture.purchased") }
        set { preferences.set(newValue, forKey: "fixture.purchased") }
    }
    init() {
        if ProcessInfo.processInfo.arguments.contains("--reset-ui-state") {
            preferences.removePersistentDomain(forName: "SignalWord.SupporterUITests")
        }
    }
    func offer() async throws -> SupporterOffer? { .init(price: "TEST $4.99") }
    func isActive() async throws -> Bool { purchased }
    func purchase() async throws -> SupporterPurchaseResult { purchased = true; return .active }
    func restore() async throws -> Bool { purchased }
}
#endif
