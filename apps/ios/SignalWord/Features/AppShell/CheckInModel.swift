import Foundation
import Observation
import UserNotifications

@MainActor @Observable final class CheckInModel {
    private let api: (any CheckInServing)?
    private let preferences: UserDefaults
    private var generation = 0
    private(set) var snapshot: CheckInSnapshot?
    private(set) var pending: CheckInCommand?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var reminderMessage: String?
    private let remindersEnabled: Bool
    nonisolated static let pendingKey = "checkIn.pendingCommand"

    init(api: (any CheckInServing)?, preferences: UserDefaults = .standard, remindersEnabled: Bool = true) {
        self.api = api
        self.preferences = preferences
        self.remindersEnabled = remindersEnabled
        if let data = preferences.data(forKey: Self.pendingKey) {
            pending = try? JSONDecoder().decode(CheckInCommand.self, from: data)
        }
    }
    func clear() {
        generation += 1
        snapshot = nil; pending = nil; message = nil
        preferences.removeObject(forKey: Self.pendingKey)
        if remindersEnabled { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["signalword.check-in"]) }
    }
    func refresh() async {
        guard let api, !busy else { return }
        busy = true
        let version = generation
        defer { busy = false }
        do {
            if let pending, let recovered = try await api.recoverCheckIn(command: pending.id) {
                guard version == generation else { return }
                self.pending = nil; preferences.removeObject(forKey: Self.pendingKey)
                snapshot = recovered
            }
            let latest = try await api.recoverCheckIn(command: nil)
            guard version == generation else { return }
            snapshot = latest
            message = pending == nil ? nil : "Your last change is unconfirmed. Review current status, then retry the same request when connected."
        } catch {
            guard version == generation else { return }
            message = "Unable to refresh. The server timer may still be running; do not assume it has stopped."
        }
    }
    func change(_ action: CheckInCommand.Action, minutes: Int? = nil) async {
        guard pending == nil, !busy else { return }
        let command = CheckInCommand(id: UUID(), action: action, timerId: action == .start ? nil : snapshot?.timerId, minutes: minutes)
        // Persist before the request so a lost response can be reconciled on relaunch.
        guard let data = try? JSONEncoder().encode(command) else { return }
        preferences.set(data, forKey: Self.pendingKey)
        pending = command
        await retry()
    }
    func retry() async {
        guard let api, let command = pending, !busy else { return }
        busy = true
        let version = generation
        defer { busy = false }
        do {
            let confirmed = try await api.changeCheckIn(command)
            guard version == generation else { return }
            snapshot = confirmed
            pending = nil; preferences.removeObject(forKey: Self.pendingKey)
            message = nil
            await updateReminder(confirmed)
        } catch {
            guard version == generation else { return }
            if case CheckInFailure.conflict = error {
                pending = nil
                preferences.removeObject(forKey: Self.pendingKey)
            }
            message = "Change not confirmed. The timer may still be running. Refresh or retry; the same request ID prevents duplicate changes."
        }
    }
    private func updateReminder(_ confirmed: CheckInSnapshot) async {
        guard remindersEnabled else { return }
        let version = generation
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["signalword.check-in"])
        guard confirmed.state == .active else { return }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                reminderMessage = "Reminders are disabled. Your confirmed server timer still runs."
                return
            }
            guard version == generation else { return }
            let seconds = confirmed.deadline.timeIntervalSince(confirmed.serverNow) - 60
            guard seconds > 0 else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your SignalWord check-in is due soon"
            content.body = "Open SignalWord and confirm your check-in while connected."
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: "signalword.check-in", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
            if version != generation { center.removePendingNotificationRequests(withIdentifiers: ["signalword.check-in"]); return }
            reminderMessage = "A device reminder is supplementary; it cannot cancel the server timer."
        } catch { reminderMessage = "Could not schedule a device reminder. Your confirmed server timer still runs." }
    }
}
