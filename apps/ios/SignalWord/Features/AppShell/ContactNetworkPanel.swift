import SwiftUI

struct ContactNetworkPanel: View {
    @Environment(ContactNetworkModel.self) private var network
    @State private var editing = false
    @State private var contactID: UUID?
    @State private var name = ""
    @State private var email = ""
    @State private var withdrawing: NetworkContact?

    var body: some View {
        if let snapshot = network.network {
            SignalWordCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your contact network").font(.headline)
                    Text("Up to three people. Each person confirms their email.").font(.subheadline).foregroundStyle(SignalWordColor.secondaryText)
                    ForEach(snapshot.contacts) { contact in
                        VStack(alignment: .leading) {
                            Text(contact.name + (contact.primary ? " · Primary" : "")).font(.headline)
                            Text(contact.status.capitalized).font(.caption)
                            VStack(alignment: .leading, spacing: 8) {
                                Button("Replace / invite again") {
                                    contactID = contact.id; name = contact.name; email = ""; editing = true
                                }
                                if !contact.primary && contact.status == "confirmed" {
                                    Button("Make primary") { Task { await network.configure(primary: contact.id) } }
                                }
                            }
                            if contact.status != "disabled" {
                                Button("Withdraw \(contact.name)", role: .destructive) { withdrawing = contact }
                            }
                        }
                        Divider()
                    }
                    if snapshot.contacts.count < 3 {
                        Button("Invite another person") { contactID = nil; name = ""; email = ""; editing = true }
                    }
                    Text("Routing for new alerts").font(.headline)
                    ForEach(ContactRoutingPolicy.allCases, id: \.self) { policy in
                        Button {
                            Task { await network.configure(policy: policy) }
                        } label: {
                            Label(policy.title, systemImage: snapshot.policy == policy ? "checkmark.circle.fill" : "circle")
                        }
                        .accessibilityAddTraits(snapshot.policy == policy ? .isSelected : [])
                    }
                    Text("Acknowledgement does not stop escalation or mean help is coming. Resolution stops unsent alerts. Two minutes is a pilot setting. Changes apply only to new alerts.")
                        .font(.caption)
                    if let message = network.message { Text(message).foregroundStyle(.orange) }
                }
                .font(.subheadline)
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(network.busy)
            }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    Form {
                        TextField("Contact name", text: $name)
                        TextField("Email", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                        Text("This sends an invitation. Replacing a person or inviting again revokes their earlier consent and access.")
                        if let message = network.message { Text(message) }
                        Button("Send invitation") {
                            Task { if await network.save(contactID: contactID, name: name, email: email) { editing = false } }
                        }.disabled(network.busy || name.trimmingCharacters(in: .whitespaces).isEmpty || !email.contains("@"))
                    }
                    .navigationTitle("Invite trusted contact")
                    .toolbar { Button("Close") { editing = false } }
                }
            }
            .confirmationDialog("Withdraw this person's consent?", isPresented: Binding(
                get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } })) {
                if let contact = withdrawing {
                    Button("Withdraw consent", role: .destructive) { Task { await network.withdraw(contact.id) }; withdrawing = nil }
                }
            } message: { Text("Their links and pending deliveries will be revoked. A message already submitted cannot be recalled.") }
        } else if let message = network.message {
            Text(message).font(.caption)
        }
    }
}

struct RecipientProgressPanel: View {
    let eventID: UUID?
    @Environment(ContactNetworkModel.self) private var network
    var body: some View {
        if eventID == network.recipientEventID, !network.recipients.isEmpty {
            SignalWordCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recipient progress").font(.headline)
                    ForEach(network.recipients) { recipient in
                        VStack(alignment: .leading) {
                            Text(recipient.name).font(.headline)
                            Text(recipient.summary(at: Date()))
                            if recipient.delivery == "queued" {
                                Text(recipient.scheduledAt, style: .time).font(.caption)
                            }
                            if recipient.acknowledgedAt != nil { Text("Acknowledged through this person's link").font(.caption) }
                            if let state = recipient.resolutionDelivery { Text("Resolution message: \(state)").font(.caption) }
                        }
                    }
                    Text("A link acknowledgement does not verify identity or confirm help.").font(.caption)
                    if let message = network.message { Text(message).foregroundStyle(.orange) }
                }
            }
        }
    }
}
