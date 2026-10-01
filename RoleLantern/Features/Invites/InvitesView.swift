import SwiftUI

/// Shared so the Dashboard badge and the inbox stay in sync.
@MainActor
final class InvitesViewModel: ObservableObject {
    @Published var invites: [CandidateInvite] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private let api = CandidateAPI()
    private let mobile = MobileAPI()

    /// Last invite removed, kept briefly for Undo.
    @Published var recentlyRemoved: CandidateInvite?

    var openCount: Int { invites.filter(\.isOpen).count }

    func remove(_ invite: CandidateInvite) async {
        withAnimation { invites.removeAll { $0.id == invite.id } }
        recentlyRemoved = invite
        do {
            try await api.setInviteHidden(invite.id, hidden: true)
        } catch {
            recentlyRemoved = nil
            errorText = error.localizedDescription
            await refresh()
            return
        }
        let removedId = invite.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            if self.recentlyRemoved?.id == removedId { withAnimation { self.recentlyRemoved = nil } }
        }
    }

    func undoRemove() async {
        guard let invite = recentlyRemoved else { return }
        withAnimation { recentlyRemoved = nil }
        try? await api.setInviteHidden(invite.id, hidden: false)
        await refresh()
    }

    func refresh() async {
        isLoading = invites.isEmpty
        defer { isLoading = false }
        do {
            invites = try await api.invites()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func accept(_ invite: CandidateInvite, shareCv: Bool) async -> Bool {
        await run { try await self.mobile.acceptInvite(invite.id, shareCv: shareCv) }
    }

    func decline(_ invite: CandidateInvite) async -> Bool {
        await run { try await self.mobile.declineInvite(invite.id) }
    }

    func stopSharing(_ invite: CandidateInvite) async -> Bool {
        await run { try await self.mobile.revokeInvite(invite.id) }
    }

    private func run(_ work: @escaping () async throws -> Void) async -> Bool {
        do {
            try await work()
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
    /// False when a parent stack (My Jobs) already declares the invite destination.
    var declaresDestination = true

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
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            Task { await vm.remove(invite) }
                                        } label: {
                                            Label("Not interested", systemImage: "hand.thumbsdown")
                                        }
                                        .tint(.red)
                                    }
                            }
                        }
                    }
                    if !answered.isEmpty {
                        Section("Answered") {
                            ForEach(answered) { invite in
                                NavigationLink(value: invite) { InviteRow(invite: invite) }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            Task { await vm.remove(invite) }
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Invites")
        .modifier(InviteDestination(enabled: declaresDestination, vm: vm))
        .overlay(alignment: .bottom) {
            if vm.recentlyRemoved != nil {
                UndoBar(text: "Invite removed",
                        onUndo: { Task { await vm.undoRemove() } },
                        onClose: { withAnimation { vm.recentlyRemoved = nil } })
            }
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

    @State private var showConsent = false
    @State private var confirmStop = false
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
                        Text("This employer sees your name, email and LinkedIn, and you're added as an applicant for this role. Your CV is only shared if you choose to. Other employers still see nothing. Declining keeps you anonymous.")
                            .font(.subheadline)
                            .foregroundColor(Brand.slate)
                    }
                    .padding(14)
                    .background(Brand.cream)
                    .cornerRadius(12)

                    Button("Accept invite") { showConsent = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working)

                    Button {
                        Task {
                            working = true
                            if await vm.decline(invite) { dismiss() }
                            working = false
                        }
                    } label: {
                        if working { ProgressView() } else { Text("Decline") }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(working)
                } else {
                    InviteStatusChip(status: invite.status)
                    if invite.status == "accepted" {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("You're sharing with \(invite.companyName ?? "this employer")", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.navy)
                            Text(invite.cvShared == true
                                 ? "Your name, email, LinkedIn and CV."
                                 : "Your name, email and LinkedIn. Not your CV.")
                                .font(.subheadline)
                                .foregroundColor(Brand.slate)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.surface)
                        .cornerRadius(12)

                        Button(role: .destructive) {
                            confirmStop = true
                        } label: {
                            if working { ProgressView() } else { Text("Stop sharing my details") }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(working)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConsent) {
            InviteConsentSheet(companyName: invite.companyName ?? "this employer") { shareCv in
                showConsent = false
                Task {
                    working = true
                    if await vm.accept(invite, shareCv: shareCv) { dismiss() }
                    working = false
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Stop sharing your details with \(invite.companyName ?? "this employer")?",
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button("Stop sharing", role: .destructive) {
                Task {
                    working = true
                    if await vm.stopSharing(invite) { dismiss() }
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They lose access to your details and you're removed as an applicant for this role. The invite will show as declined.")
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

struct InviteDestination: ViewModifier {
    let enabled: Bool
    @ObservedObject var vm: InvitesViewModel
    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: CandidateInvite.self) { invite in
                InviteDetailView(invite: invite, vm: vm)
            }
        } else {
            content
        }
    }
}

/// Consent screen shown before accepting an invite. Matches the website: name, email
/// and LinkedIn are shared; the CV only if the candidate ticks the box (unticked by default).
struct InviteConsentSheet: View {
    let companyName: String
    let onAccept: (Bool) -> Void
    @State private var shareCv = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Your full name", systemImage: "person")
                    Label("Your email", systemImage: "envelope")
                    Label("Your LinkedIn", systemImage: "link")
                } header: {
                    Text("\(companyName) will see")
                }

                Section {
                    Toggle(isOn: $shareCv) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also share my CV").foregroundColor(Brand.navy)
                            Text("Your CV includes your phone number and work history.")
                                .font(.caption)
                                .foregroundColor(Brand.slate)
                        }
                    }
                    .tint(.green)
                } footer: {
                    Text("You can stop sharing at any time from this invite.")
                }

                Section {
                    Button {
                        onAccept(shareCv)
                    } label: {
                        Text(shareCv ? "Accept and share with my CV" : "Accept and share")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationTitle("Accept invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
