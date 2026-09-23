import SwiftUI

/// Native Privacy Center. Same settings as the web Privacy Center (they share
/// one record), so a change here shows up on the website and vice versa.
struct PrivacyCenterView: View {
    @State private var settings: PrivacySettings?
    @State private var saved: PrivacySettings?
    @State private var blocked: [BlockedEmployer] = []
    @State private var audit: [PrivacyAuditEntry] = []
    @State private var isLoading = true
    @State private var saving = false
    @State private var errorText: String?
    @State private var newBlock = ""
    @State private var showAddBlock = false
    @Environment(\.openURL) private var openURL

    private let api = CandidateAPI()

    private let salaryOptions: [(String, String)] = [
        ("private", "Private"),
        ("private_match_only", "Only for matching"),
        ("anonymous_aggregate", "Anonymous statistics"),
        ("share_after_apply", "Share after I apply"),
        ("share_with_approved_employers", "Share with approved employers"),
    ]

    var body: some View {
        Group {
            if let binding = Binding($settings) {
                form(binding)
            } else if isLoading {
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
        .alert("Block an employer", isPresented: $showAddBlock) {
            TextField("Company name", text: $newBlock)
            Button("Block") { Task { await addBlock() } }
            Button("Cancel", role: .cancel) { newBlock = "" }
        } message: {
            Text("They, and their parent and sister companies we know about, will never see or find your profile.")
        }
    }

    @ViewBuilder
    private func form(_ s: Binding<PrivacySettings>) -> some View {
        Form {
            Section {
                Toggle("Employers can discover me", isOn: s.discoverable)
                Toggle("Show my anonymous card in search", isOn: s.anonymousSearchOptin)
                    .disabled(!s.wrappedValue.discoverable)
            } header: {
                Text("Visibility")
            } footer: {
                Text("Even when discoverable, employers only see an anonymous card. Your name and CV stay hidden until you accept an invite or apply.")
            }

            Section {
                Toggle("Lock my CV", isOn: s.cvLocked)
                Toggle("Hide my contact details", isOn: s.redactContactDetails)
                Toggle("Hide my current employer", isOn: s.redactCurrentEmployer)
                Picker("Reveal my identity", selection: s.identityRevealPolicy) {
                    Text("Only when I approve").tag("manual")
                    Text("When I accept an invite").tag("on_accept")
                }
            } header: {
                Text("Identity and CV")
            }

            Section {
                Picker("Invites per week", selection: s.inviteLimitPerWeek) {
                    ForEach([0, 1, 3, 5, 10, 20], id: \.self) { n in
                        Text(n == 0 ? "No invites" : "Up to \(n)").tag(n)
                    }
                }
                Picker("Salary expectations", selection: s.salaryVisibility) {
                    ForEach(salaryOptions, id: \.0) { value, label in Text(label).tag(value) }
                }
            } header: {
                Text("Invites and salary")
            }

            Section {
                Toggle("Also block parent and sister companies", isOn: s.autoProtectParentSubsidiaries)
                ForEach(blocked) { employer in
                    Label(employer.companyNameRaw ?? "Employer", systemImage: "shield.lefthalf.filled")
                        .foregroundColor(Brand.navy)
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
                Text("Blocked employers can never see, find, or contact you. This overrides every other setting. Swipe left to remove one.")
            }

            if s.wrappedValue != saved {
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Save changes") }
                    }
                    .disabled(saving)
                    Button("Discard", role: .destructive) { settings = saved }
                }
            }

            if !audit.isEmpty {
                Section("Recent privacy activity") {
                    ForEach(audit.prefix(10)) { entry in
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
                }
            }

            Section {
                Button {
                    openURL(AppConfig.webBaseURL.appendingPathComponent("candidate/privacy-center"))
                } label: {
                    Label("Download or correct my data (web)", systemImage: "arrow.up.right.square")
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
        defer { isLoading = false }
        do {
            let data = try await api.privacy()
            settings = data.settings
            saved = data.settings
            blocked = data.blockedEmployers
            audit = data.audit
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save() async {
        guard let settings else { return }
        saving = true
        defer { saving = false }
        do {
            try await api.updatePrivacy(settings)
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addBlock() async {
        let name = newBlock.trimmingCharacters(in: .whitespaces)
        newBlock = ""
        guard !name.isEmpty else { return }
        do {
            try await api.blockEmployer(named: name)
            await reloadKeepingEdits()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove(_ items: [BlockedEmployer]) async {
        do {
            for item in items { try await api.unblock(item) }
            await reloadKeepingEdits()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Refresh the firewall list without throwing away unsaved toggle edits.
    private func reloadKeepingEdits() async {
        let pending = settings
        let hadEdits = settings != saved
        await load()
        if hadEdits { settings = pending }
    }
}
