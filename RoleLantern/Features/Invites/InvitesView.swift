import SwiftUI

/// Shared so the Dashboard badge and the inbox stay in sync.
@MainActor
final class InvitesViewModel: ObservableObject {
    @Published var invites: [CandidateInvite] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private let api = CandidateAPI()

    var openCount: Int { invites.filter(\.isOpen).count }

    func refresh() async {
        isLoading = invites.isEmpty
        defer { isLoading = false }
        do {
            invites = try await api.invites()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func respond(_ invite: CandidateInvite, accept: Bool) async -> Bool {
        do {
            try await api.respond(to: invite, accept: accept)
            await refresh()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }
}

struct InvitesView: View {
    @ObservedObject var vm: InvitesViewModel

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.invites.isEmpty {
                ScrollView {
                    EmptyStateView(
                        title: "No invites yet",
                        message: "When an employer invites you to apply, it shows up here. They only see your anonymous profile until you accept."
                    )
                }
            } else {
                List {
                    let open = vm.invites.filter(\.isOpen)
                    let answered = vm.invites.filter { !$0.isOpen }
                    if !open.isEmpty {
                        Section("Waiting for you") {
                            ForEach(open) { invite in
                                NavigationLink(value: invite) { InviteRow(invite: invite) }
                            }
                        }
                    }
                    if !answered.isEmpty {
                        Section("Answered") {
                            ForEach(answered) { invite in
                                NavigationLink(value: invite) { InviteRow(invite: invite) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Invites")
        .navigationDestination(for: CandidateInvite.self) { invite in
            InviteDetailView(invite: invite, vm: vm)
        }
        .refreshable { await vm.refresh() }
        .task { await vm.refresh() }
    }
}

struct InviteRow: View {
    let invite: CandidateInvite

    var body: some View {
        HStack(spacing: 12) {
            CompanyAvatar(name: invite.companyName ?? "Employer", size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(invite.jobTitle ?? "Invite to apply")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Brand.navy)
                    .lineLimit(2)
                Text(invite.companyName ?? "An employer")
                    .font(.caption)
                    .foregroundColor(Brand.slate)
                if let date = invite.sentDate {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundColor(Brand.slate)
                }
            }
            Spacer(minLength: 0)
            InviteStatusChip(status: invite.status)
        }
        .padding(.vertical, 4)
    }
}

struct InviteStatusChip: View {
    let status: String
    var body: some View {
        switch status {
        case "sent": TagChip(text: "New", color: Brand.gold)
        case "viewed": TagChip(text: "Open", color: Brand.gold)
        case "accepted": TagChip(text: "Accepted", color: Brand.teal)
        case "declined": TagChip(text: "Declined", color: Brand.slate)
        case "expired": TagChip(text: "Expired", color: Brand.slate)
        default: TagChip(text: status.capitalized, color: Brand.slate)
        }
    }
}

struct InviteDetailView: View {
    let invite: CandidateInvite
    @ObservedObject var vm: InvitesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var confirmAccept = false
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    CompanyAvatar(name: invite.companyName ?? "Employer", size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(invite.jobTitle ?? "Invite to apply")
                            .font(.title3.weight(.medium))
                            .foregroundColor(Brand.navy)
                        Text([invite.companyName, invite.locationText].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundColor(Brand.slate)
                    }
                }

                if let message = invite.message, !message.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Message from the employer")
                            .font(.caption.weight(.medium))
                            .foregroundColor(Brand.slate)
                        Text(message)
                            .font(.body)
                            .foregroundColor(Brand.navy)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.surface)
                    .cornerRadius(12)
                }

                if let jobId = invite.jobId {
                    NavigationLink {
                        JobDetailLoader(jobId: jobId)
                    } label: {
                        Label("View the role", systemImage: "briefcase")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if invite.isOpen {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("What accepting means", systemImage: "hand.raised")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Brand.navy)
                        Text("This employer sees your name, email and CV, and you're submitted as an applicant for this role. Other employers still see nothing. Declining keeps you completely anonymous.")
                            .font(.subheadline)
                            .foregroundColor(Brand.slate)
                    }
                    .padding(14)
                    .background(Brand.cream)
                    .cornerRadius(12)

                    Button {
                        confirmAccept = true
                    } label: {
                        if working { ProgressView().tint(.white) } else { Text("Accept and share my CV") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working)

                    Button("Decline") {
                        Task {
                            working = true
                            if await vm.respond(invite, accept: false) { dismiss() }
                            working = false
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(working)
                } else {
                    InviteStatusChip(status: invite.status)
                }
            }
            .padding(20)
        }
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Share your name, email and CV with \(invite.companyName ?? "this employer")?",
            isPresented: $confirmAccept,
            titleVisibility: .visible
        ) {
            Button("Accept and share") {
                Task {
                    working = true
                    if await vm.respond(invite, accept: true) { dismiss() }
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Invite", isPresented: .init(
            get: { vm.errorText != nil }, set: { if !$0 { vm.errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorText ?? "")
        }
    }
}
