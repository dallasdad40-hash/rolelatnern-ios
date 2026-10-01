import SwiftUI

/// Native Privacy Center. Visibility and contact settings go through the website's
/// mobile API (the same fields the website enforces); the firewall table is shared.
struct PrivacyCenterView: View {
    /// Website-enforced settings (candidate_profiles), via the mobile API.
    @State private var web: MobilePrivacy?
    @State private var loaded = false
    @State private var blocked: [BlockedEmployer] = []
    @State private var audit: [PrivacyAuditEntry] = []
    @State private var isLoading = true
    @State private var saving = false
    @State private var errorText: String?
    @State private var newBlock = ""
    @State private var showAddBlock = false
    @State private var pendingRemoval: BlockedEmployer?
    /// Activity older than this is cleared from the candidate's view (the server keeps its record).
    @AppStorage("privacyActivityClearedAt") private var activityClearedAt: Double = 0

    /// Activity to show: newer than the last Clear, and with block/unblock pairs removed
    /// (unblocking an employer hides both the "Unblocked" and its matching "Blocked" line).
    private var visibleAudit: [PrivacyAuditEntry] {
        let recent = audit.filter { (ISODate.parse($0.createdAt)?.timeIntervalSince1970 ?? 0) > activityClearedAt }
        let oldestFirst = recent.sorted { (ISODate.parse($0.createdAt) ?? .distantPast) < (ISODate.parse($1.createdAt) ?? .distantPast) }
        var openBlocks: [String: [UUID]] = [:]
        var hidden = Set<UUID>()
        for entry in oldestFirst {
            let name = employerName(entry).lowercased()
            if entry.kind == "employer_blocked" {
                openBlocks[name, default: []].append(entry.id)
            } else if entry.kind == "employer_unblocked" {
                hidden.insert(entry.id)
                if let blockId = openBlocks[name]?.popLast() { hidden.insert(blockId) }
            }
        }
        return recent.filter { !hidden.contains($0.id) }
    }

    private func employerName(_ entry: PrivacyAuditEntry) -> String {
        (entry.detail ?? "").replacingOccurrences(of: " (iOS app)", with: "").trimmingCharacters(in: .whitespaces)
    }
    @Environment(\.openURL) private var openURL

    private let api = CandidateAPI()
    private let mobile = MobileAPI()

    /// The two choices the website offers, in the same words.
    private let visibilityChoices: [(value: String, title: String, detail: String)] = [
        ("anonymous_to_employers", "Verified employers, anonymously",
         "Verified employers can find an anonymous card with your skills and experience. No name, contact details, or CV."),
        ("private", "No one, keep me private",
         "Employers can't find you. You can still search and apply for jobs."),
    ]

    private func visibilityLabel(_ value: String) -> String {
        switch value {
        case "job_alerts_only": return "Job alerts only"
        case "visible_to_approved_employers": return "Approved employers"
        default: return visibilityChoices.first { $0.value == value }?.title ?? value
        }
    }

    var body: some View {
        Group {
            if let current = web {
                form(current)
            } else if isLoading && !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(title: "Privacy Center unavailable", message: "Pull down to try again.")
            }
        }
        .navigationTitle("Privacy Center")
        .refreshable { await load() }
        .task { await load() }
        .alert("Privacy Center", isPresented: .init(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.companyNameRaw ?? "this employer") from your firewall?",
            isPresented: .init(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval { Task { await remove([item]) } }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("They will be able to find your anonymous profile again, like any other employer.")
        }
        .alert("Block an employer", isPresented: $showAddBlock) {
            TextField("Company name", text: $newBlock)
            Button("Block") { Task { await addBlock() } }
            Button("Cancel", role: .cancel) { newBlock = "" }
        } message: {
            Text("They, and their parent and sister companies we know about, will never see or find your profile.")
        }
    }

    @ViewBuilder
    private func form(_ current: MobilePrivacy) -> some View {
        Form {
            Section {
                ForEach(visibilityChoices, id: \.value) { choice in
                    Button {
                        Task { await setVisibility(choice.value) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: current.profileVisibility == choice.value ? "largecircle.fill.circle" : "circle")
                                .font(.title3)
                                .foregroundColor(current.profileVisibility == choice.value ? .green : Color.gray.opacity(0.6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title).foregroundColor(Brand.navy)
                                Text(choice.detail)
                                    .font(.caption)
                                    .foregroundColor(Brand.slate)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                }
                if !visibilityChoices.contains(where: { $0.value == current.profileVisibility }) {
                    Label("Currently: \(visibilityLabel(current.profileVisibility)) (set on the website)", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(Brand.slate)
                }
            } header: {
                HStack {
                    Text("Who can find me")
                    if saving { Spacer(); ProgressView() }
                }
            } footer: {
                Text("This is the same setting as on rolelantern.com. Your name and CV stay hidden until you accept an invite or apply.")
            }

            Section {
                Toggle("Email me job alerts", isOn: Binding(
                    get: { current.jobAlertsEnabled ?? false },
                    set: { on in Task { await patch(.init(jobAlertsEnabled: on)) } }
                ))
                .tint(.green)
                Toggle("Recruitment agencies can contact me", isOn: Binding(
                    get: { current.agencyOutreachOptIn ?? false },
                    set: { on in Task { await patch(.init(agencyOutreachOptIn: on)) } }
                ))
                .tint(.green)
            } header: {
                Text("Contact")
            }

            Section {
                ProtectionRow(title: "Your CV is locked", detail: "Employers can't open your CV until you apply, or accept an invite and choose to share it.")
                ProtectionRow(title: "Contact details hidden", detail: "Your email and phone are never shown on your anonymous card.")
                ProtectionRow(title: "Current employer hidden", detail: "Companies don't see where you work now. Your firewall stops blocked employers from seeing you at all.")
                ProtectionRow(title: "You decide what's shared", detail: "Accepting an invite shares your name, email and LinkedIn. Your CV is only shared if you tick the box.")
            } header: {
                Text("Always on")
            }

            Section {
                ForEach(blocked) { employer in
                    HStack {
                        Label(employer.companyNameRaw ?? "Employer", systemImage: "shield.lefthalf.filled")
                            .foregroundColor(Brand.navy)
                        Spacer()
                        Button("Remove", role: .destructive) { pendingRemoval = employer }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.medium))
                    }
                }
                .onDelete { idx in
                    let items = idx.map { blocked[$0] }
                    Task { await remove(items) }
                }
                Button {
                    showAddBlock = true
                } label: {
                    Label("Block an employer", systemImage: "plus.circle")
                }
            } header: {
                Text("Employer firewall")
            } footer: {
                Text("Blocked employers can never see, find, or contact you. This overrides every other setting.")
            }

            if !visibleAudit.isEmpty {
                Section {
                    ForEach(visibleAudit.prefix(10)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(auditTitle(entry))
                                .font(.subheadline)
                                .foregroundColor(Brand.navy)
                            if let date = ISODate.parse(entry.createdAt) {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundColor(Brand.slate)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent privacy activity")
                        Spacer()
                        Button("Clear") {
                            withAnimation { activityClearedAt = Date().timeIntervalSince1970 }
                        }
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    Text("Clearing removes this list from your screen. RoleLantern keeps a private copy as proof of your privacy choices.")
                }
            }
        }
    }

    private func auditTitle(_ entry: PrivacyAuditEntry) -> String {
        switch entry.kind {
        case "employer_blocked": return "Blocked \(entry.detail?.replacingOccurrences(of: " (iOS app)", with: "") ?? "an employer")"
        case "employer_unblocked": return "Unblocked \(entry.detail?.replacingOccurrences(of: " (iOS app)", with: "") ?? "an employer")"
        case "setting_changed": return "Changed a privacy setting"
        default: return entry.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false; loaded = true }
        do {
            web = try await mobile.privacy()
        } catch {
            errorText = error.localizedDescription
        }
        // Firewall list and activity log (shared tables).
        if let data = try? await api.privacy() {
            blocked = data.blockedEmployers
            audit = data.audit
        }
    }

    private func setVisibility(_ value: String) async {
        guard web?.profileVisibility != value else { return }
        await patch(.init(profileVisibility: value))
    }

    private func patch(_ change: MobileAPI.PrivacyPatch) async {
        saving = true
        defer { saving = false }
        do {
            web = try await mobile.updatePrivacy(change)
        } catch {
            errorText = error.localizedDescription
            await load()
        }
    }

    private func addBlock() async {
        let name = newBlock.trimmingCharacters(in: .whitespaces)
        newBlock = ""
        guard !name.isEmpty else { return }
        do {
            try await api.blockEmployer(named: name)
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove(_ items: [BlockedEmployer]) async {
        do {
            for item in items { try await api.unblock(item) }
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

}

/// An always-on protection with a one-line explanation.
private struct ProtectionRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(Brand.navy)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(Brand.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
