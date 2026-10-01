import SwiftUI

/// Job alerts, stored and emailed by the website's alert engine.
struct JobAlertsView: View {
    @State private var alerts: [JobAlert] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var showCreate = false
    @State private var pendingDelete: JobAlert?
    @State private var matchesFor: JobAlert?

    private let api = MobileAPI()
    static let frequencies = ["Instant", "Daily", "Weekly"]

    var body: some View {
        Group {
            if isLoading && alerts.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if alerts.isEmpty {
                ScrollView {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            title: "No job alerts yet",
                            message: "Tell us what you're looking for and we'll email you when matching roles are posted."
                        )
                        Button("Create a job alert") { showCreate = true }
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.horizontal, 20)
                    }
                }
            } else {
                List {
                    Section {
                        Text("We email you new matching jobs at the frequency you pick. Tap See matching jobs to view today's matches here.")
                            .font(.caption)
                            .foregroundColor(Brand.slate)
                    }
                    ForEach(alerts) { alert in
                        AlertRow(
                            alert: alert,
                            onToggle: { on in Task { await setStatus(alert, active: on) } },
                            onFrequency: { f in Task { await setFrequency(alert, f) } },
                            onShowMatches: { matchesFor = alert }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { pendingDelete = alert } label: { Label("Delete", systemImage: "trash") }
                                .tint(.red)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Job alerts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New job alert")
            }
        }
        .sheet(item: $matchesFor) { alert in
            AlertMatchesView(alert: alert)
        }
        .sheet(isPresented: $showCreate) {
            CreateAlertView { created in
                alerts.insert(created, at: 0)
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "this alert")\"?",
            isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let a = pendingDelete { Task { await delete(a) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .alert("Job alerts", isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { alerts = try await api.alerts() } catch { errorText = error.localizedDescription }
    }

    private func setStatus(_ alert: JobAlert, active: Bool) async {
        guard let i = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[i].status = active ? "active" : "paused"
        do { try await api.updateAlert(alert.id, status: active ? "active" : "paused") }
        catch { errorText = error.localizedDescription; await load() }
    }

    private func setFrequency(_ alert: JobAlert, _ f: String) async {
        guard let i = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[i].frequency = f
        do { try await api.updateAlert(alert.id, frequency: f) }
        catch { errorText = error.localizedDescription; await load() }
    }

    private func delete(_ alert: JobAlert) async {
        withAnimation { alerts.removeAll { $0.id == alert.id } }
        do { try await api.deleteAlert(alert.id) }
        catch { errorText = error.localizedDescription; await load() }
    }
}

private struct AlertRow: View {
    let alert: JobAlert
    let onToggle: (Bool) -> Void
    let onFrequency: (String) -> Void
    var onShowMatches: () -> Void = {}

    private var summary: String {
        let t = alert.triggers
        var parts = t.keywords + t.functions + t.therapeutic_areas
        parts += t.categories.map { AlertCategories.label(for: $0) }
        if !t.states.isEmpty { parts.append(t.states.joined(separator: ", ")) }
        if t.remote_status != "any" { parts.append(AlertCategories.workLabel(t.remote_status)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { alert.status == "active" }, set: onToggle)) {
                Text(alert.name).font(.subheadline.weight(.semibold)).foregroundColor(Brand.navy)
            }
            .tint(.green)
            if !summary.isEmpty {
                Text(summary).font(.caption).foregroundColor(Brand.slate).lineLimit(2)
            }
            HStack {
                Menu {
                    ForEach(JobAlertsView.frequencies, id: \.self) { f in
                        Button { onFrequency(f) } label: {
                            if alert.frequency == f { Label(f, systemImage: "checkmark") } else { Text(f) }
                        }
                    }
                } label: {
                    Label("Email: " + (alert.frequency == "Paused" ? "Paused" : alert.frequency), systemImage: "envelope")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(action: onShowMatches) {
                    Label("See matching jobs", systemImage: "list.bullet")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Brand.teal)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .opacity(alert.status == "active" ? 1 : 0.6)
    }
}

/// Same job categories as the website (lib/jobboard/categories.ts), stored by slug.
enum AlertCategories {
    static let all: [(slug: String, label: String)] = [
        ("clinical operations", "Clinical Operations"), ("biometrics", "Biometrics"),
        ("regulatory", "Regulatory"), ("quality", "Quality"), ("cmc", "CMC"),
        ("medical affairs", "Medical Affairs"), ("safety", "Safety"), ("research", "Research"),
        ("commercial", "Commercial"), ("medical device", "Medical Device"), ("diagnostics", "Diagnostics"),
        ("technical service", "Field & Technical Service"), ("information technology", "IT & Software"),
        ("corporate", "Corporate & Business"), ("supply chain", "Supply Chain & Logistics"),
        ("manufacturing operations", "Manufacturing Operations"),
    ]
    static func label(for slug: String) -> String { all.first { $0.slug == slug }?.label ?? slug.capitalized }

    static let work: [(value: String, label: String)] = [
        ("any", "Any work setting"), ("onsite", "On-site"), ("hybrid", "Hybrid"),
        ("remote", "Remote"), ("field_based", "Field-based"), ("travel_based", "Travel-based"),
    ]
    static func workLabel(_ v: String) -> String { work.first { $0.value == v }?.label ?? v }
}

struct CreateAlertView: View {
    let onCreated: (JobAlert) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var keywords = ""
    @State private var functions = ""
    @State private var areas = ""
    @State private var states = ""
    @State private var categories: Set<String> = []
    @State private var work = "any"
    @State private var frequency = "Daily"
    @State private var preview: AlertPreview?
    @State private var previewing = false
    @State private var saving = false
    @State private var errorText: String?

    private let api = MobileAPI()

    private func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var triggers: JobAlertTriggers {
        var t = JobAlertTriggers()
        t.keywords = list(keywords)
        t.functions = list(functions)
        t.therapeutic_areas = list(areas)
        t.states = list(states).map { $0.uppercased() }
        t.categories = AlertCategories.all.map(\.slug).filter { categories.contains($0) }
        t.remote_status = work
        return t
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Alert name (optional)", text: $name)
                }
                Section {
                    TextField("Keywords, e.g. CRA, oncology", text: $keywords)
                    TextField("Functions, e.g. Clinical Data Management", text: $functions)
                    TextField("Therapeutic areas, e.g. Oncology", text: $areas)
                } header: { Text("What to look for") } footer: { Text("Separate several with commas.") }

                Section("Categories") {
                    ForEach(AlertCategories.all, id: \.slug) { c in
                        Button {
                            if categories.contains(c.slug) { categories.remove(c.slug) } else { categories.insert(c.slug) }
                        } label: {
                            HStack {
                                Text(c.label).foregroundColor(Brand.navy)
                                Spacer()
                                if categories.contains(c.slug) { Image(systemName: "checkmark").foregroundColor(Brand.teal) }
                            }
                        }
                    }
                }

                Section {
                    TextField("States, e.g. MA, CA (blank for all)", text: $states)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Work setting", selection: $work) {
                        ForEach(AlertCategories.work, id: \.value) { Text($0.label).tag($0.value) }
                    }
                } header: { Text("Where") } footer: {
                    Text(work == "remote" && !list(states).isEmpty
                         ? "Jobs in \(list(states).joined(separator: ", ").uppercased()) or remote anywhere."
                         : "Pick Remote and add states to get jobs in those states or remote anywhere.")
                }

                Section {
                    Picker("Email me", selection: $frequency) {
                        ForEach(JobAlertsView.frequencies, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section {
                    HStack {
                        if previewing {
                            ProgressView()
                            Text("Checking today's jobs...").foregroundColor(Brand.slate)
                        } else if let preview {
                            Image(systemName: preview.count > 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundColor(preview.count > 0 ? Brand.teal : .orange)
                            Text(preview.count == 1 ? "1 job matches today" : "\(preview.count) jobs match today")
                                .fontWeight(.semibold)
                                .foregroundColor(Brand.navy)
                        } else {
                            Text(triggers.hasCriteria ? "Checking..." : "Add a keyword, category, state or Remote to see matches.")
                                .font(.subheadline)
                                .foregroundColor(Brand.slate)
                        }
                    }
                    ForEach(preview?.top ?? []) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? "Role").font(.subheadline).foregroundColor(Brand.navy)
                            Text([item.company, item.location].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundColor(Brand.slate)
                        }
                    }
                } header: {
                    Text("Matches today")
                } footer: {
                    if preview?.count == 0 {
                        Text("Keywords match job titles. Try a broader keyword, or fewer filters. You can still save it and we'll email you when one is posted.")
                    }
                }
            }
            .navigationTitle("New job alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") { Task { await save() } }.disabled(!triggers.hasCriteria)
                    }
                }
            }
            .task(id: triggers) {
                // Live preview, half a second after the last change.
                preview = nil
                guard triggers.hasCriteria else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                await runPreview()
            }
            .alert("Job alert", isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func runPreview() async {
        previewing = true
        defer { previewing = false }
        let t = triggers
        if let p = try? await api.previewAlert(t), t == triggers { preview = p }
    }

    private func save() async {
        if triggers.states.contains(where: { $0.count != 2 }) {
            errorText = "Use 2-letter state codes, like MA or CA."
            return
        }
        saving = true
        defer { saving = false }
        do {
            let created = try await api.createAlert(
                name: name.trimmingCharacters(in: .whitespaces), triggers: triggers, frequency: frequency)
            onCreated(created)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Jobs matching one alert today (same matching rules as the alert emails).
struct AlertMatchesView: View {
    let alert: JobAlert
    @Environment(\.dismiss) private var dismiss
    @State private var preview: AlertPreview?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if let preview {
                    if preview.count == 0 {
                        EmptyStateView(title: "No matches today",
                                       message: "We'll email you as soon as a matching job is posted.")
                    } else {
                        List {
                            Section {
                                ForEach(preview.top ?? []) { item in
                                    NavigationLink {
                                        JobDetailLoader(jobId: item.id)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title ?? "Role").font(.subheadline.weight(.medium)).foregroundColor(Brand.navy)
                                            Text([item.company, item.location].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption).foregroundColor(Brand.slate)
                                        }
                                    }
                                }
                            } footer: {
                                if preview.count > (preview.top?.count ?? 0) {
                                    Text("Showing the newest \(preview.top?.count ?? 0) of \(preview.count) matches.")
                                }
                            }
                        }
                    }
                } else if let errorText {
                    EmptyStateView(title: "Couldn't load matches", message: errorText)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(alert.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                do { preview = try await MobileAPI().previewAlert(alert.triggers) }
                catch { errorText = error.localizedDescription }
            }
        }
    }
}
