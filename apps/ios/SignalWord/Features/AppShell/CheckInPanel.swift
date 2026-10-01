import SwiftUI

struct CheckInPanel: View {
    private var unresolvedIncident: Bool { timer.snapshot?.state == .escalated && !["resolved", "expired"].contains(timer.snapshot?.incidentState ?? "") && timer.snapshot?.incidentId != nil }
    @Environment(CheckInModel.self) private var timer
    @State private var expanded = false
    var body: some View {
        SignalWordCard {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup("Safety check-in", isExpanded: Binding(get: { expanded || timer.snapshot?.state == .active || unresolvedIncident || timer.pending != nil }, set: { expanded = $0 })) {
                    controls
                }
                .font(.headline)
                Text("A missed check-in can send a REAL alert.")
                    .font(.caption).foregroundStyle(SignalWordColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: timer.snapshot?.state) { previous, current in
            // Keep the completion receipt visible after the active section ends.
            if previous == .active && current != .active { expanded = true }
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
                Text("Choose when you will check in. If you miss it, the server alerts your consenting contacts after a one-minute grace period and the next scheduling run.").font(.subheadline)
                if let current = timer.snapshot {
                    switch current.state {
                    case .active:
                        Text(current.serverNow >= current.graceEndsAt ? "Deadline passed — awaiting reconciliation" : "Active — confirmed by server").font(.headline).accessibilityIdentifier("timer.active")
                        Text("Check in by \(current.deadline.formatted(date: .abbreviated, time: .shortened))")
                        Text("Server grace ends \(current.graceEndsAt.formatted(date: .omitted, time: .shortened))").font(.caption)
                        Button("Check in now") { Task { await timer.change(.checkIn) } }
                        Button("Cancel check-in timer", role: .destructive) { Task { await timer.change(.cancel) } }
                        ForEach([15,30,60], id: \.self) { minutes in
                            Button("Extend by \(minutes) minutes") { Task { await timer.change(.extend, minutes: minutes) } }
                        }
                    case .escalated:
                        Text(unresolvedIncident ? "An alert already exists" : "Previous timer alert ended").font(.headline)
                        Text("Ending this timer does not retract alerts. Review the active alert above and resolve it explicitly.")
                    case .failed:
                        Text("Timer escalation failed").font(.headline)
                        Text("Review your confirmed primary contact and contact someone directly if you need assistance.")
                    case .checkedIn: Text("Checked in — confirmed by server")
                    case .cancelled: Text("Cancelled — confirmed by server")
                    }
                }
                if timer.snapshot?.state != .active && !unresolvedIncident && timer.pending == nil {
                    ForEach([15,30,60], id: \.self) { minutes in
                        Button("Start \(minutes)-minute check-in") { Task { await timer.change(.start, minutes: minutes) } }
                    }
                }
                if timer.pending != nil {
                    Text("Change pending — not confirmed").font(.headline)
                    Button("Retry timer request") { Task { await timer.retry() } }
                }
                if let message = timer.message { Text(message).foregroundStyle(.orange) }
                if let reminder = timer.reminderMessage { Text(reminder).font(.caption) }
                Button("Refresh timer status") { Task { await timer.refresh() } }
                Text("Keep a way to reconnect. Closing the app, losing reception or dismissing a reminder does not stop the timer.").font(.caption)
        }.font(.subheadline).buttonStyle(.bordered).controlSize(.large).disabled(timer.busy).padding(.top, 12)
    }
}
