import SwiftUI

/// Profile tab: who you are, your CV + Lantern AI review, and your employer firewall.
struct ProfileView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var showReview = false
    @State private var details: MobileProfile?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    CVCard()
                    EmployerFirewallCard()
                    links
                }
                .padding(20)
            }
            .background(Brand.surface.ignoresSafeArea())
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ProfileMenuButton() }
            }
            .refreshable {
                await auth.loadOrCreateProfile()
                await loadDetails()
            }
            .task { await loadDetails() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            LanternMark(size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(details?.fullName?.isEmpty == false ? details!.fullName! : (auth.userEmail ?? "Your profile"))
                    .font(.headline)
                    .foregroundColor(Brand.navy)
                    .lineLimit(1)
                if let title = details?.currentTitle, !title.isEmpty {
                    Text(title).font(.subheadline).foregroundColor(Brand.slate).lineLimit(1)
                }
                if let anonId = auth.profile?.anonymousDisplayId {
                    Label("Employers see you as \(anonId)", systemImage: "theatermasks")
                        .font(.caption)
                        .foregroundColor(Brand.slate)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(16)
    }

    private var links: some View {
        VStack(spacing: 0) {
            NavigationLink {
                EditProfileView { details = $0 }
            } label: {
                row("Your details", icon: "person.text.rectangle",
                    badge: details?.strength.flatMap { $0.percent < 100 ? "\($0.percent)% complete" : nil })
            }
            Divider().padding(.leading, 48)
            NavigationLink {
                JobAlertsView()
            } label: {
                row("Job alerts", icon: "bell.badge")
            }
            Divider().padding(.leading, 48)
            NavigationLink {
                PrivacyCenterView()
            } label: {
                row("All privacy settings", icon: "hand.raised")
            }
            Divider().padding(.leading, 48)
            NavigationLink {
                AccountView(embedded: true)
            } label: {
                row("Account settings", icon: "gearshape")
            }
        }
        .buttonStyle(.plain)
        .background(Color.white)
        .cornerRadius(16)
    }

    private func loadDetails() async {
        if let p = try? await MobileAPI().profile() { details = p }
    }

    private func row(_ title: String, icon: String, badge: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(Brand.teal).frame(width: 24)
            Text(title).font(.subheadline.weight(.medium)).foregroundColor(Brand.navy)
            Spacer()
            if let badge {
                Text(badge).font(.caption.weight(.semibold)).foregroundColor(Brand.teal)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Brand.slate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Add and remove employers who must never see you. Same list as the website.
struct EmployerFirewallCard: View {
    @State private var blocked: [BlockedEmployer] = []
    @State private var isLoading = true
    @State private var busy = false
    @State private var showAdd = false
    @State private var newName = ""
    @State private var pendingRemoval: BlockedEmployer?
    @State private var errorText: String?

    private let api = CandidateAPI()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Employer firewall", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                    .foregroundColor(Brand.navy)
                Spacer()
                if busy { ProgressView() }
            }
            Text("Employers you add here can never see, find, or contact you, including their parent and sister companies.")
                .font(.caption)
                .foregroundColor(Brand.slate)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if blocked.isEmpty {
                Text("No employers blocked yet. Add your current employer so they never see you.")
                    .font(.subheadline)
                    .foregroundColor(Brand.navy)
            } else {
                ForEach(blocked) { employer in
                    HStack {
                        Image(systemName: "building.2").foregroundColor(Brand.teal)
                        Text(employer.companyNameRaw ?? "Employer")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Brand.navy)
                        Spacer()
                        Button("Remove", role: .destructive) { pendingRemoval = employer }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                    if employer.id != blocked.last?.id { Divider() }
                }
            }

            Button {
                showAdd = true
            } label: {
                Label("Add an employer", systemImage: "plus.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy)
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(16)
        .task { await load() }
        .alert("Add an employer", isPresented: $showAdd) {
            TextField("Company name", text: $newName)
            Button("Add") { Task { await add() } }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("They, and their parent and sister companies we know about, will never see or find your profile.")
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.companyNameRaw ?? "this employer") from your firewall?",
            isPresented: .init(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval { Task { await remove(item) } }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("They will be able to find your anonymous profile again, like any other employer.")
        }
        .alert("Employer firewall", isPresented: .init(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            blocked = try await api.privacy().blockedEmployers
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func add() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.blockEmployer(named: name)
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove(_ employer: BlockedEmployer) async {
        busy = true
        defer { busy = false }
        do {
            try await api.unblock(employer)
            withAnimation { blocked.removeAll { $0.id == employer.id } }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
