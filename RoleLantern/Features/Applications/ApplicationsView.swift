import SwiftUI

/// Application tracker: every role the candidate applied to (in-app) or opened
/// on the company site, with the latest status from the employer.
struct ApplicationsView: View {
    /// False when a parent stack (My Jobs) already declares the job destination.
    var declaresDestination = true
    @State private var applications: [TrackedApplication] = []
    @State private var recentlyRemoved: TrackedApplication?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var filter: Filter = .all
    @State private var pendingWithdraw: TrackedApplication?

    private let api = CandidateAPI()

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case applied = "Applied"
        case external = "Company site"
        var id: String { rawValue }
    }

    private var shown: [TrackedApplication] {
        switch filter {
        case .all: return applications
        case .applied: return applications.filter(\.isPlatform)
        case .external: return applications.filter { !$0.isPlatform }
        }
    }

    var body: some View {
        Group {
            if isLoading && applications.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if applications.isEmpty {
                ScrollView {
                    EmptyStateView(
                        title: "No applications yet",
                        message: "Roles you apply to show up here, with updates when the employer changes your status."
                    )
                }
            } else {
                List {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    ForEach(shown) { app in
                        NavigationLink(value: app.jobId) {
                            ApplicationRow(app: app)
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                Task { await remove(app) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .tint(.red)
                            if app.isPlatform && app.status != "withdrawn" {
                                Button {
                                    pendingWithdraw = app
                                } label: {
                                    Label("Withdraw", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Applications")
        .modifier(JobIdDestination(enabled: declaresDestination))
        .overlay(alignment: .bottom) {
            if recentlyRemoved != nil {
                UndoBar(text: "Removed from your tracker",
                        onUndo: { Task { await undoRemove() } },
                        onClose: { withAnimation { recentlyRemoved = nil } })
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            "Withdraw your application for \(pendingWithdraw?.jobTitle ?? "this role")?",
            isPresented: .init(get: { pendingWithdraw != nil }, set: { if !$0 { pendingWithdraw = nil } }),
            titleVisibility: .visible
        ) {
            Button("Withdraw application", role: .destructive) {
                if let app = pendingWithdraw { Task { await withdraw(app) } }
                pendingWithdraw = nil
            }
            Button("Cancel", role: .cancel) { pendingWithdraw = nil }
        } message: {
            Text("\(pendingWithdraw?.companyName ?? "The employer") will no longer see your application. To only tidy your list, use Remove instead.")
        }
        .alert("Applications", isPresented: .init(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func remove(_ app: TrackedApplication) async {
        withAnimation { applications.removeAll { $0.id == app.id } }
        recentlyRemoved = app
        do {
            try await api.setApplicationHidden(app.id, hidden: true)
        } catch {
            recentlyRemoved = nil
            await load()
            errorText = error.localizedDescription
            return
        }
        // Always clear the Undo bar after 5 seconds, even if this task is cancelled.
        let removedId = app.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if recentlyRemoved?.id == removedId { withAnimation { recentlyRemoved = nil } }
        }
    }

    private func withdraw(_ app: TrackedApplication) async {
        withAnimation { applications.removeAll { $0.id == app.id } }
        do {
            try await MobileAPI().withdrawApplication(app.id)
        } catch {
            errorText = error.localizedDescription
            await load()
        }
    }

    private func undoRemove() async {
        guard let app = recentlyRemoved else { return }
        withAnimation { recentlyRemoved = nil }
        try? await api.setApplicationHidden(app.id, hidden: false)
        await load()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            applications = try await api.applications()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct ApplicationRow: View {
    let app: TrackedApplication

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CompanyAvatar(name: app.companyName ?? "Role", size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.jobTitle ?? "Role no longer listed")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Brand.navy)
                    .lineLimit(2)
                if let company = app.companyName {
                    Text(company)
                        .font(.caption)
                        .foregroundColor(Brand.slate)
                }
                HStack(spacing: 6) {
                    TagChip(text: ApplicationStatus.label(for: app), color: ApplicationStatus.color(for: app))
                    if app.jobClosed {
                        TagChip(text: "Role closed", color: Brand.slate)
                    }
                }
                if let date = app.appliedDate {
                    Text((app.isPlatform ? "Applied " : "Opened ") + date.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundColor(Brand.slate)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

enum ApplicationStatus {
    static func label(for app: TrackedApplication) -> String {
        if !app.isPlatform { return "Applied on company site" }
        switch app.status {
        case "submitted": return "Submitted"
        case "viewed", "reviewed", "under_review", "in_review": return "Being reviewed"
        case "shortlisted", "interview", "interviewing": return "Interviewing"
        case "offer", "offered": return "Offer"
        case "hired": return "Hired"
        case "rejected", "declined", "not_selected": return "Not selected"
        case "withdrawn": return "Withdrawn"
        default: return app.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func color(for app: TrackedApplication) -> Color {
        if !app.isPlatform { return Brand.slate }
        switch app.status {
        case "shortlisted", "interview", "interviewing", "offer", "offered", "hired": return Brand.teal
        case "rejected", "declined", "not_selected", "withdrawn": return Brand.slate
        default: return Brand.gold
        }
    }
}

/// Loads a job by id, then shows the normal job detail screen.
struct JobDetailLoader: View {
    let jobId: UUID
    @EnvironmentObject var auth: AuthViewModel
    @StateObject private var jobsVM = JobsViewModel()
    @State private var job: BoardJob?
    @State private var failed = false

    var body: some View {
        Group {
            if let job {
                JobDetailView(job: job, jobsVM: jobsVM)
            } else if failed {
                EmptyStateView(title: "Role unavailable", message: "This role is no longer listed.")
            } else {
                ProgressView()
            }
        }
        .task {
            if let profile = auth.profile {
                await jobsVM.loadCandidateState(candidateId: profile.id)
            }
            do { job = try await DataService().fetchJob(id: jobId) } catch { failed = true }
        }
    }
}

/// Declares the job-id destination unless a parent stack already does.
struct JobIdDestination: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: UUID.self) { jobId in JobDetailLoader(jobId: jobId) }
        } else {
            content
        }
    }
}

/// Dark "…removed · Undo" bar shown for a few seconds after a removal.
struct UndoBar: View {
    let text: String
    let onUndo: () -> Void
    var onClose: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 14) {
            Text(text).font(.subheadline).foregroundColor(.white)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.gold)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundColor(.white.opacity(0.8))
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Brand.navy, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
