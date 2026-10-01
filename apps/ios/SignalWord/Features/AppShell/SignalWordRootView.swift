import SwiftUI
import Observation
import SupporterKit

private enum SignalTab: Hashable {
    case home, people, settings

    var title: String {
        switch self {
        case .home: "Home"
        case .people: "People"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .people: "person.2.fill"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct SignalWordRootView: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var network: ContactNetworkModel = {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return ContactNetworkModel(api: ProcessInfo.processInfo.arguments.contains("--network-ui-testing") ? UITestNetworkService() : nil)
        }
        #endif
        return ContactNetworkModel(api: AppCompositionRoot.lifecycleAPI)
    }()
    @State private var timer: CheckInModel = {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return CheckInModel(api: ProcessInfo.processInfo.arguments.contains("--timer-ui-testing") ? UITestCheckInService() : nil,
                preferences: UserDefaults(suiteName: "SignalWord.UIJourney")!, remindersEnabled: false)
        }
        #endif
        return CheckInModel(api: AppCompositionRoot.lifecycleAPI)
    }()
    @Bindable var model: AppShellModel
    @State private var supporter = SupporterComposition.makeModel()
    @State private var selectedTab: SignalTab = .home
    @State private var showDeleteConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var isConfirmingSignOut = false
    @State private var showContactEditor = false

    private var accent: SignalWordAccent { SignalWordAccent(appearance: supporter.selectedAppearance) }

    var body: some View {
        Group {
            if model.hasEnteredDashboard && !model.needsIdentityVerification {
                mainTabs
            } else {
                SignalWordSetupFlow(model: model)
            }
        }
        .disabled(model.isSigningOut)
        .environment(network)
        .environment(timer)
        .onChange(of: timer.snapshot?.incidentId) { _, incident in
            if incident != nil { Task { await model.recover() } }
        }
        .onChange(of: model.hasEnteredDashboard) { _, entered in if !entered { network.clear(); timer.clear() } }
        .accessibilityValue("Appearance: " + supporter.selectedAppearance)
        .environment(\.signalWordAccent, accent)
        .tint(accent.link)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showContactEditor, onDismiss: { model.cancelContactEdit() }) {
            ContactEditorSheet(model: model).environment(\.dynamicTypeSize, textSize).environment(\.signalWordAccent, accent)
        }
        .task(id: scenePhase) {
            // Restore the saved accent on cold launch, before the purchase screen is opened.
            // Billing identity is independent of the safety account.
            if scenePhase == .active { await supporter.refresh() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Own both initial and periodic recovery here. A separate startup
            // task can retry immediately and race the first recovery result.
            while !Task.isCancelled {
                // Finish any current read before confirmation is enabled, then
                // avoid starting a new poll over the user's sign-out operation.
                if !showSignOutConfirmation && !isConfirmingSignOut {
                    await model.recover()
                    if model.identityReady {
                        await network.refresh(eventID: model.currentAlertEventID)
                        await timer.refresh()
                    }
                }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .confirmationDialog("Sign out of SignalWord?", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign out") {
                isConfirmingSignOut = true
                Task {
                    defer { isConfirmingSignOut = false }
                    await model.signOut(statusUpdateInProgress: timer.busy || network.busy)
                    if !model.hasEnteredDashboard { network.clear(); timer.clear(); selectedTab = .home }
                }
            }
            .disabled(!model.canSignOut || timer.busy || network.busy)
            .accessibilityIdentifier("account.confirmSignOut")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account and server data are kept. Sign-out does not cancel alerts or check-in timers. Finish active alerts and timers first. Vocal Shortcuts cannot send alerts while signed out; after switching accounts, they use the signed-in account.")
        }
        .confirmationDialog(
            "Delete all SignalWord data?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account and data", role: .destructive) {
                Task { await model.deleteAccount() }
            }
            .accessibilityIdentifier("account.confirmDeletion")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes alert links, removes your contact and alerts, deletes the identity, and clears this device session. This cannot be undone.")
        }
    }

    private var mainTabs: some View {
        VStack(spacing: 0) {
            NavigationStack {
                switch selectedTab {
                case .home:
                    HomeScreen(
                        model: model,
                        openPeople: { selectedTab = .people },
                        openSettings: { selectedTab = .settings },
                        openRehearsal: { selectedTab = .people }
                    )
                case .people:
                    PeopleScreen(model: model, editContact: showContactEditorFlow)
                case .settings:
                    SettingsScreen(
                        model: model,
                        supporter: supporter,
                        openPeople: { selectedTab = .people },
                        openDeleteConfirmation: { showDeleteConfirmation = true },
                        openSignOutConfirmation: { showSignOutConfirmation = true }
                    )
                }
            }
            .background(SignalWordBackground())
            .clipped()
            bottomNavigation
        }
        .background(SignalWordBackground())
    }

    /// A layout sibling, never an overlay. The ScrollViews get the remaining
    /// viewport; the bar's background alone extends over the home indicator.
    private var bottomNavigation: some View {
        HStack(spacing: 8) {
            ForEach([SignalTab.home, .people, .settings], id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 19, weight: .semibold))
                        Text(tab.title).font(.caption.weight(.medium))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedTab == tab ? accent.link : SignalWordColor.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .padding(.vertical, 4)
                    .background(selectedTab == tab ? accent.action.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("navigation.\(tab.title)")
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, SignalWordSpacing.page)
        .padding(.vertical, 8)
        .background(SignalWordColor.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(SignalWordColor.separator).frame(height: 0.5) }
        .accessibilityElement(children: .contain)

    }

    private func showContactEditorFlow() {
        model.editContact()
        showContactEditor = true
    }
}
